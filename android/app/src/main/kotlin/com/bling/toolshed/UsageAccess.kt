package com.bling.toolshed

import android.content.Context

/**
 * The status payload, plus the one number on a phone that genuinely means
 * "right now": the device's own free memory.
 *
 * `ActivityManager.getMemoryInfo` is deprecated at API 34 and only ever
 * described the calling app's heap, so the totals come from /proc/meminfo —
 * live and permission-free. What meminfo cannot give is any per-app figure.
 */
class UsageAccess(context: Context) {

    private val ranking = AppRanking(context)

    fun status(): Map<String, Any?> {
        val meminfo = readMemInfo()
        return mapOf(
            "usageAccessGranted" to ranking.usageAccessGranted(),
            "ramTotalBytes" to (meminfo["MemTotal"] ?: -1L),
            "ramAvailableBytes" to (meminfo["MemAvailable"] ?: -1L),
            "retentionStartMillis" to ranking.retentionStartMillis(),
            "retentionEndMillis" to System.currentTimeMillis(),
        )
    }

    /** `MemTotal` and `MemAvailable` are kB in the kernel's output. */
    private fun readMemInfo(): Map<String, Long> = try {
        java.io.File("/proc/meminfo").useLines { lines ->
            lines.mapNotNull { line ->
                val parts = line.split(":")
                if (parts.size < 2) return@mapNotNull null
                val value = parts[1].trim().toLongOrNull() ?: return@mapNotNull null
                parts[0].trim() to value * 1024L
            }.toMap()
        }
    } catch (_: Exception) {
        // Reading /proc/meminfo is not gated by a permission, so the only
        // realistic failure is a kernel that changed the field names — which is
        // reported as "unknown" rather than guessed at.
        emptyMap()
    }
}
