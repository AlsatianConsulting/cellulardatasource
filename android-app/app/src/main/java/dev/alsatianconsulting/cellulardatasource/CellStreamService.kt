package dev.alsatianconsulting.cellulardatasource

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.telephony.*
import androidx.core.app.NotificationCompat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.atomic.AtomicInteger
import android.content.SharedPreferences
import android.location.GnssStatus
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.math.abs

class CellStreamService : Service() {
    companion object {
        const val ACTION_CELL_UPDATE = "dev.alsatianconsulting.cellulardatasource.CELL_UPDATE"
        const val EXTRA_PAYLOAD = "payload"
        private const val PREFS_NAME = "cellstream_prefs"
        private const val KEY_TRANSPORT_MODE = "transport_mode"
        private const val TRANSPORT_USB = "usb"
        private const val TRANSPORT_BLUETOOTH = "bluetooth"
        private const val TRANSPORT_BOTH = "both"
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private const val BT_SERVICE_NAME = "CellularDatasource"
    }
    // Use a non-adb port to avoid clashing with wireless-debugging (adb over TCP uses 5555).
    private val port = 8765
    // Dedicated NMEA TCP port for GPS feed that Kismet or other tools can consume directly.
    private val nmeaPort = 8766
    private val exec = Executors.newSingleThreadExecutor()
    private val nmeaExec = Executors.newSingleThreadExecutor()
    private val btExec = Executors.newSingleThreadExecutor()
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var running = true
    @Suppress("DEPRECATION")
    private var phoneStateListener: PhoneStateListener? = null
    private var telephonyCallback: TelephonyCallback? = null
    private var telephonyManager: TelephonyManager? = null
    private val prefs: SharedPreferences by lazy {
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
    }
    @Volatile private var satelliteCount: Int? = null
    private var gnssCallback: GnssStatus.Callback? = null
    @Volatile private var lastFix: android.location.Location? = null
    private var locationListener: LocationListener? = null
    @Volatile private var streamServerSocket: ServerSocket? = null
    @Volatile private var nmeaServerSocket: ServerSocket? = null
    @Volatile private var bluetoothServerSocket: BluetoothServerSocket? = null
    private val activeStreamClients = AtomicInteger(0)
    private val activeNmeaClients = AtomicInteger(0)
    private val activeBluetoothClients = AtomicInteger(0)
    private val listenerEventCount = AtomicInteger(0)
    @Volatile private var lastStreamWriteMs: Long = 0L
    @Volatile private var lastPiClientSeenMs: Long = 0L
    @Volatile private var lastListenerEventMs: Long = 0L
    @Volatile private var listenerRegistered: Boolean = false

    override fun onCreate() {
        super.onCreate()
        startForeground(1, notif())
        telephonyManager = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
        registerGnss()
        registerLocationUpdates()
        registerPhoneListener()
        exec.execute { runServer() }
        nmeaExec.execute { runNmeaServer() }
        btExec.execute { runBluetoothServer() }
        // Periodic broadcast even without TCP client connected
        scheduler.scheduleAtFixedRate({
            val payload = collectOnce()
            if (payload != null) {
                broadcast(payload)
            }
        }, 0, 2, TimeUnit.SECONDS)
    }

