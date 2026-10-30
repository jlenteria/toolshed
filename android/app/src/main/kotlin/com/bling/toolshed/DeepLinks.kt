package com.bling.toolshed

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings

/**
 * The only stop-related thing a normal app may do on a phone: hand the user to
 * the system page that has a working Force Stop button.
 *
 * `killBackgroundProcesses()` is not used anywhere in this project. Since
 * Android 14 it only acts on the caller's own processes, and it never did
 * anything to a game that has a foreground service or a visible window.
 * OEM ROMs are also known to drop the usage-access settings screen, so both
 * jumps return the failure text instead of throwing.
 */
class DeepLinks(context: Context) {

    private val appContext = context.applicationContext

    /** Null on success, otherwise the reason the system page could not open. */
    fun openAppDetails(packageName: String): String? {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            // The package name only ever comes from our own launchable-apps
            // query, never from text typed into the app.
            data = android.net.Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            appContext.startActivity(intent)
            null
        } catch (error: Exception) {
            when (error) {
                is ActivityNotFoundException ->
                    "This device has no app-details screen for $packageName."
                else -> error.message ?: error.toString()
            }
        }
    }

    /**
     * Null when the settings screen opened. There is no public fallback action
     * for "special app access", so a ROM that removed the usage-access screen
     * gets the manual path in the message instead of a second guessed intent.
     */
    fun openUsageAccess(): String? {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        return try {
            appContext.startActivity(intent)
            null
        } catch (error: Exception) {
            "This device has no usage-access screen to open " +
                "(${error.message ?: error.toString()}). Turn the permission on " +
                "under Settings > Apps > Special app access > Usage access."
        }
    }
}
