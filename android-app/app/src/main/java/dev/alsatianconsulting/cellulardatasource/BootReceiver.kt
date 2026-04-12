package dev.alsatianconsulting.cellulardatasource

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.UserManager
import android.util.Log
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private const val PREFS_NAME = "cellstream_prefs"
        private const val KEY_START_ON_BOOT = "start_on_boot"
        private val START_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_USER_UNLOCKED
        )
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action !in START_ACTIONS) return

        if (!shouldStartOnBoot(context)) {
            Log.i(TAG, "Skipping startup from action=$action (start_on_boot disabled)")
            return
        }

        // Start the foreground service; it will collect and stream.
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, CellStreamService::class.java)
            )
            Log.i(TAG, "Started CellStreamService from action=$action")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start CellStreamService from action=$action", e)
        }
    }

    private fun shouldStartOnBoot(context: Context): Boolean {
        val deviceContext = context.createDeviceProtectedStorageContext()
        val dePrefs = deviceContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val deValue = dePrefs.getBoolean(KEY_START_ON_BOOT, false)
        if (deValue) return true

        val unlocked = try {
            val userManager = context.getSystemService(UserManager::class.java)
            userManager?.isUserUnlocked ?: true
        } catch (_: Exception) {
            true
        }
        if (!unlocked) return false

        val ceValue = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_START_ON_BOOT, false)
        if (ceValue) {
            // Backfill DE preferences so locked-boot path can read this setting next reboot.
            dePrefs.edit().putBoolean(KEY_START_ON_BOOT, true).apply()
        }
        return ceValue
    }
}
