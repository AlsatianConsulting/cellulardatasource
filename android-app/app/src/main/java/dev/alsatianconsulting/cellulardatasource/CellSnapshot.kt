package dev.alsatianconsulting.cellulardatasource

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.telephony.CellIdentityNr
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.CellSignalStrengthNr
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal class CellSnapshot(
    private val context: Context,
    private val prefs: SharedPreferences,
    private val telephonyManager: TelephonyManager?,
    private val getLastFix: () -> Location?,
    private val setLastFix: (Location) -> Unit,
    private val getSatellites: () -> Int?,
    private val getStreamClients: () -> Int,
    private val getNmeaClients: () -> Int,
    private val getLastWriteMs: () -> Long,
    private val getLastActivityMs: () -> Long,
    private val isListenerRegistered: () -> Boolean,
    private val getListenerEventCount: () -> Int,
    private val getLastListenerEventMs: () -> Long,
) {
    companion object {
        private const val TAG = "CellSnapshot"
        private const val KEY_STREAM_CELL = "stream_cellular"
        private const val KEY_STREAM_GPS = "stream_gps"
        private const val TRANSPORT_USB = "usb"
    }

    fun collectOnce(): JSONObject {
        val root = JSONObject()
        root.put("ts", System.currentTimeMillis() / 1000.0)

        val hasLocationPermission = hasLocationPermission()
        val hasPhonePermission = hasPhonePermission()

        val cells = if (prefs.getBoolean(KEY_STREAM_CELL, true) && hasLocationPermission && hasPhonePermission) {
            fetchCellArray()
        } else {
            JSONArray()
        }

        val bestLoc = if (prefs.getBoolean(KEY_STREAM_GPS, true) && hasLocationPermission) {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            selectBestLocation(getLastFix(), getBestLocation(lm))
        } else {
            null
        }

        telephonyManager?.let { tm ->
            root.put("network_name", tm.networkOperatorName ?: "")
            root.put("network_type", networkTypeToString(tm.dataNetworkType))
        }

        bestLoc?.let { loc ->
            root.put("lat", loc.latitude)
            root.put("lon", loc.longitude)
            if (loc.hasAltitude()) root.put("alt_m", loc.altitude)
            if (loc.hasSpeed()) root.put("speed_mps", loc.speed)
            if (loc.hasBearing()) root.put("bearing_deg", loc.bearing)
            if (loc.hasAccuracy()) root.put("accuracy_m", loc.accuracy)
            root.put("provider", loc.provider ?: JSONObject.NULL)
            setLastFix(Location(loc))
        }
        getSatellites()?.let { root.put("satellites", it) }
        root.put("cells", cells)

        if (cells.length() == 0 && bestLoc == null) {
            root.put("status", when {
                !hasLocationPermission &&
                    (prefs.getBoolean(KEY_STREAM_CELL, true) ||
                        prefs.getBoolean(KEY_STREAM_GPS, true)) -> "no_location_permission"
                else -> "no_observations"
            })
        }

        return root
    }

    fun appendStreamHealth(root: JSONObject) {
        val now = System.currentTimeMillis()
        val streamClients = getStreamClients().coerceAtLeast(0)
        val nmeaClients = getNmeaClients().coerceAtLeast(0)
        val totalClients = streamClients + nmeaClients
        val lastWrite = getLastWriteMs()
        val ageMs = if (lastWrite > 0L) now - lastWrite else Long.MAX_VALUE
        val lastActivity = getLastActivityMs()
        val seenRecently = lastActivity > 0L && (now - lastActivity) <= 10_000L
        val streamOk = streamClients > 0 && ageMs <= 6000L
        val attachedClient = totalClients > 0 || seenRecently
        val listenerEvents = getListenerEventCount().coerceAtLeast(0)
        val lastListenerEvent = getLastListenerEventMs()
        val listenerAgeMs = if (lastListenerEvent > 0L) now - lastListenerEvent else Long.MAX_VALUE
        val listenerLive = listenerAgeMs <= 10_000L

        root.put("stream_clients", streamClients)
        root.put("nmea_clients", nmeaClients)
        root.put("total_clients", totalClients)
        root.put("transport_mode", TRANSPORT_USB)
        root.put("pi_service_running", attachedClient)
        root.put("stream_ok", streamOk)
        root.put("cell_listener_registered", isListenerRegistered())
        root.put("cell_listener_events", listenerEvents)
        root.put("cell_listener_live", listenerLive)
        root.put("stream_cell_enabled", prefs.getBoolean(KEY_STREAM_CELL, true))
        root.put("stream_gps_enabled", prefs.getBoolean(KEY_STREAM_GPS, true))
        if (lastListenerEvent > 0L) {
            root.put("cell_listener_last_event_age_s", listenerAgeMs / 1000.0)
        } else {
            root.put("cell_listener_last_event_age_s", JSONObject.NULL)
        }
        if (streamClients > 0 && lastWrite > 0L) {
            root.put("stream_last_write_age_s", ageMs / 1000.0)
        } else {
            root.put("stream_last_write_age_s", JSONObject.NULL)
        }
    }

    internal fun fetchCellArray(): JSONArray {
        val arr = JSONArray()
        val infos = telephonyManager?.let { fetchCells(it) } ?: emptyList<CellInfo>()
        infos.forEach { ci ->
            when (ci) {
                is CellInfoLte -> lteJson(ci)?.let { arr.put(it) }
                is CellInfoWcdma -> wcdmaJson(ci)?.let { arr.put(it) }
                is CellInfoGsm -> gsmJson(ci)?.let { arr.put(it) }
                is CellInfoNr -> nrJson(ci)?.let { arr.put(it) }
            }
        }
        return arr
    }

    private fun fetchCells(tm: TelephonyManager): List<CellInfo>? {
        val latch = CountDownLatch(1)
        var result: List<CellInfo>? = null
        try {
            tm.requestCellInfoUpdate(context.mainExecutor, object : TelephonyManager.CellInfoCallback() {
                override fun onCellInfo(cellInfo: MutableList<CellInfo>) {
                    result = cellInfo
                    latch.countDown()
                }
            })
            latch.await(1, TimeUnit.SECONDS)
        } catch (exc: Exception) {
            Log.w(TAG, "requestCellInfoUpdate failed", exc)
        }
        if (!result.isNullOrEmpty()) return result
        return tm.allCellInfo
    }

    internal fun networkTypeToString(type: Int): String = when (type) {
        TelephonyManager.NETWORK_TYPE_LTE -> "LTE"
        TelephonyManager.NETWORK_TYPE_NR -> "NR"
        TelephonyManager.NETWORK_TYPE_GPRS -> "GPRS"
        TelephonyManager.NETWORK_TYPE_EDGE -> "EDGE"
        TelephonyManager.NETWORK_TYPE_UMTS -> "UMTS"
        TelephonyManager.NETWORK_TYPE_HSDPA -> "HSDPA"
        TelephonyManager.NETWORK_TYPE_HSUPA -> "HSUPA"
        TelephonyManager.NETWORK_TYPE_HSPA -> "HSPA"
        TelephonyManager.NETWORK_TYPE_CDMA -> "CDMA"
        TelephonyManager.NETWORK_TYPE_EVDO_0 -> "EVDO_0"
        TelephonyManager.NETWORK_TYPE_EVDO_A -> "EVDO_A"
        TelephonyManager.NETWORK_TYPE_EVDO_B -> "EVDO_B"
        else -> "UNKNOWN"
    }

    private fun validInt(v: Int): Any = if (v == Int.MAX_VALUE) JSONObject.NULL else v

    private fun lteJson(ci: CellInfoLte): JSONObject? {
        val id = ci.cellIdentity
        val ss = ci.cellSignalStrength
        val mcc = mccString(id.mccString, id.mcc)
        val mnc = mccString(id.mncString, id.mnc)
        val cid = if (id.ci == Int.MAX_VALUE) null else id.ci
        val tac = if (id.tac == Int.MAX_VALUE) null else id.tac
        return JSONObject().apply {
            put("rat", "LTE")
            put("registered", ci.isRegistered)
            put("mcc", mcc ?: JSONObject.NULL)
            put("mnc", mnc ?: JSONObject.NULL)
            put("tac", tac ?: JSONObject.NULL)
            put("cid", cid ?: JSONObject.NULL)
            put("full_cell_id", cid ?: JSONObject.NULL)
            put("pci", validInt(id.pci))
            put("earfcn", validInt(id.earfcn))
            put("rssi", validInt(ss.dbm))
            put("rsrp", validInt(ss.rsrp))
            put("rsrq", validInt(ss.rsrq))
            put("rssnr", validInt(ss.rssnr))
            put("ta", validInt(ss.timingAdvance))
            put("full_cell_key", listOfNotNull(mcc, mnc, tac?.toString(), cid?.toString()).joinToString("-"))
        }
    }

    private fun gsmJson(ci: CellInfoGsm): JSONObject? {
        val id = ci.cellIdentity
        val ss = ci.cellSignalStrength
        val mcc = mccString(id.mccString, id.mcc)
        val mnc = mccString(id.mncString, id.mnc)
        val cid = if (id.cid == Int.MAX_VALUE) null else id.cid
        val lac = if (id.lac == Int.MAX_VALUE) null else id.lac
        return JSONObject().apply {
            put("rat", "GSM")
            put("registered", ci.isRegistered)
            put("mcc", mcc ?: JSONObject.NULL)
            put("mnc", mnc ?: JSONObject.NULL)
            put("lac", lac ?: JSONObject.NULL)
            put("cid", cid ?: JSONObject.NULL)
            put("arfcn", validInt(id.arfcn))
            put("bsic", validInt(id.bsic))
            put("rssi", validInt(ss.dbm))
            put("full_cell_key", listOfNotNull(mcc, mnc, lac?.toString(), cid?.toString()).joinToString("-"))
        }
    }

    private fun wcdmaJson(ci: CellInfoWcdma): JSONObject? {
        val id = ci.cellIdentity
        val ss = ci.cellSignalStrength
        val mcc = mccString(id.mccString, id.mcc)
        val mnc = mccString(id.mncString, id.mnc)
        val cid = if (id.cid == Int.MAX_VALUE) null else id.cid
        val lac = if (id.lac == Int.MAX_VALUE) null else id.lac
        return JSONObject().apply {
            put("rat", "WCDMA")
            put("registered", ci.isRegistered)
            put("mcc", mcc ?: JSONObject.NULL)
            put("mnc", mnc ?: JSONObject.NULL)
            put("lac", lac ?: JSONObject.NULL)
            put("cid", cid ?: JSONObject.NULL)
            put("psc", validInt(id.psc))
            put("uarfcn", validInt(id.uarfcn))
            put("rssi", validInt(ss.dbm))
            put("full_cell_key", listOfNotNull(mcc, mnc, lac?.toString(), cid?.toString()).joinToString("-"))
        }
    }

    private fun nrJson(ci: CellInfoNr): JSONObject? {
        val id = ci.cellIdentity as? CellIdentityNr ?: return null
        val ss = ci.cellSignalStrength as? CellSignalStrengthNr
        val nci = if (id.nci == Long.MAX_VALUE) null else id.nci
        val tac = if (id.tac == Int.MAX_VALUE) null else id.tac
        val mcc = id.mccString
        val mnc = id.mncString
        return JSONObject().apply {
            put("rat", "NR")
            put("registered", ci.isRegistered)
            put("mcc", mcc ?: JSONObject.NULL)
            put("mnc", mnc ?: JSONObject.NULL)
            put("tac", tac ?: JSONObject.NULL)
            put("nci", nci ?: JSONObject.NULL)
            put("full_cell_id", nci ?: JSONObject.NULL)
            put("pci", validInt(id.pci))
            put("nrarfcn", validInt(id.nrarfcn))
            put("rssi", if (ss != null) validInt(ss.dbm) else JSONObject.NULL)
            put("rsrp", if (ss != null) validInt(ss.ssRsrp) else JSONObject.NULL)
            put("rsrq", if (ss != null) validInt(ss.ssRsrq) else JSONObject.NULL)
            put("rssnr", if (ss != null) validInt(ss.ssSinr) else JSONObject.NULL)
            put("csi_rsrp", if (ss != null) validInt(ss.csiRsrp) else JSONObject.NULL)
            put("csi_rsrq", if (ss != null) validInt(ss.csiRsrq) else JSONObject.NULL)
            put("csi_sinr", if (ss != null) validInt(ss.csiSinr) else JSONObject.NULL)
            put("full_cell_key", listOfNotNull(mcc, mnc, tac?.toString(), nci?.toString()).joinToString("-"))
        }
    }

    @Suppress("DEPRECATION")
    private fun mccString(newValue: String?, oldValue: Int): String? =
        newValue ?: if (oldValue != Int.MAX_VALUE) oldValue.toString() else null

    private fun hasLocationPermission(): Boolean =
        context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun hasPhonePermission(): Boolean =
        context.checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED

    private fun selectBestLocation(liveFix: Location?, fallbackFix: Location?): Location? {
        if (liveFix == null) return fallbackFix
        if (fallbackFix == null) return liveFix
        return if (liveFix.time >= fallbackFix.time) liveFix else fallbackFix
    }

    private fun getBestLocation(lm: LocationManager): Location? {
        var best: Location? = null
        for (provider in lm.getProviders(true)) {
            try {
                val location = lm.getLastKnownLocation(provider) ?: continue
                val currentBest = best
                if (currentBest == null) {
                    best = location
                } else {
                    val newer = location.time > currentBest.time
                    val moreAccurate = if (location.hasAccuracy() && currentBest.hasAccuracy()) {
                        location.accuracy < currentBest.accuracy
                    } else {
                        location.hasAccuracy() && !currentBest.hasAccuracy()
                    }
                    if (newer || moreAccurate) best = location
                }
            } catch (exc: SecurityException) {
                Log.w(TAG, "location permission denied for provider=$provider", exc)
            }
        }
        return best
    }
}
