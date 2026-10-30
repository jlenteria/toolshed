package com.bling.toolshed

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Android half of `com.bling.toolshed/memreaper`.
 *
 * Every method here is read-only except the two that hand the user to a system
 * settings page. There is no kill, no freeze and no background service, because
 * the platform does not permit any of that from an ordinary app — see
 * [AppRanking] for what is actually available.
 *
 * Usage-stats queries and icon decoding are not instantaneous, so they run on a
 * worker and the reply is posted back to the platform thread, which is the only
 * thread a [MethodChannel.Result] may be called from.
 */
class MemReaperChannel(
    context: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private val ranking = AppRanking(context)
    private val statusProvider = UsageAccess(context)
    private val icons = AppIcons(context)
    private val links = DeepLinks(context)

    private val worker = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> offload(result) { statusProvider.status() }

            "rankedApps" -> {
                val windowDays = call.argument<Int>("windowDays") ?: DEFAULT_WINDOW_DAYS
                val limit = call.argument<Int>("limit") ?: DEFAULT_LIMIT
                offload(result) {
                    ranking.ranked(
                        windowDays.coerceIn(1, MAX_WINDOW_DAYS),
                        limit.coerceIn(1, MAX_LIMIT),
                    )
                }
            }

            "appIcon" -> {
                val packageName = call.argument<String>("packageName")
                val sizePx = call.argument<Int>("sizePx") ?: DEFAULT_ICON_PX
                if (packageName.isNullOrEmpty()) {
                    result.error("BAD_ARGUMENT", "packageName is required", null)
                } else {
                    offload(result) { icons.png(packageName, sizePx) }
                }
            }

            // startActivity is not thread-affine, but a misbehaving OEM
            // ActivityManager is easier to read about from the main thread.
            "openAppDetails" -> {
                val packageName = call.argument<String>("packageName")
                if (packageName.isNullOrEmpty()) {
                    result.error("BAD_ARGUMENT", "packageName is required", null)
                } else {
                    main.post { result.success(links.openAppDetails(packageName)) }
                }
            }

            "openUsageAccess" ->
                main.post { result.success(links.openUsageAccess()) }

            else -> result.notImplemented()
        }
    }

    private fun offload(result: MethodChannel.Result, body: () -> Any?) {
        worker.execute {
            val value = try {
                body()
            } catch (error: Exception) {
                main.post {
                    result.error("NATIVE_FAILURE", error.message ?: error.toString(), null)
                }
                return@execute
            }
            main.post { result.success(value) }
        }
    }

    companion object {
        const val NAME = "com.bling.toolshed/memreaper"
        const val DEFAULT_WINDOW_DAYS = 7
        const val DEFAULT_LIMIT = 100
        const val DEFAULT_ICON_PX = 96

        /** Beyond a month the answer is "the device does not keep that much
         *  history", so a larger window would only mislead. */
        const val MAX_WINDOW_DAYS = 30
        const val MAX_LIMIT = 300
    }
}
