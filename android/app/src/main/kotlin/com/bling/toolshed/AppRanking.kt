package com.bling.toolshed

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Per-app ranking, as far as a non-rooted app is allowed to see it.
 *
 * Two limits shape everything here, and neither is a choice:
 *  - `getRunningAppProcesses()` has returned only the caller's own processes
 *    since Android 8, and `killBackgroundProcesses()` is limited to the
 *    caller's processes since Android 14. There is no live per-app memory
 *    number and no way to stop something else.
 *  - The only per-app signal left is `UsageStatsManager`, whose
 *    `totalTimeInForeground` is a duration over a window. It is NOT bytes, so
 *    nothing here pretends otherwise: rows carry a share of the period plus
 *    foreground time, and the phone is described by /proc/meminfo totals.
 */
class AppRanking(context: Context) {

    private val appContext = context.applicationContext
    private val packages: PackageManager = appContext.packageManager

    private val usage: UsageStatsManager? =
        appContext.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager

    /** Launchable apps only. No QUERY_ALL_PACKAGES — the manifest's `<queries>`
     *  block declares exactly this much visibility and nothing more. */
    private fun launchable(): Map<String, String> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packages.queryIntentActivities(intent, 0)
            .asSequence()
            .mapNotNull { it.activityInfo?.packageName }
            .associateWith { pkg ->
                runCatching {
                    packages.getApplicationLabel(
                        packages.getApplicationInfo(pkg, 0)
                    ).toString()
                }.getOrDefault(pkg)
            }
    }

    /**
     * The app-op read is advisory: several OEM ROMs report it denied while
     * usage stats still work, and the reverse happens too. So this is `granted`
     * only when the op says allowed or a query actually returned rows.
     */
    fun usageAccessGranted(): Boolean {
        val manager = appContext.getSystemService(Context.APP_OPS_SERVICE)
            as? AppOpsManager ?: return false
        val op = AppOpsManager.OPSTR_GET_USAGE_STATS
        val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            manager.unsafeCheckOpNoThrow(op, processUid(), appContext.packageName) ==
                AppOpsManager.MODE_ALLOWED
        } else {
            @Suppress("DEPRECATION")
            manager.checkOpNoThrow(op, processUid(), appContext.packageName) ==
                AppOpsManager.MODE_ALLOWED
        }
        return allowed || hasUsageData()
    }

    private fun processUid(): Int = runCatching { appContext.applicationInfo.uid }.getOrDefault(-1)

    private fun query(start: Long, end: Long): List<UsageStats> {
        val manager = usage ?: return emptyList()
        // Some ROMs throw on a window with no data at all rather than returning
        // an empty list, which is not a condition worth crashing the app over.
        return runCatching {
            manager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, start, end)
        }.getOrNull().orEmpty()
    }

    fun hasUsageData(): Boolean {
        val end = System.currentTimeMillis()
        return query(end - DAY_MILLIS, end).any { it.totalTimeInForeground > 0 }
    }

    /**
     * The least recent `lastTimeUsed` in a thirty-day scan, which is the oldest
     * record the device is actually giving up. Reported so a 30-day window on a
     * phone that kept three days of history can say so instead of showing
     * near-zero numbers for everything.
     */
    fun retentionStartMillis(): Long {
        val end = System.currentTimeMillis()
        val seen = query(end - 30L * DAY_MILLIS, end)
            .map { it.lastTimeUsed }
            .filter { it > 0L && it < end }
        return seen.minOrNull() ?: end
    }

    fun ranked(windowDays: Int, limit: Int): List<Map<String, Any?>> {
        val names = launchable()
        if (names.isEmpty()) return emptyList()

        val end = System.currentTimeMillis()
        val start = end - windowDays.toLong() * DAY_MILLIS
        val stats = query(start, end).filter { names.containsKey(it.packageName) }
        if (stats.isEmpty()) return emptyList()

        // Fold the daily buckets each package is returned in.
        val foreground = HashMap<String, Long>()
        val lastUsed = HashMap<String, Long>()
        for (row in stats) {
            val pkg = row.packageName
            foreground[pkg] = (foreground[pkg] ?: 0L) + row.totalTimeInForeground.coerceAtLeast(0L)
            val seen = row.lastTimeUsed
            if (seen > (lastUsed[pkg] ?: -1L)) lastUsed[pkg] = seen
        }

        // The denominator is the whole window's foreground time, so the column
        // means "of everything you used in this period".
        val total = foreground.values.fold(0L) { acc, value -> acc + value }
        val launches = launchCounts(names.keys, start, end)

        return foreground.entries
            .asSequence()
            .filter { it.value > 0 }
            .map { (pkg, millis) ->
                mapOf(
                    "packageName" to pkg,
                    "label" to names[pkg]!!,
                    "foregroundMillis" to millis,
                    "share" to (if (total > 0) millis.toDouble() / total else 0.0),
                    "lastUsedMillis" to (lastUsed[pkg] ?: -1L),
                    // -1 below API 30, where ACTIVITY_RESUMED is not delivered
                    // to normal apps; the Dart side hides the column.
                    "launchCount" to (launches?.get(pkg) ?: -1L),
                )
            }
            .sortedByDescending { it["share"] as Double }
            .take(limit)
            .toList()
    }

    private fun launchCounts(
        pkgs: Set<String>,
        start: Long,
        end: Long,
    ): Map<String, Long>? {
        if (Build.VERSION.SDK_INT < 30) return null
        val manager = usage ?: return null
        val events = runCatching { manager.queryEvents(start, end) }.getOrNull() ?: return null
        val out = HashMap<String, Long>()
        val event = UsageEvents.Event()
        while (runCatching { events.hasNextEvent() }.getOrDefault(false)) {
            if (!runCatching { events.getNextEvent(event) }.isSuccess) break
            val pkg = event.packageName ?: continue
            if (pkgs.contains(pkg) &&
                event.eventType == UsageEvents.Event.ACTIVITY_RESUMED
            ) {
                out[pkg] = (out[pkg] ?: 0L) + 1
            }
        }
        return out
    }

    companion object {
        const val DAY_MILLIS = 24L * 60 * 60 * 1000
    }
}
