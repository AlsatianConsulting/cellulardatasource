package dev.alsatianconsulting.cellulardatasource

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.telephony.CellInfo
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class CellStreamService : Service() {
    companion object {
        private const val TAG = "CellStreamService"
        const val ACTION_CELL_UPDATE = "dev.alsatianconsulting.cellulardatasource.CELL_UPDATE"
        const val EXTRA_PAYLOAD = "payload"
        const val ACTION_SERVICE_STATE = "dev.alsatianconsulting.cellulardatasource.SERVICE_STATE"
        const val EXTRA_RUNNING = "running"

        private const val PREFS_NAME = "cellstream_prefs"
        private const val KEY_STREAM_CELL = "stream_cellular"
        const val KEY_SERVICE_RUNNING = "service_running"

        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "cellstream"
    }

    private val exec = Executors.newSingleThreadExecutor()
    private val nmeaExec = Executors.newSingleThreadExecutor()
    private val streamClientPool = Executors.newCachedThreadPool()
    private val nmeaClientPool = Executors.newCachedThreadPool()
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    @Volatile private var running = true

    private var telephonyManager: TelephonyManager? = null
    @Suppress("DEPRECATION")
    private var phoneStateListener: PhoneStateListener? = null
    private var telephonyCallback: TelephonyCallback? = null
    private var locationListener: LocationListener? = null
    private var gnssCallback: GnssStatus.Callback? = null

    private val prefs by lazy { getSharedPreferences(PREFS_NAME, MODE_PRIVATE) }
    private val prefsListener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        updateForegroundStatusNotification()
    }

    @Volatile private var lastFix: Location? = null
    @Volatile private var satelliteCount: Int? = null
    @Volatile private var listenerRegistered: Boolean = false
    private val listenerEventCount = AtomicInteger(0)
    @Volatile private var lastListenerEventMs: Long = 0L

    private lateinit var jsonServer: JsonStreamServer
    private lateinit var nmeaServer: NmeaStreamServer
    private lateinit var snapshot: CellSnapshot

    override fun onCreate() {
        super.onCreate()
        prefs.registerOnSharedPreferenceChangeListener(prefsListener)
        telephonyManager = getSystemService(TELEPHONY_SERVICE) as TelephonyManager

        // Servers reference snapshot via lateinit closure; snapshot is guaranteed
        // to be initialized before any lambda is invoked.
        jsonServer = JsonStreamServer(
            getRunning = { running },
            getPayload = { snapshot.collectOnce() },
            appendHealth = { root -> snapshot.appendStreamHealth(root) },
            broadcast = { text -> broadcast(text) },
            clientPool = streamClientPool,
        )
        nmeaServer = NmeaStreamServer(
            getRunning = { running },
            getLastFix = { lastFix },
            getSatellites = { satelliteCount },
            clientPool = nmeaClientPool,
        )
        snapshot = CellSnapshot(
            context = this,
            prefs = prefs,
            telephonyManager = telephonyManager,
            getLastFix = { lastFix },
            setLastFix = { lastFix = it },
            getSatellites = { satelliteCount },
            getStreamClients = { jsonServer.activeClients.get() },
            getNmeaClients = { nmeaServer.activeClients.get() },
            getLastWriteMs = { jsonServer.lastWriteMs },
            getLastActivityMs = { maxOf(jsonServer.lastActivityMs, nmeaServer.lastActivityMs) },
            isListenerRegistered = { listenerRegistered },
            getListenerEventCount = { listenerEventCount.get() },
            getLastListenerEventMs = { lastListenerEventMs },
        )

        setServiceRunningState(true)
        startForeground(NOTIFICATION_ID, notif())
        broadcastServiceState(true)

        registerGnss()
        registerLocationUpdates()
        registerPhoneListener()

        exec.execute { jsonServer.run() }
        nmeaExec.execute { nmeaServer.run() }
        scheduler.scheduleAtFixedRate({
            try {
                val payload = snapshot.collectOnce()
                snapshot.appendStreamHealth(payload)
                broadcast(payload.toString())
                updateForegroundStatusNotification()
            } catch (exc: Exception) {
                Log.e(TAG, "scheduled cell loop failed", exc)
            }
        }, 0, 2, TimeUnit.SECONDS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        setServiceRunningState(true)
        broadcastServiceState(true)
        return START_STICKY
    }

    private fun notif(): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    "CellularDatasource",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = PendingIntent.getActivity(this, 1001, openAppIntent, pendingFlags)
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(currentStreamingStatus())
            .setContentText("Attached local stream active")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(true)
            .build()
    }

    private fun currentStreamingStatus(): String {
        val cell = prefs.getBoolean(KEY_STREAM_CELL, true)
        val gps = prefs.getBoolean("stream_gps", true)
        return when {
            cell && gps -> "Streaming Cell+GPS"
            cell -> "Streaming Cell"
            gps -> "Streaming GPS"
            else -> "Not Streaming"
        }
    }

    private fun updateForegroundStatusNotification() {
        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notif())
    }

    private fun broadcast(payload: String) {
        val intent = Intent(ACTION_CELL_UPDATE).apply {
            putExtra(EXTRA_PAYLOAD, payload)
            setPackage(packageName)
        }
        sendBroadcast(intent)
    }

    private fun broadcastServiceState(isRunning: Boolean) {
        val intent = Intent(ACTION_SERVICE_STATE).apply {
            putExtra(EXTRA_RUNNING, isRunning)
            setPackage(packageName)
        }
        sendBroadcast(intent)
    }

    private fun setServiceRunningState(isRunning: Boolean) {
        try {
            prefs.edit().putBoolean(KEY_SERVICE_RUNNING, isRunning).apply()
            createDeviceProtectedStorageContext()
                .getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_SERVICE_RUNNING, isRunning)
                .apply()
        } catch (exc: Exception) {
            Log.w(TAG, "setServiceRunningState failed", exc)
        }
    }

    private fun registerPhoneListener() {
        val tm = telephonyManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val callback = object : TelephonyCallback(), TelephonyCallback.CellInfoListener {
                    override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>) {
                        handleCellInfoChanged(tm)
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
                        handleCellInfoChanged(tm)
                    }
                }
                phoneStateListener = listener
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CELL_INFO)
            }
            listenerRegistered = true
        } catch (_: SecurityException) {
            listenerRegistered = false
        }
    }

    private fun handleCellInfoChanged(tm: TelephonyManager) {
        lastListenerEventMs = System.currentTimeMillis()
        listenerEventCount.incrementAndGet()
        if (!prefs.getBoolean(KEY_STREAM_CELL, true)) return
        val root = JSONObject()
        root.put("ts", System.currentTimeMillis() / 1000.0)
        root.put("network_name", tm.networkOperatorName ?: "")
        root.put("network_type", snapshot.networkTypeToString(tm.dataNetworkType))
        root.put("cells", snapshot.fetchCellArray())
        lastFix?.let { loc ->
            root.put("lat", loc.latitude)
            root.put("lon", loc.longitude)
            if (loc.hasAltitude()) root.put("alt_m", loc.altitude)
            if (loc.hasAccuracy()) root.put("accuracy_m", loc.accuracy)
            root.put("provider", loc.provider ?: JSONObject.NULL)
        }
        satelliteCount?.let { root.put("satellites", it) }
        snapshot.appendStreamHealth(root)
        broadcast(root.toString())
    }

    private fun registerLocationUpdates() {
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        val listener = LocationListener { location -> lastFix = Location(location) }
        locationListener = listener
        try {
            for (provider in lm.getProviders(true)) {
                lm.requestLocationUpdates(provider, 1000L, 0f, listener)
            }
        } catch (exc: SecurityException) {
            Log.w(TAG, "location updates registration failed", exc)
        }
    }

    private fun registerGnss() {
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val lm = getSystemService(LOCATION_SERVICE) as LocationManager
            val callback = object : GnssStatus.Callback() {
                override fun onSatelliteStatusChanged(status: GnssStatus) {
                    satelliteCount = status.satelliteCount
                }
            }
            try {
                lm.registerGnssStatusCallback(callback)
                gnssCallback = callback
            } catch (exc: SecurityException) {
                Log.w(TAG, "GNSS status callback registration failed", exc)
            }
        }
    }

    override fun onDestroy() {
        running = false
        setServiceRunningState(false)
        broadcastServiceState(false)

        jsonServer.close()
        nmeaServer.close()
        scheduler.shutdownNow()

        try {
            prefs.unregisterOnSharedPreferenceChangeListener(prefsListener)
        } catch (exc: Exception) {
            Log.w(TAG, "prefs unregister failed", exc)
        }

        locationListener?.let { listener ->
            try {
                (getSystemService(LOCATION_SERVICE) as LocationManager).removeUpdates(listener)
            } catch (exc: Exception) {
                Log.w(TAG, "location updates removal failed", exc)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            gnssCallback?.let { cb ->
                try {
                    (getSystemService(LOCATION_SERVICE) as LocationManager).unregisterGnssStatusCallback(cb)
                } catch (exc: Exception) {
                    Log.w(TAG, "GNSS callback unregister failed", exc)
                }
            }
        }

        telephonyManager?.let { tm ->
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    telephonyCallback?.let { tm.unregisterTelephonyCallback(it) }
                } else {
                    @Suppress("DEPRECATION")
                    phoneStateListener?.let { tm.listen(it, PhoneStateListener.LISTEN_NONE) }
                }
            } catch (exc: Exception) {
                Log.w(TAG, "telephony unregister failed", exc)
            }
        }

        exec.shutdownNow()
        nmeaExec.shutdownNow()
        streamClientPool.shutdownNow()
        nmeaClientPool.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
