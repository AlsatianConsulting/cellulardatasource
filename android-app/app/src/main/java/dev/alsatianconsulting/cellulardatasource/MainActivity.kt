package dev.alsatianconsulting.cellulardatasource

import android.Manifest
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.RadioGroup
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.appcompat.widget.SwitchCompat
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : AppCompatActivity() {
    companion object {
        private const val PREFS_NAME = "cellstream_prefs"
        private const val KEY_START_ON_BOOT = "start_on_boot"
        private const val KEY_TRANSPORT_MODE = "transport_mode"
        private const val TRANSPORT_USB = "usb"
        private const val TRANSPORT_BLUETOOTH = "bluetooth"
        private const val TRANSPORT_BOTH = "both"
    }

    private var running = false
    private lateinit var toggleBtn: Button
    private lateinit var settingsBtn: Button
    private lateinit var statusTxt: TextView
    private lateinit var cellInfoTxt: TextView
    private lateinit var gpsInfoTxt: TextView
    private lateinit var switchCell: SwitchCompat
    private lateinit var switchGps: SwitchCompat
    private lateinit var cellStatusLight: View
    private lateinit var gpsStatusLight: View
    private lateinit var cellStatusTxt: TextView
    private lateinit var gpsStatusTxt: TextView
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }
    private val devicePrefs by lazy {
        createDeviceProtectedStorageContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val cellUpdateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val payload = intent?.getStringExtra(CellStreamService.EXTRA_PAYLOAD) ?: return
            cellInfoTxt.text = formatDisplay(payload)
            gpsInfoTxt.text = formatGps(payload)
            updateStreamStatus(payload)
        }
    }

    private val reqPerm = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grant ->
        val ok = grant.values.all { it }
        if (ok) {
            requestBackgroundLocationIfNeeded()
            requestIgnoreBatteryOptimization()
            startStream()
        }
    }

    private val reqBgLocation = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { /* no-op */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        toggleBtn = findViewById(R.id.toggleButton)
        settingsBtn = findViewById(R.id.settingsButton)
        statusTxt = findViewById(R.id.statusText)
        cellInfoTxt = findViewById(R.id.cellInfoText)
        gpsInfoTxt = findViewById(R.id.gpsInfoText)
        switchCell = findViewById(R.id.switchCellToggle)
        switchGps = findViewById(R.id.switchGpsToggle)
        cellStatusLight = findViewById(R.id.cellStatusLight)
        gpsStatusLight = findViewById(R.id.gpsStatusLight)
        cellStatusTxt = findViewById(R.id.cellStatusText)
        gpsStatusTxt = findViewById(R.id.gpsStatusText)
        syncStartOnBootPreference()

        // initial styling for start state
        applyStartStyle()

        toggleBtn.setOnClickListener {
            if (running) stopStream() else ensurePermsAndStart()
        }

        settingsBtn.setOnClickListener { showSettingsDialog() }

        // Keep switches in sync with persisted prefs
        switchCell.isChecked = prefs.getBoolean("stream_cellular", true)
        switchGps.isChecked = prefs.getBoolean("stream_gps", true)
        switchCell.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean("stream_cellular", isChecked).apply()
            if (!isChecked) {
                setStatusIndicator(cellStatusLight, cellStatusTxt, false)
            }
        }
        switchGps.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean("stream_gps", isChecked).apply()
            if (!isChecked) {
                setStatusIndicator(gpsStatusLight, gpsStatusTxt, false)
            }
        }

        syncRunningStateFromService()
        setConnectionLights(cellConnected = false, gpsConnected = false)

        // Auto-start stream if the preference is enabled
        if (prefs.getBoolean("auto_start_stream", false) && !running) {
            ensurePermsAndStart()
        }
    }

    private fun ensurePermsAndStart() {
        val needed = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.READ_PHONE_STATE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && usesBluetoothTransport()) {
            needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            reqPerm.launch(missing.toTypedArray())
        } else {
            requestBackgroundLocationIfNeeded()
            requestIgnoreBatteryOptimization()
            startStream()
        }
    }

    private fun requestBackgroundLocationIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val granted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                reqBgLocation.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            }
        }
    }

    private fun requestIgnoreBatteryOptimization() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val pkg = packageName
        if (!pm.isIgnoringBatteryOptimizations(pkg)) {
            try {
                startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$pkg")
                    }
                )
            } catch (_: Exception) {
                // ignore if not available
            }
        }
    }

    private fun formatDisplay(payload: String): String {
        return try {
            val root = JSONObject(payload)
            if (root.has("status")) {
                "Status: ${root.getString("status")}"
            } else {
                val cells = root.optJSONArray("cells") ?: JSONArray()
                if (cells.length() == 0) return "No cells"
                val chosen = chooseCell(cells)
                if (chosen == null) {
                    "No cells"
                } else {
                    buildString {
                        val netName = root.optString("network_name", "")
                        val netType = root.optString("network_type", "UNKNOWN")
                        if (netName.isNotEmpty()) appendLine("Network: $netName")
                        appendLine("Technology: $netType")
                        appendLine("MCC: ${chosen.optString("mcc", "N/A")}")
                        appendLine("MNC: ${chosen.optString("mnc", "N/A")}")
                        val lac = when {
                            chosen.has("tac") -> chosen.optString("tac")
                            chosen.has("lac") -> chosen.optString("lac")
                            else -> "N/A"
                        }
                        appendLine("LAC/TAC: $lac")
                        appendLine("Cell ID: ${chosen.optString("cid", "N/A")}")
                        appendLine("eNB ID: ${chosen.optString("enb_id", "N/A")}")
                        appendLine("PCI: ${chosen.optString("pci", "N/A")}")
                        appendLine("CQI: N/A")
                        appendLine("Timing Advance: ${chosen.optString("timing_advance", "N/A")}")
                        val arfcn = when {
                            chosen.has("earfcn") -> chosen.optString("earfcn")
                            chosen.has("arfcn") -> chosen.optString("arfcn")
                            chosen.has("nrarfcn") -> chosen.optString("nrarfcn")
                            else -> "N/A"
                        }
                        appendLine("ARFCN: $arfcn")
                        appendLine("RSSI: ${chosen.optString("rssi", "N/A")}")
                        val rsrp = if (chosen.has("rsrp")) chosen.optString("rsrp") else chosen.optString("ss_rsrp", "N/A")
                        val rsrq = if (chosen.has("rsrq")) chosen.optString("rsrq") else chosen.optString("ss_rsrq", "N/A")
                        val snr = if (chosen.has("snr")) chosen.optString("snr") else chosen.optString("ss_sinr", "N/A")
                        appendLine("RSRP: $rsrp")
                        appendLine("RSRQ: $rsrq")
                        appendLine("SNR: $snr")
                    }
                }
            }
        } catch (_: Exception) {
            "Parse error"
        }
    }

    private fun formatGps(payload: String): String {
        return try {
            val root = JSONObject(payload)
            val lat = root.optDouble("lat", Double.NaN)
            val lon = root.optDouble("lon", Double.NaN)
            val acc = if (root.has("accuracy_m")) root.optDouble("accuracy_m", Double.NaN) else Double.NaN
            val sats = if (root.has("satellites")) root.optInt("satellites") else -1
            buildString {
                appendLine()
                appendLine()
                appendLine("GPS:")
                appendLine("Lat/Lon: ${if (lat.isNaN() || lon.isNaN()) "N/A" else "$lat, $lon"}")
                appendLine("Accuracy (m): ${if (acc.isNaN()) "N/A" else acc}")
                appendLine("Satellites: ${if (sats >= 0) sats else "N/A"}")
            }
        } catch (_: Exception) {
            ""
        }
    }

    private fun chooseCell(cells: JSONArray): JSONObject? {
        for (i in 0 until cells.length()) {
            val obj = cells.optJSONObject(i) ?: continue
            if (obj.optBoolean("registered", false)) return obj
        }
        return cells.optJSONObject(0)
    }

    private fun showSettingsDialog() {
        val view = LayoutInflater.from(this).inflate(R.layout.dialog_settings, null)
        val transportGroup = view.findViewById<RadioGroup>(R.id.transportModeGroup)
        val swCell = view.findViewById<SwitchCompat>(R.id.switchStreamCell)
        val swGps = view.findViewById<SwitchCompat>(R.id.switchStreamGps)
        val swAuto = view.findViewById<SwitchCompat>(R.id.switchAutoStart)
        val swBoot = view.findViewById<SwitchCompat>(R.id.switchStartOnBoot)

        when (currentTransportMode()) {
            TRANSPORT_BLUETOOTH -> transportGroup.check(R.id.radioTransportBluetooth)
            TRANSPORT_BOTH -> transportGroup.check(R.id.radioTransportBoth)
            else -> transportGroup.check(R.id.radioTransportUsb)
        }
        swCell.isChecked = prefs.getBoolean("stream_cellular", true)
        swGps.isChecked = prefs.getBoolean("stream_gps", true)
        swAuto.isChecked = prefs.getBoolean("auto_start_stream", false)
        swBoot.isChecked = prefs.getBoolean("start_on_boot", false)

        transportGroup.setOnCheckedChangeListener { _, checkedId ->
            val mode = when (checkedId) {
                R.id.radioTransportBluetooth -> TRANSPORT_BLUETOOTH
                R.id.radioTransportBoth -> TRANSPORT_BOTH
                else -> TRANSPORT_USB
            }
            prefs.edit().putString(KEY_TRANSPORT_MODE, mode).apply()
        }
        swCell.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean("stream_cellular", isChecked).apply()
        }
        swGps.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean("stream_gps", isChecked).apply()
        }
        swAuto.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean("auto_start_stream", isChecked).apply()
            if (isChecked && !running) ensurePermsAndStart()
        }
        swBoot.setOnCheckedChangeListener { _, isChecked ->
            setStartOnBootPreference(isChecked)
        }

        AlertDialog.Builder(this)
            .setTitle("Settings")
            .setView(view)
            .setPositiveButton("Close", null)
            .show()
    }

    private fun updateStreamStatus(payload: String) {
        if (!running) {
            running = true
            applyRunningStyle()
        }
        statusTxt.text = runningStatusText()
        try {
            val root = JSONObject(payload)
            val streamClients = root.optInt("stream_clients", -1)
            val bluetoothClients = root.optInt("bt_clients", -1)
            val nmeaClients = root.optInt("nmea_clients", -1)
            val piConnected = root.optBoolean(
                "pi_connected",
                root.optBoolean("pi_service_running", false)
            )
            val primaryStreamClients = maxOf(streamClients, 0) + maxOf(bluetoothClients, 0)

            val cellConnected = if (streamClients >= 0 || bluetoothClients >= 0) {
                primaryStreamClients > 0
            } else {
                piConnected
            }
            val gpsConnected = if (nmeaClients >= 0) {
                nmeaClients > 0 || primaryStreamClients > 0
            } else {
                piConnected
            }
            setConnectionLights(cellConnected = cellConnected, gpsConnected = gpsConnected)
        } catch (_: Exception) {
            setConnectionLights(cellConnected = false, gpsConnected = false)
        }
    }

    private fun setConnectionLights(cellConnected: Boolean, gpsConnected: Boolean) {
        setStatusIndicator(cellStatusLight, cellStatusTxt, switchCell.isChecked && cellConnected)
        setStatusIndicator(gpsStatusLight, gpsStatusTxt, switchGps.isChecked && gpsConnected)
    }

    private fun setStatusIndicator(indicator: View, label: TextView, connected: Boolean) {
        val colorId = if (connected) R.color.status_green else R.color.status_red
        val color = ContextCompat.getColor(this, colorId)
        indicator.backgroundTintList = ColorStateList.valueOf(color)
        label.text = if (connected) "Connected" else "Not Connected"
        label.setTextColor(color)
    }

    private fun setStartOnBootPreference(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_START_ON_BOOT, enabled).apply()
        devicePrefs.edit().putBoolean(KEY_START_ON_BOOT, enabled).apply()
    }

    private fun runningStatusText(): String {
        return "Stream running"
    }

    private fun syncStartOnBootPreference() {
        val ceValue = prefs.getBoolean(KEY_START_ON_BOOT, false)
        val deValue = devicePrefs.getBoolean(KEY_START_ON_BOOT, false)
        if (ceValue != deValue) {
            devicePrefs.edit().putBoolean(KEY_START_ON_BOOT, ceValue).apply()
        }
    }

    private fun currentTransportMode(): String {
        return prefs.getString(KEY_TRANSPORT_MODE, TRANSPORT_USB) ?: TRANSPORT_USB
    }

    private fun usesBluetoothTransport(): Boolean {
        return when (currentTransportMode()) {
            TRANSPORT_BLUETOOTH, TRANSPORT_BOTH -> true
            else -> false
        }
    }

    private fun startStream() {
        ContextCompat.startForegroundService(
            this,
            Intent(this, CellStreamService::class.java)
        )
        running = true
        statusTxt.text = runningStatusText()
        setConnectionLights(cellConnected = false, gpsConnected = false)
        applyRunningStyle()
    }

    private fun stopStream() {
        stopService(Intent(this, CellStreamService::class.java))
        running = false
        statusTxt.text = "Stream stopped"
        setConnectionLights(cellConnected = false, gpsConnected = false)
        toggleBtn.text = "Start Stream"
        applyStartStyle()
    }

    private fun applyStartStyle() {
        toggleBtn.background = ContextCompat.getDrawable(this, R.drawable.btn_start)
        toggleBtn.backgroundTintList = null
        toggleBtn.setTextColor(ContextCompat.getColor(this, R.color.orange_accent))
    }

    private fun applyRunningStyle() {
        toggleBtn.text = "Stop Stream"
        toggleBtn.background = ContextCompat.getDrawable(this, R.drawable.btn_stop)
        toggleBtn.backgroundTintList = null
        toggleBtn.setTextColor(ContextCompat.getColor(this, R.color.black))
    }

    private fun syncRunningStateFromService() {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        val serviceRunning = am.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == CellStreamService::class.java.name
        }
        running = serviceRunning
        if (serviceRunning) {
            applyRunningStyle()
            statusTxt.text = runningStatusText()
            setConnectionLights(cellConnected = false, gpsConnected = false)
        } else {
            statusTxt.text = "Stream stopped"
            setConnectionLights(cellConnected = false, gpsConnected = false)
            toggleBtn.text = "Start Stream"
            applyStartStyle()
        }
    }

    override fun onStart() {
        super.onStart()
        ContextCompat.registerReceiver(
            this,
            cellUpdateReceiver,
            IntentFilter(CellStreamService.ACTION_CELL_UPDATE),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        syncRunningStateFromService()
        // Refresh toggles in case they were changed elsewhere (e.g., dialog)
        switchCell.isChecked = prefs.getBoolean("stream_cellular", true)
        switchGps.isChecked = prefs.getBoolean("stream_gps", true)
        // Show placeholder until first update arrives
        cellInfoTxt.text = "Waiting for cell data..."
    }

    override fun onStop() {
        unregisterReceiver(cellUpdateReceiver)
        super.onStop()
    }
}
