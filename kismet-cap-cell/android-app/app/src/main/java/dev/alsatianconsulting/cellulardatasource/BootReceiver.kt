package dev.alsatianconsulting.cellulardatasource

import android.app.AlarmManager
import android.app.PendingIntent
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
        private const val KEY_LAUNCH_UI_ON_BOOT = "launch_ui_on_boot"
        private val START_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_USER_UNLOCKED,
            Intent.ACTION_USER_PRESENT,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON"
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

        if (shouldLaunchUiOnBoot(context, action)) {
            launchMainActivityBestEffort(context, action)
            // Launcher/home can reclaim focus during boot.
            // Schedule delayed retries to bring app to foreground once boot settles.
            scheduleLaunchRetry(context, action, 15000L)
            scheduleLaunchRetry(context, action, 30000L)
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

    private fun shouldLaunchUiOnBoot(context: Context, action: String): Boolean {
        if (action == Intent.ACTION_LOCKED_BOOT_COMPLETED) return false

        val deviceContext = context.createDeviceProtectedStorageContext()
        val dePrefs = deviceContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val deValue = dePrefs.getBoolean(KEY_LAUNCH_UI_ON_BOOT, false)
        if (deValue) return true

        val unlocked = try {
            val userManager = context.getSystemService(UserManager::class.java)
            userManager?.isUserUnlocked ?: true
        } catch (_: Exception) {
            true
        }
        if (!unlocked) return false

        val cePrefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val ceValue = cePrefs.getBoolean(KEY_LAUNCH_UI_ON_BOOT, false)
        if (ceValue) {
            dePrefs.edit().putBoolean(KEY_LAUNCH_UI_ON_BOOT, true).apply()
        }
        return ceValue
    }

    private fun launchMainActivityBestEffort(context: Context, action: String) {
        val launchIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
            setClass(context, MainActivity::class.java)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("launch_reason", "boot")
            putExtra("launch_action", action)
        }

        try {
            context.startActivity(launchIntent)
            Log.i(TAG, "Launched MainActivity from action=$action")
            return
        } catch (e: Exception) {
            Log.w(TAG, "Direct launch failed from action=$action; scheduling retry", e)
        }

        // Some Android builds block direct startActivity from boot receiver context.
        // Schedule one short retry shortly after unlock/present.
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            val pi = buildLaunchPendingIntent(context, launchIntent, 2001)
            am?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + 3000L, pi)
            Log.i(TAG, "Scheduled MainActivity launch retry from action=$action")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to schedule launch retry from action=$action", e)
        }
    }

    private fun scheduleLaunchRetry(context: Context, action: String, delayMs: Long) {
        try {
            val launchIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
                setClass(context, MainActivity::class.java)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("launch_reason", "boot_retry")
                putExtra("launch_action", action)
            }
            val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            val requestCode = (2000 + (delayMs / 1000L).toInt()).coerceAtLeast(2002)
            val pi = buildLaunchPendingIntent(context, launchIntent, requestCode)
            am?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + delayMs, pi)
            Log.i(TAG, "Scheduled delayed launch retry in ${delayMs}ms from action=$action")
        } catch (e: Exception) {
            Log.w(TAG, "Failed scheduling delayed launch retry from action=$action", e)
        }
    }

    private fun buildLaunchPendingIntent(
        context: Context,
        launchIntent: Intent,
        requestCode: Int
    ): PendingIntent {
        val piFlags = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getActivity(context, requestCode, launchIntent, piFlags)
    }
}