    private fun notif(): Notification {
        val chanId = "cellstream"
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(chanId, "Cell Stream", NotificationManager.IMPORTANCE_LOW)
            )
        }
        return NotificationCompat.Builder(this, chanId)
            .setContentTitle("Cell stream running")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .build()
    }

    private fun runServer() {
        while (running) {
            if (!isUsbTransportEnabled()) {
                closeStreamServerSocket()
                Thread.sleep(500)
                continue
            }
            try {
                val server = ensureStreamServerSocket()
                val client = server.accept()
                activeStreamClients.incrementAndGet()
                lastPiClientSeenMs = System.currentTimeMillis()
                Executors.newSingleThreadExecutor().execute { handleClient(client) }
            } catch (_: SocketTimeoutException) {
                // Keep server responsive without blocking forever on accept.
            } catch (_: Exception) {
                closeStreamServerSocket()
                if (running) Thread.sleep(500)
            }
        }
        closeStreamServerSocket()
    }

    private fun handleClient(sock: Socket) {
        try {
            sock.use { s ->
                val out = BufferedWriter(OutputStreamWriter(s.getOutputStream()))
                while (running && !s.isClosed) {
                    try {
                        val payload = collectOnce()
                        if (payload != null) {
                            out.write(payload)
                            out.newLine()
                            out.flush()
                            lastPiClientSeenMs = System.currentTimeMillis()
                            lastStreamWriteMs = System.currentTimeMillis()
                            broadcast(payload)
                        }
                    } catch (_: Exception) {
                        // A write/read error means the client is gone; exit so counters stay accurate.
                        break
                    }
                    Thread.sleep(2000)
                }
            }
        } finally {
            val remaining = activeStreamClients.decrementAndGet()
            if (remaining < 0) activeStreamClients.set(0)
        }
    }

    private fun runNmeaServer() {
        while (running) {
            if (!isUsbTransportEnabled()) {
                closeNmeaServerSocket()
                Thread.sleep(500)
                continue
            }
            try {
                val server = ensureNmeaServerSocket()
                val client = server.accept()
                activeNmeaClients.incrementAndGet()
                lastPiClientSeenMs = System.currentTimeMillis()
                Executors.newSingleThreadExecutor().execute { handleNmeaClient(client) }
            } catch (_: SocketTimeoutException) {
                // Keep server responsive without blocking forever on accept.
            } catch (_: Exception) {
                closeNmeaServerSocket()
                if (running) Thread.sleep(500)
            }
        }
        closeNmeaServerSocket()
    }

    private fun runBluetoothServer() {
        while (running) {
            if (!isBluetoothTransportEnabled()) {
                closeBluetoothServerSocket()
                Thread.sleep(500)
                continue
            }
            if (!hasBluetoothPermission()) {
                closeBluetoothServerSocket()
                Thread.sleep(1000)
                continue
            }

            val adapter = getBluetoothAdapter()
            if (adapter == null || !adapter.isEnabled) {
                closeBluetoothServerSocket()
                Thread.sleep(1000)
                continue
            }

            try {
                val server = ensureBluetoothServerSocket(adapter)
                val client = server.accept()
                activeBluetoothClients.incrementAndGet()
                lastPiClientSeenMs = System.currentTimeMillis()
                Executors.newSingleThreadExecutor().execute { handleBluetoothClient(client) }
            } catch (_: Exception) {
                closeBluetoothServerSocket()
                if (running) Thread.sleep(500)
            }
        }
        closeBluetoothServerSocket()
    }

    private fun handleBluetoothClient(sock: BluetoothSocket) {
        try {
            sock.use { s ->
                val out = BufferedWriter(OutputStreamWriter(s.outputStream))
                val reader = BufferedReader(InputStreamReader(s.inputStream))
                while (running && isBluetoothTransportEnabled() && s.isConnected) {
                    try {
                        if (reader.ready()) {
                            reader.readLine()
                        }
                        val payload = collectOnce()
                        if (payload != null) {
                            out.write(payload)
                            out.newLine()
                            out.flush()
                            lastPiClientSeenMs = System.currentTimeMillis()
                            lastStreamWriteMs = System.currentTimeMillis()
                            broadcast(payload)
                        }
                    } catch (_: Exception) {
                        break
                    }
                    Thread.sleep(2000)
                }
            }
        } finally {
            val remaining = activeBluetoothClients.decrementAndGet()
            if (remaining < 0) activeBluetoothClients.set(0)
        }
    }

    private fun handleNmeaClient(sock: Socket) {
        try {
            sock.use { s ->
                val out = BufferedWriter(OutputStreamWriter(s.getOutputStream()))
                while (running && !s.isClosed) {
                    try {
                        val fix = lastFix
                        if (fix != null && fix.latitude != 0.0 && fix.longitude != 0.0) {
                            val sentences = buildNmeaSentences(fix, satelliteCount)
                            for (line in sentences) {
                                out.write(line)
                                out.newLine()
                            }
                            out.flush()
                            lastPiClientSeenMs = System.currentTimeMillis()
                        }
                    } catch (_: Exception) {
                        // Exit the worker when the client disconnects to avoid zombie threads.
                        break
                    }
                    Thread.sleep(1000)
                }
            }
        } finally {
            val remaining = activeNmeaClients.decrementAndGet()
            if (remaining < 0) activeNmeaClients.set(0)
        }
    }

    private fun ensureStreamServerSocket(): ServerSocket {
        val existing = streamServerSocket
        if (existing != null && !existing.isClosed) return existing
        val server = ServerSocket(port).apply {
            reuseAddress = true
            soTimeout = 2000
        }
        streamServerSocket = server
        return server
    }

    private fun closeStreamServerSocket() {
        try {
            streamServerSocket?.close()
        } catch (_: Exception) {
        } finally {
            streamServerSocket = null
        }
    }

    private fun ensureNmeaServerSocket(): ServerSocket {
        val existing = nmeaServerSocket
        if (existing != null && !existing.isClosed) return existing
        val server = ServerSocket(nmeaPort).apply {
            reuseAddress = true
            soTimeout = 2000
        }
        nmeaServerSocket = server
        return server
    }

    private fun closeNmeaServerSocket() {
        try {
            nmeaServerSocket?.close()
        } catch (_: Exception) {
        } finally {
            nmeaServerSocket = null
        }
    }

    private fun ensureBluetoothServerSocket(adapter: BluetoothAdapter): BluetoothServerSocket {
        val existing = bluetoothServerSocket
        if (existing != null) return existing
        // Prefer insecure RFCOMM to avoid mandatory pairing/bonding on headless Pi bridges.
        val server = adapter.listenUsingInsecureRfcommWithServiceRecord(BT_SERVICE_NAME, SPP_UUID)
        bluetoothServerSocket = server
        return server
    }

    private fun closeBluetoothServerSocket() {
        try {
            bluetoothServerSocket?.close()
        } catch (_: Exception) {
        } finally {
            bluetoothServerSocket = null
        }
    }

    private fun getBluetoothAdapter(): BluetoothAdapter? {
        val bm = getSystemService(BLUETOOTH_SERVICE) as? BluetoothManager
        return bm?.adapter
    }

    private fun hasBluetoothPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun broadcast(payload: String) {
        val intent = Intent(ACTION_CELL_UPDATE).apply {
            putExtra(EXTRA_PAYLOAD, payload)
            setPackage(packageName)
        }
        sendBroadcast(intent)
    }

    private fun collectOnce(): String? {
        val tm = telephonyManager ?: return null
        val loc = getSystemService(LOCATION_SERVICE) as LocationManager

        val hasLocationPerm = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
                checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!hasLocationPerm) {
            return statusPayload("no_permission")
        }
        if (!loc.isProviderEnabled(LocationManager.GPS_PROVIDER) && !loc.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
            return statusPayload("location_disabled")
        }

        val cellEnabled = prefs.getBoolean("stream_cellular", true)
        val gpsEnabled = prefs.getBoolean("stream_gps", true)

        val infos = if (cellEnabled) fetchCells(tm) else emptyList()
        val bestLoc = if (gpsEnabled) selectBestLocation(lastFix, getBestLocation(loc)) else null
        val arr = JSONArray()
        infos?.forEach { ci ->
            when (ci) {
                is CellInfoLte -> lteJson(ci)?.let { arr.put(it) }
                is CellInfoWcdma -> wcdmaJson(ci)?.let { arr.put(it) }
                is CellInfoGsm -> gsmJson(ci)?.let { arr.put(it) }
                is CellInfoNr -> nrJson(ci)?.let { arr.put(it) }
            }
        }
        if (arr.length() == 0 && bestLoc == null) {
            return statusPayload("no_cells")
        }
        val root = JSONObject()
        root.put("ts", System.currentTimeMillis() / 1000.0)
        root.put("network_name", tm.networkOperatorName ?: "")
        root.put("network_type", networkTypeToString(tm.dataNetworkType))
        bestLoc?.let { l ->
            root.put("lat", l.latitude)
            root.put("lon", l.longitude)
            if (l.hasAltitude()) root.put("alt_m", l.altitude)
            if (l.hasSpeed()) root.put("speed_mps", l.speed)
            if (l.hasBearing()) root.put("bearing_deg", l.bearing)
            if (l.hasAccuracy()) root.put("accuracy_m", l.accuracy)
            root.put("provider", l.provider ?: JSONObject.NULL)
            lastFix = android.location.Location(l)
        }
        satelliteCount?.let { root.put("satellites", it) }
        root.put("cells", arr)
        appendStreamHealth(root)
        return root.toString()
    }

    private fun statusPayload(status: String): String {
        val root = JSONObject()
        root.put("ts", System.currentTimeMillis() / 1000.0)
        root.put("status", status)
        appendStreamHealth(root)
        return root.toString()
    }

    private fun appendStreamHealth(root: JSONObject) {
        val now = System.currentTimeMillis()
        val streamClients = activeStreamClients.get().coerceAtLeast(0)
        val nmeaClients = activeNmeaClients.get().coerceAtLeast(0)
        val btClients = activeBluetoothClients.get().coerceAtLeast(0)
        val totalClients = streamClients + nmeaClients + btClients
        val lastWrite = lastStreamWriteMs
        val ageMs = if (lastWrite > 0L) now - lastWrite else Long.MAX_VALUE
        val seenRecently = lastPiClientSeenMs > 0L && (now - lastPiClientSeenMs) <= 10_000L
        // Healthy means we have an active stream client and writes are succeeding recently.
        val streamOk = (streamClients + btClients) > 0 && ageMs <= 6000L
        val piConnected = totalClients > 0 || seenRecently
        val listenerEvents = listenerEventCount.get().coerceAtLeast(0)
        val listenerAgeMs =
            if (lastListenerEventMs > 0L) now - lastListenerEventMs else Long.MAX_VALUE
        val listenerLive = listenerAgeMs <= 10_000L

        root.put("stream_clients", streamClients)
        root.put("bt_clients", btClients)
        root.put("nmea_clients", nmeaClients)
        root.put("total_clients", totalClients)
        root.put("transport_mode", currentTransportMode())
        root.put("pi_service_running", piConnected)
        root.put("pi_connected", piConnected)
        root.put("stream_ok", streamOk)
        root.put("cell_listener_registered", listenerRegistered)
        root.put("cell_listener_events", listenerEvents)
        root.put("cell_listener_live", listenerLive)
        if (lastListenerEventMs > 0L) {
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

    private fun selectBestLocation(
        liveFix: android.location.Location?,
        fallbackFix: android.location.Location?
    ): android.location.Location? {
        if (liveFix == null) return fallbackFix
        if (fallbackFix == null) return liveFix
        return if (liveFix.time >= fallbackFix.time) liveFix else fallbackFix
    }

    private fun fetchCells(tm: TelephonyManager): List<CellInfo>? {
        // Try async requestCellInfoUpdate for fresher data; fall back to allCellInfo.
        val latch = CountDownLatch(1)
        var result: List<CellInfo>? = null
        try {
            tm.requestCellInfoUpdate(mainExecutor, object : TelephonyManager.CellInfoCallback() {
                override fun onCellInfo(cellInfo: MutableList<CellInfo>) {
                    result = cellInfo
                    latch.countDown()
                }
            })
            latch.await(1, TimeUnit.SECONDS)
        } catch (_: Exception) {
            // ignore and fall back
        }
        if (result != null && result!!.isNotEmpty()) return result
        return tm.allCellInfo
    }

    private fun registerPhoneListener() {
        val tm = telephonyManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val callback = object : TelephonyCallback(), TelephonyCallback.CellInfoListener {
                    override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>) {
                        handleCellInfoChanged(cellInfo, tm)
                    }
                }
                telephonyCallback = callback
                tm.registerTelephonyCallback(mainExecutor, callback)
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Suppress("OVERRIDE_DEPRECATION")
                    override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>?) {
                        super.onCellInfoChanged(cellInfo)
                        handleCellInfoChanged(cellInfo, tm)
                    }
                }
                phoneStateListener = listener
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CELL_INFO)
            }
            listenerRegistered = true
        } catch (_: SecurityException) {
            listenerRegistered = false
            // ignored
        }
    }

    private fun handleCellInfoChanged(cellInfo: List<CellInfo>?, tm: TelephonyManager) {
        lastListenerEventMs = System.currentTimeMillis()
        listenerEventCount.incrementAndGet()
        if (!prefs.getBoolean("stream_cellular", true)) return
        if (cellInfo.isNullOrEmpty()) return

        val arr = JSONArray()
        cellInfo.forEach { ci ->
            when (ci) {
                is CellInfoLte -> lteJson(ci)?.let { arr.put(it) }
                is CellInfoWcdma -> wcdmaJson(ci)?.let { arr.put(it) }
                is CellInfoGsm -> gsmJson(ci)?.let { arr.put(it) }
                is CellInfoNr -> nrJson(ci)?.let { arr.put(it) }
            }
        }
        if (arr.length() == 0) return

        val root = JSONObject()
        root.put("ts", System.currentTimeMillis() / 1000.0)
        root.put("network_name", tm.networkOperatorName ?: "")
        root.put("cells", arr)
        appendStreamHealth(root)
        broadcast(root.toString())
    }

    private fun lteJson(ci: CellInfoLte): JSONObject? {
        val id = ci.cellIdentity
        val ss = ci.cellSignalStrength
        fun validDbm(v: Int): Int? =
            if (v == CellInfo.UNAVAILABLE || v == Int.MAX_VALUE) null else v

        val eci = id.ci
        val enb = if (eci > 0) eci / 256 else null
        val sector = if (eci > 0) eci % 256 else null
        val dlUl = lteFreqsMhz(id.earfcn, earfcnToBandLte(id.earfcn))
        val obj = JSONObject()
        obj.put("rat", "LTE")
        obj.put("registered", ci.isRegistered)
        obj.put("mcc", id.mccString ?: JSONObject.NULL)
        obj.put("mnc", id.mncString ?: JSONObject.NULL)
        obj.put("tac", id.tac)
        obj.put("cid", eci)
        obj.put("full_cell_id", eci) // LTE ECI as full Cell ID
        obj.put("enb_id", enb ?: JSONObject.NULL)
        obj.put("sector_id", sector ?: JSONObject.NULL)
        obj.put("earfcn", id.earfcn)
        obj.put("band", earfcnToBandLte(id.earfcn) ?: JSONObject.NULL)
        obj.put("bandwidth_khz", id.bandwidth)
        obj.put("dl_freq_mhz", dlUl?.first ?: JSONObject.NULL)
        obj.put("ul_freq_mhz", dlUl?.second ?: JSONObject.NULL)
        obj.put("pci", id.pci)
        // Android does not expose LTE RSSI separately; fall back to any available dBm/RSRP so UI never shows null.
        val rssi = validDbm(ss.rssi) ?: validDbm(ss.dbm) ?: validDbm(ss.rsrp)
        obj.put("rssi", rssi ?: JSONObject.NULL)
        obj.put("rsrp", ss.rsrp)
        obj.put("rsrq", ss.rsrq)
        obj.put("snr", ss.rssnr)
        obj.put("timing_advance", ss.timingAdvance)
        obj.put("vqi", JSONObject.NULL)  // Not exposed via public API
        return obj
    }

    private fun wcdmaJson(ci: CellInfoWcdma): JSONObject? {
        val id = ci.cellIdentity
        val ss = ci.cellSignalStrength
        val obj = JSONObject()
        obj.put("rat", "WCDMA")
        obj.put("registered", ci.isRegistered)
        obj.put("mcc", id.mccString ?: JSONObject.NULL)
        obj.put("mnc", id.mncString ?: JSONObject.NULL)
        obj.put("lac", id.lac)
        obj.put("cid", id.cid)
        obj.put("full_cell_id", id.cid)
        obj.put("uarfcn", id.uarfcn)
        obj.put("psc", id.psc)
        obj.put("rscp", ss.dbm)
        obj.put("rssi", ss.dbm) // use RSCP dBm as RSSI proxy for display consistency
        return obj
    }

    private fun gsmJson(ci: CellInfoGsm): JSONObject? {
        val id = ci.cellIdentity
        val ss = ci.cellSignalStrength
        val obj = JSONObject()
        obj.put("rat", "GSM")
        obj.put("registered", ci.isRegistered)
        obj.put("mcc", id.mccString ?: JSONObject.NULL)
        obj.put("mnc", id.mncString ?: JSONObject.NULL)
        obj.put("lac", id.lac)
        obj.put("cid", id.cid)
        obj.put("full_cell_id", id.cid)
        obj.put("arfcn", id.arfcn)
        obj.put("bsic", id.bsic)
        obj.put("rssi", ss.dbm)
        return obj
    }

    private fun nrJson(ci: CellInfoNr): JSONObject? {
        val ss = ci.cellSignalStrength as CellSignalStrengthNr
        val id = ci.cellIdentity as CellIdentityNr
        fun validDbm(v: Int): Int? =
            if (v == CellInfo.UNAVAILABLE || v == Int.MAX_VALUE) null else v
        val obj = JSONObject()
        obj.put("rat", "NR")
        obj.put("registered", ci.isRegistered)
        obj.put("mcc", id.mccString ?: JSONObject.NULL)
        obj.put("mnc", id.mncString ?: JSONObject.NULL)
        obj.put("nci", id.nci)
        obj.put("full_cell_id", id.nci)
        obj.put("tac", id.tac)
        obj.put("pci", id.pci)
        obj.put("nrarfcn", id.nrarfcn)
        obj.put("ss_rsrp", ss.ssRsrp)
        obj.put("ss_rsrq", ss.ssRsrq)
        obj.put("ss_sinr", ss.ssSinr)
        // No RSSI for NR in public API; use SS-RSRP/CSI-RSRP as a proxy so the UI has a numeric value.
        val rssi = validDbm(ss.csiRsrp) ?: validDbm(ss.ssRsrp)
        obj.put("rssi", rssi ?: JSONObject.NULL)
        return obj
    }

    private fun getBestLocation(lm: LocationManager): android.location.Location? {
        val providers = lm.getProviders(true)
        var best: android.location.Location? = null
        for (p in providers) {
            try {
                val l = lm.getLastKnownLocation(p) ?: continue
                val currentBest = best
                if (currentBest == null) {
                    best = l
                } else {
                    // Prefer newer; if similar time, prefer better accuracy
                    val newer = l.time > currentBest.time
                    val betterAcc = l.hasAccuracy() && currentBest.hasAccuracy() &&
                        l.accuracy < currentBest.accuracy
                    if (newer || betterAcc) best = l
                }
            } catch (_: SecurityException) {
            }
        }
        return best
    }

    private fun registerGnss() {
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        val cb = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                satelliteCount = status.satelliteCount
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                lm.registerGnssStatusCallback(mainExecutor, cb)
            } else {
                @Suppress("DEPRECATION")
                lm.registerGnssStatusCallback(cb)
            }
            gnssCallback = cb
        } catch (_: SecurityException) {
        }
    }

    private fun registerLocationUpdates() {
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        val listener = LocationListener { location: Location ->
            if (location.latitude == 0.0 && location.longitude == 0.0) return@LocationListener
            // Keep the freshest GNSS/network fix so payloads and NMEA stream follow device movement.
            lastFix = android.location.Location(location)
        }

        requestProviderUpdates(lm, LocationManager.GPS_PROVIDER, listener)
        requestProviderUpdates(lm, LocationManager.NETWORK_PROVIDER, listener)
        requestProviderUpdates(lm, LocationManager.PASSIVE_PROVIDER, listener)
        locationListener = listener
    }

    private fun requestProviderUpdates(
        lm: LocationManager,
        provider: String,
        listener: LocationListener
    ) {
        try {
            if (!lm.allProviders.contains(provider)) return
            lm.requestLocationUpdates(provider, 1000L, 0f, listener, mainLooper)
        } catch (_: SecurityException) {
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun networkTypeToString(type: Int): String {
        return when (type) {
            TelephonyManager.NETWORK_TYPE_LTE -> "LTE"
            TelephonyManager.NETWORK_TYPE_NR -> "NR"
            TelephonyManager.NETWORK_TYPE_HSPAP -> "HSPAP"
            TelephonyManager.NETWORK_TYPE_HSPA -> "HSPA"
            TelephonyManager.NETWORK_TYPE_HSDPA -> "HSDPA"
            TelephonyManager.NETWORK_TYPE_HSUPA -> "HSUPA"
            TelephonyManager.NETWORK_TYPE_UMTS -> "UMTS"
            TelephonyManager.NETWORK_TYPE_EDGE -> "EDGE"
            TelephonyManager.NETWORK_TYPE_GPRS -> "GPRS"
            TelephonyManager.NETWORK_TYPE_EVDO_0 -> "EVDO_0"
            TelephonyManager.NETWORK_TYPE_EVDO_A -> "EVDO_A"
            TelephonyManager.NETWORK_TYPE_EVDO_B -> "EVDO_B"
            TelephonyManager.NETWORK_TYPE_1xRTT -> "1xRTT"
            TelephonyManager.NETWORK_TYPE_EHRPD -> "EHRPD"
            TelephonyManager.NETWORK_TYPE_GSM -> "GSM"
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "TD_SCDMA"
            TelephonyManager.NETWORK_TYPE_IWLAN -> "IWLAN"
            else -> "UNKNOWN"
        }
    }

    private fun currentTransportMode(): String {
        val mode = prefs.getString(KEY_TRANSPORT_MODE, TRANSPORT_USB) ?: TRANSPORT_USB
        return when (mode) {
            TRANSPORT_USB, TRANSPORT_BLUETOOTH, TRANSPORT_BOTH -> mode
            else -> TRANSPORT_USB
        }
    }

    private fun isUsbTransportEnabled(): Boolean {
        return when (currentTransportMode()) {
            TRANSPORT_USB, TRANSPORT_BOTH -> true
            else -> false
        }
    }

    private fun isBluetoothTransportEnabled(): Boolean {
        return when (currentTransportMode()) {
            TRANSPORT_BLUETOOTH, TRANSPORT_BOTH -> true
            else -> false
        }
    }

    private fun lteFreqsMhz(earfcn: Int, band: Int?): Pair<Double, Double>? {
        if (earfcn <= 0 || band == null) return null
        // Minimal band definitions: NoffsDL, NoffsUL, FDL_low, FUL_low
        val table: Map<Int, Quadruple> = mapOf(
            1 to Quadruple(0, 18000, 2110.0, 1920.0),
            2 to Quadruple(600, 18600, 1930.0, 1850.0),
            3 to Quadruple(1200, 19200, 1805.0, 1710.0),
            4 to Quadruple(1950, 19950, 2110.0, 1710.0),
            5 to Quadruple(2400, 20400, 869.0, 824.0),
            7 to Quadruple(2750, 20750, 2620.0, 2500.0),
            12 to Quadruple(5010, 23010, 729.0, 699.0),
            13 to Quadruple(5180, 23180, 746.0, 777.0),
            17 to Quadruple(5730, 23730, 734.0, 704.0),
            20 to Quadruple(6150, 24150, 791.0, 832.0),
            25 to Quadruple(8040, 24440, 1930.0, 1850.0),
            26 to Quadruple(8690, 24690, 859.0, 814.0),
            28 to Quadruple(9210, 25210, 758.0, 703.0),
            66 to Quadruple(66436 - 65536, 131436 - 65536, 2110.0, 1710.0), // reuse band 4 anchors
            71 to Quadruple(68586 - 65536, 133586 - 65536, 617.0, 663.0)
        )
        val def = table[band] ?: return null
        val dl = def.fdlLow + 0.1 * (earfcn - def.noffsDl)
        val ul = def.fulLow + 0.1 * (earfcn - def.noffsUl)
        return Pair(dl, ul)
    }

    private data class Quadruple(val noffsDl: Int, val noffsUl: Int, val fdlLow: Double, val fulLow: Double)

    private fun earfcnToBandLte(earfcn: Int): Int? {
        if (earfcn <= 0) return null
        val ranges = listOf(
            Triple(0, 599, 1),
            Triple(1200, 1949, 3),
            Triple(1950, 2399, 4),
            Triple(2400, 2649, 5),
            Triple(2750, 3449, 7),
            Triple(3450, 3799, 8),
            Triple(36200, 36349, 11),
            Triple(36950, 37549, 12),
            Triple(37750, 38249, 13),
            Triple(38250, 38649, 14),
            Triple(39650, 41589, 17),
            Triple(41590, 43589, 18),
            Triple(43590, 45589, 19),
            Triple(45590, 46589, 20),
            Triple(46990, 47889, 21),
            Triple(48200, 48899, 22),
            Triple(49200, 50009, 23),
            Triple(50100, 50349, 24),
            Triple(51440, 52339, 26),
            Triple(52340, 52739, 27),
            Triple(52740, 53739, 28),
            Triple(54540, 55239, 29),
            Triple(55240, 56739, 30),
            Triple(57340, 58339, 31),
            Triple(9870, 10769, 66),
            Triple(65636, 67335, 71)
        )
        return ranges.firstOrNull { earfcn in it.first..it.second }?.third
    }

    private fun buildNmeaSentences(loc: android.location.Location, sats: Int?): List<String> {
        val utc = java.util.Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            timeInMillis = if (loc.time > 0) loc.time else System.currentTimeMillis()
        }
        val timeStr = String.format(
            Locale.US,
            "%02d%02d%02d",
            utc.get(java.util.Calendar.HOUR_OF_DAY),
            utc.get(java.util.Calendar.MINUTE),
            utc.get(java.util.Calendar.SECOND)
        )
        val dateStr = String.format(
            Locale.US,
            "%02d%02d%02d",
            utc.get(java.util.Calendar.DAY_OF_MONTH),
            utc.get(java.util.Calendar.MONTH) + 1,
            (utc.get(java.util.Calendar.YEAR) % 100)
        )
        val (latStr, latHem) = formatNmeaCoord(loc.latitude, true)
        val (lonStr, lonHem) = formatNmeaCoord(loc.longitude, false)
        val numSats = sats ?: 8
        val hdop = if (loc.hasAccuracy() && loc.accuracy > 0) loc.accuracy / 5.0 else 1.0
        val alt = if (loc.hasAltitude()) loc.altitude else 0.0
        val speedKnots = if (loc.hasSpeed()) loc.speed * 1.943844 else 0.0
        val course = if (loc.hasBearing()) loc.bearing else 0.0

        val ggaCore = String.format(
            Locale.US,
            "GPGGA,%s,%s,%s,%s,%s,1,%02d,%.1f,%.1f,M,0.0,M,,",
            timeStr,
            latStr,
            latHem,
            lonStr,
            lonHem,
            numSats,
            hdop,
            alt
        )
        val rmcCore = String.format(
            Locale.US,
            "GPRMC,%s,A,%s,%s,%s,%s,%.1f,%.1f,%s,,",
            timeStr,
            latStr,
            latHem,
            lonStr,
            lonHem,
            speedKnots,
            course,
            dateStr
        )
        return listOf(
            "\$${ggaCore}*${checksum(ggaCore)}",
            "\$${rmcCore}*${checksum(rmcCore)}"
        )
    }

    private fun formatNmeaCoord(value: Double, isLat: Boolean): Pair<String, String> {
        val hemi = if (isLat) {
            if (value >= 0) "N" else "S"
        } else {
            if (value >= 0) "E" else "W"
        }
        val absVal = abs(value)
        val deg = absVal.toInt()
        val minutes = (absVal - deg) * 60.0
        val fmt = if (isLat) "%02d%07.4f" else "%03d%07.4f"
        val coord = String.format(Locale.US, fmt, deg, minutes)
        return Pair(coord, hemi)
    }

    private fun checksum(sentence: String): String {
        var sum = 0
        sentence.forEach { ch -> sum = sum xor ch.code }
        return String.format(Locale.US, "%02X", sum and 0xFF)
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        running = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephonyCallback?.let { telephonyManager?.unregisterTelephonyCallback(it) }
            } else {
                @Suppress("DEPRECATION")
                phoneStateListener?.let { telephonyManager?.listen(it, PhoneStateListener.LISTEN_NONE) }
            }
        } catch (_: Exception) {
        }
        closeStreamServerSocket()
        closeNmeaServerSocket()
        closeBluetoothServerSocket()
        try {
            val lm = getSystemService(LOCATION_SERVICE) as LocationManager
            gnssCallback?.let { lm.unregisterGnssStatusCallback(it) }
            locationListener?.let { lm.removeUpdates(it) }
        } catch (_: Exception) {
        }
        scheduler.shutdownNow()
        exec.shutdownNow()
        nmeaExec.shutdownNow()
        btExec.shutdownNow()
        super.onDestroy()
    }
}
