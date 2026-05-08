package dev.alsatianconsulting.cellulardatasource

import android.Manifest
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
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageButton
import android.widget.PopupMenu
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.ArrayDeque

class MainActivity : AppCompatActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val PREFS_NAME = "cellstream_prefs"
        private const val KEY_FIRST_RUN_PERMISSION_SETUP_SHOWN = "first_run_permission_setup_shown"
        private const val KEY_START_ON_BOOT = "start_on_boot"
        private const val KEY_LAUNCH_UI_ON_BOOT = "launch_ui_on_boot"
        private const val KEY_AUTO_START = "auto_start_stream"
        private const val KEY_STREAM_CELL = "stream_cellular"
        private const val KEY_STREAM_GPS = "stream_gps"
        private const val KEY_SERVICE_RUNNING = "service_running"
    }

    private data class PermissionStep(
        val title: String,
        val message: String,
        val permissions: List<String> = emptyList(),
        val intent: Intent? = null,
        val shouldRun: () -> Boolean = { true }
    )

    private var running = false
    private var startAfterPermissionFlow = false
    private val pendingPermissionSteps = ArrayDeque<PermissionStep>()
    private lateinit var toggleBtn: Button
    private lateinit var menuBtn: ImageButton
    private lateinit var statusTxt: TextView
    private lateinit var attachedStatusTxt: TextView
    private lateinit var cellInfoTxt: TextView
    private lateinit var gpsInfoTxt: TextView
    private lateinit var cellStatusLight: View
    private lateinit var gpsStatusLight: View
    private lateinit var cellStatusTxt: TextView
    private lateinit var gpsStatusTxt: TextView

    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }
    private val devicePrefs by lazy {
        createDeviceProtectedStorageContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val payloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                CellStreamService.ACTION_CELL_UPDATE -> {
                    val payload = intent.getStringExtra(CellStreamService.EXTRA_PAYLOAD) ?: return
                    renderPayload(payload)
                }
                CellStreamService.ACTION_SERVICE_STATE -> {
                    updateRunningStateUi(intent.getBooleanExtra(CellStreamService.EXTRA_RUNNING, false))
                }
            }
        }
    }

    private val reqPerms = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { continuePermissionFlow() }

    private val reqSettingsActivity = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { continuePermissionFlow() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        toggleBtn = findViewById(R.id.toggleButton)
        menuBtn = findViewById(R.id.menuButton)
        statusTxt = findViewById(R.id.statusText)
        attachedStatusTxt = findViewById(R.id.attachedStatusText)
        cellInfoTxt = findViewById(R.id.cellInfoText)
        gpsInfoTxt = findViewById(R.id.gpsInfoText)
        cellStatusLight = findViewById(R.id.cellStatusLight)
        gpsStatusLight = findViewById(R.id.gpsStatusLight)
        cellStatusTxt = findViewById(R.id.cellStatusText)
        gpsStatusTxt = findViewById(R.id.gpsStatusText)
        syncStartOnBootPreference()

        applyStartStyle()
        toggleBtn.setOnClickListener {
            if (running) stopStream() else ensurePermsAndStart()
        }
        menuBtn.setOnClickListener { showAppMenu(it) }

        syncRunningStateFromService()
        renderIdleState()

        val shouldAutoStart = prefs.getBoolean(KEY_AUTO_START, false) && !running
        val startedFirstRunSetup = showFirstRunPermissionSetupIfNeeded(shouldAutoStart)
        if (shouldAutoStart && !startedFirstRunSetup) {
            ensurePermsAndStart()
        }
    }

    private fun showFirstRunPermissionSetupIfNeeded(startAfterSetup: Boolean): Boolean {
        if (prefs.getBoolean(KEY_FIRST_RUN_PERMISSION_SETUP_SHOWN, false)) return false

        prefs.edit().putBoolean(KEY_FIRST_RUN_PERMISSION_SETUP_SHOWN, true).apply()
        AlertDialog.Builder(this)
            .setTitle("Permission setup")
            .setMessage(
                "CellularDatasource will ask for permissions one at a time and explain each one.\n\n" +
                    "Location: gets GPS and lets Android provide cell tower details.\n" +
                    "Phone: reads cell tower IDs and signal values.\n" +
                    "Background location: keeps GPS tags working while streaming in the background.\n" +
                    "Notifications: shows that streaming is running.\n" +
                    "Battery: helps keep the stream alive when the screen is off.\n\n" +
                    "Android does not show prompts for install-time permissions like local sockets or start-on-boot. " +
                    "Start-on-boot only runs if you enable it in Settings."
            )
            .setCancelable(false)
            .setPositiveButton("Start setup") { _, _ ->
                startPermissionFlow(startAfterSetup)
            }
            .show()
        return true
    }

    private fun renderIdleState() {
        attachedStatusTxt.text = "Attached stream waiting"
        cellInfoTxt.text = "No cell data yet"
        gpsInfoTxt.text = "No GPS fix yet"
        updateStreamIndicators(false, false)
    }

    private fun ensurePermsAndStart() {
        if (hasRequiredRuntimePermissions()) {
            startStream()
        } else {
            startPermissionFlow(startAfterSetup = true)
        }
    }

    private fun startPermissionFlow(startAfterSetup: Boolean) {
        startAfterPermissionFlow = startAfterSetup
        pendingPermissionSteps.clear()
        pendingPermissionSteps.addAll(buildPermissionSteps())
        continuePermissionFlow()
    }

    private fun buildPermissionSteps(): List<PermissionStep> {
        val steps = mutableListOf<PermissionStep>()

        steps += PermissionStep(
            title = "Location permission",
            message = "Needed to get GPS coordinates and attach latitude/longitude to the cell data. " +
                "Android also requires location permission before apps can read nearby cell tower details.",
            permissions = listOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ),
            shouldRun = { !hasLocationPermission() }
        )

        steps += PermissionStep(
            title = "Phone permission",
            message = "Needed to read cellular tower and signal fields like MCC, MNC, LAC/TAC, Cell ID, " +
                "PCI/PSC, ARFCN, RSSI, RSRP, RSRQ, RSSNR, and TA. It is not used to place calls or read messages.",
            permissions = listOf(Manifest.permission.READ_PHONE_STATE),
            shouldRun = { !hasPhonePermission() }
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            steps += PermissionStep(
                title = "Notification permission",
                message = "Needed to show an ongoing status notification while the app streams in the background.",
                permissions = listOf(Manifest.permission.POST_NOTIFICATIONS),
                shouldRun = { !hasNotificationPermission() }
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            steps += PermissionStep(
                title = "Background location permission",
                message = "Needed when you leave the app or use auto-start, so GPS tagging can continue while the stream runs.",
                permissions = listOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                shouldRun = { hasLocationPermission() && !hasBackgroundLocationPermission() }
            )
        }

        steps += PermissionStep(
            title = "Battery permission",
            message = "Needed to reduce the chance Android stops the stream when the screen is off or the phone is idle.",
            intent = batteryOptimizationIntent(),
            shouldRun = { batteryOptimizationIntent() != null }
        )

        return steps
    }

    private fun continuePermissionFlow() {
        while (pendingPermissionSteps.isNotEmpty()) {
            val step = pendingPermissionSteps.removeFirst()
            if (!step.shouldRun()) continue
            showPermissionRationale(step)
            return
        }

        val shouldStart = startAfterPermissionFlow
        startAfterPermissionFlow = false
        if (shouldStart) {
            if (hasRequiredRuntimePermissions()) {
                startStream()
            } else {
                showRequiredPermissionsMissing()
            }
        }
    }

    private fun showPermissionRationale(step: PermissionStep) {
        AlertDialog.Builder(this)
            .setTitle(step.title)
            .setMessage(step.message)
            .setCancelable(false)
            .setPositiveButton("Continue") { _, _ ->
                when {
                    step.permissions.isNotEmpty() -> reqPerms.launch(step.permissions.toTypedArray())
                    step.intent != null -> launchSettingsStep(step.intent)
                    else -> continuePermissionFlow()
                }
            }
            .show()
    }

    private fun launchSettingsStep(intent: Intent) {
        try {
            reqSettingsActivity.launch(intent)
        } catch (exc: Exception) {
            Log.w(TAG, "failed to launch settings step", exc)
            continuePermissionFlow()
        }
    }

    private fun showRequiredPermissionsMissing() {
        AlertDialog.Builder(this)
            .setTitle("Permissions still needed")
            .setMessage(
                "CellularDatasource needs Location and Phone permissions before it can stream cell and GPS data."
            )
            .setPositiveButton("Try again") { _, _ -> startPermissionFlow(startAfterSetup = true) }
            .setNegativeButton("Not now", null)
            .show()
    }

    private fun hasRequiredRuntimePermissions(): Boolean {
        return hasLocationPermission() && hasPhonePermission()
    }

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasPhonePermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_PHONE_STATE
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasBackgroundLocationPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun batteryOptimizationIntent(): Intent? {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val pkg = packageName
        if (pm.isIgnoringBatteryOptimizations(pkg)) return null
        return Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$pkg")
        }
    }

    private fun showSettingsDialog() {
        val view = LayoutInflater.from(this).inflate(R.layout.dialog_settings, null)
        val swCell = view.findViewById<SwitchCompat>(R.id.switchStreamCell)
        val swGps = view.findViewById<SwitchCompat>(R.id.switchStreamGps)
        val swAuto = view.findViewById<SwitchCompat>(R.id.switchAutoStart)
        val swBoot = view.findViewById<SwitchCompat>(R.id.switchStartOnBoot)
        val swLaunchUiBoot = view.findViewById<SwitchCompat>(R.id.switchLaunchUiOnBoot)

        swCell.isChecked = prefs.getBoolean(KEY_STREAM_CELL, true)
        swGps.isChecked = prefs.getBoolean(KEY_STREAM_GPS, true)
        swAuto.isChecked = prefs.getBoolean(KEY_AUTO_START, false)
        swBoot.isChecked = prefs.getBoolean(KEY_START_ON_BOOT, false)
        swLaunchUiBoot.isChecked = prefs.getBoolean(KEY_LAUNCH_UI_ON_BOOT, false)

        AlertDialog.Builder(this)
            .setTitle("Settings")
            .setView(view)
            .setPositiveButton("Save") { _, _ ->
                prefs.edit()
                    .putBoolean(KEY_STREAM_CELL, swCell.isChecked)
                    .putBoolean(KEY_STREAM_GPS, swGps.isChecked)
                    .putBoolean(KEY_AUTO_START, swAuto.isChecked)
                    .apply()
                setStartOnBootPreference(swBoot.isChecked)
                setLaunchUiOnBootPreference(swLaunchUiBoot.isChecked)
                if (running) {
                    startStream()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun renderPayload(payload: String) {
        try {
            val root = JSONObject(payload)
            statusTxt.text = if (running) {
                if (root.has("status")) {
                    "Stream running (${root.optString("status", "idle")})"
                } else {
                    "Stream running"
                }
            } else {
                "Stream stopped"
            }

            val cells = root.optJSONArray("cells") ?: JSONArray()
            cellInfoTxt.text = formatCurrentCell(root, cells)
            gpsInfoTxt.text = formatGps(root)

            val cellConnected = prefs.getBoolean(KEY_STREAM_CELL, true) && cells.length() > 0
            val gpsConnected = prefs.getBoolean(KEY_STREAM_GPS, true) &&
                root.has("lat") && root.has("lon")
            updateStreamIndicators(cellConnected, gpsConnected)

            val clients = root.optInt("total_clients", 0)
            attachedStatusTxt.text = if (clients > 0 || root.optBoolean("pi_service_running", false)) {
                "Attached stream connected"
            } else {
                "Attached stream waiting"
            }
        } catch (exc: Exception) {
            Log.w(TAG, "cell update parse failed", exc)
            statusTxt.text = if (running) "Stream running" else "Stream stopped"
            renderIdleState()
        }
    }

    private fun formatCurrentCell(root: JSONObject, items: JSONArray): String {
        val current = currentCell(items) ?: return "No cell data yet"
        val name = valueOrFallback(
            firstPresent(current, "name", "network_name", "operator_name", "carrier_name"),
            firstPresent(root, "network_name", "operator_name", "carrier_name")
        )
        val type = valueOrFallback(
            firstPresent(current, "type", "rat"),
            firstPresent(root, "network_type")
        )
        return buildString {
            appendLine("Name: $name")
            appendLine("MCC: ${jsonValue(current, "mcc")}")
            appendLine("MNC: ${jsonValue(current, "mnc")}")
            appendLine("LAC: ${firstPresent(current, "lac", "tac")}")
            appendLine("CELLID: ${firstPresent(current, "cid", "nci", "full_cell_id")}")
            appendLine("PCI/PSC: ${firstPresent(current, "pci", "psc")}")
            appendLine("Type: $type")
            appendLine("RSRP: ${jsonValue(current, "rsrp")}")
            appendLine("RSRQ: ${jsonValue(current, "rsrq")}")
            appendLine("RSSI: ${jsonValue(current, "rssi")}")
            appendLine("RSSNR: ${firstPresent(current, "rssnr", "sinr", "ss_sinr")}")
            appendLine("ARFCN: ${firstPresent(current, "arfcn", "earfcn", "uarfcn", "nrarfcn")}")
            append("TA: ${firstPresent(current, "ta", "timing_advance", "timingAdvance")}")
        }
    }

    private fun currentCell(items: JSONArray): JSONObject? {
        var first: JSONObject? = null
        for (i in 0 until items.length()) {
            val obj = items.optJSONObject(i) ?: continue
            if (first == null) first = obj
            if (obj.optBoolean("registered", false)) {
                return obj
            }
        }
        return first
    }

    private fun formatGps(root: JSONObject): String {
        if (!root.has("lat") || !root.has("lon")) return "No GPS fix yet"
        return buildString {
            appendLine("Lat/Lon: ${root.optDouble("lat")}, ${root.optDouble("lon")}")
            appendLine("Provider: ${root.optString("provider", "unknown")}")
            appendLine("Accuracy: ${root.optString("accuracy_m", "N/A")} m")
            appendLine("Altitude: ${root.optString("alt_m", "N/A")} m")
            appendLine("Speed: ${root.optString("speed_mps", "N/A")} m/s")
            append("Satellites: ${root.optString("satellites", "N/A")}")
        }
    }

    private fun firstPresent(obj: JSONObject, vararg keys: String): String {
        for (key in keys) {
            val value = jsonValue(obj, key)
            if (value != "N/A") return value
        }
        return "N/A"
    }

    private fun valueOrFallback(primary: String, fallback: String): String {
        return if (primary != "N/A") primary else fallback
    }

    private fun jsonValue(obj: JSONObject, key: String): String {
        if (!obj.has(key) || obj.isNull(key)) return "N/A"
        return obj.opt(key)?.toString()?.takeIf {
            it.isNotBlank() &&
                it != "null" &&
                it != "2147483647" &&
                it != "-2147483648" &&
                it != "9223372036854775807"
        } ?: "N/A"
    }

    private fun updateStreamIndicators(cellConnected: Boolean, gpsConnected: Boolean) {
        setStatusIndicator(cellStatusLight, cellStatusTxt, cellConnected)
        setStatusIndicator(gpsStatusLight, gpsStatusTxt, gpsConnected)
    }

    private fun showAppMenu(anchor: View) {
        val popup = PopupMenu(this, anchor)
        popup.menuInflater.inflate(R.menu.main_app_menu, popup.menu)
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.menu_settings -> {
                    showSettingsDialog()
                    true
                }
                R.id.menu_quit -> {
                    quitApp()
                    true
                }
                else -> false
            }
        }
        popup.show()
    }

    private fun quitApp() {
        stopService(Intent(this, CellStreamService::class.java))
        running = false
        finishAffinity()
    }

    private fun setStatusIndicator(indicator: View, label: TextView, connected: Boolean) {
        val colorId = if (connected) R.color.status_green else R.color.status_red
        val color = ContextCompat.getColor(this, colorId)
        indicator.backgroundTintList = ColorStateList.valueOf(color)
        label.text = if (connected) "Active" else "Idle"
        label.setTextColor(color)
    }

    private fun setStartOnBootPreference(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_START_ON_BOOT, enabled).apply()
        devicePrefs.edit().putBoolean(KEY_START_ON_BOOT, enabled).apply()
    }

    private fun setLaunchUiOnBootPreference(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_LAUNCH_UI_ON_BOOT, enabled).apply()
        devicePrefs.edit().putBoolean(KEY_LAUNCH_UI_ON_BOOT, enabled).apply()
    }

    private fun syncStartOnBootPreference() {
        val ceValue = prefs.getBoolean(KEY_START_ON_BOOT, false)
        val deValue = devicePrefs.getBoolean(KEY_START_ON_BOOT, false)
        if (ceValue != deValue) {
            devicePrefs.edit().putBoolean(KEY_START_ON_BOOT, ceValue).apply()
        }
        val ceLaunchUi = prefs.getBoolean(KEY_LAUNCH_UI_ON_BOOT, false)
        val deLaunchUi = devicePrefs.getBoolean(KEY_LAUNCH_UI_ON_BOOT, false)
        if (ceLaunchUi != deLaunchUi) {
            devicePrefs.edit().putBoolean(KEY_LAUNCH_UI_ON_BOOT, ceLaunchUi).apply()
        }
    }

    private fun startStream() {
        ContextCompat.startForegroundService(
            this,
            Intent(this, CellStreamService::class.java)
        )
        prefs.edit().putBoolean(KEY_SERVICE_RUNNING, true).apply()
        updateRunningStateUi(true)
    }

    private fun stopStream() {
        stopService(Intent(this, CellStreamService::class.java))
        prefs.edit().putBoolean(KEY_SERVICE_RUNNING, false).apply()
        updateRunningStateUi(false)
        renderIdleState()
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
        // getRunningServices() is deprecated since API 26 and returns an empty list for
        // third-party apps on modern Android. Read the flag written by the service itself.
        val serviceRunning = prefs.getBoolean(KEY_SERVICE_RUNNING, false)
        if (!serviceRunning) {
            devicePrefs.edit().putBoolean(KEY_SERVICE_RUNNING, false).apply()
        }
        updateRunningStateUi(serviceRunning)
    }

    private fun updateRunningStateUi(isRunning: Boolean) {
        running = isRunning
        if (isRunning) {
            applyRunningStyle()
            statusTxt.text = "Stream running"
        } else {
            statusTxt.text = "Stream stopped"
            toggleBtn.text = "Start Stream"
            applyStartStyle()
        }
    }

    override fun onStart() {
        super.onStart()
        ContextCompat.registerReceiver(
            this,
            payloadReceiver,
            IntentFilter().apply {
                addAction(CellStreamService.ACTION_CELL_UPDATE)
                addAction(CellStreamService.ACTION_SERVICE_STATE)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        syncRunningStateFromService()
    }

    override fun onStop() {
        unregisterReceiver(payloadReceiver)
        super.onStop()
    }
}
