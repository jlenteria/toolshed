package com.bling.toolshed

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream

/**
 * Launcher icons, fetched one row at a time.
 *
 * Bulk-decoding two hundred icons at app start is megabytes of work for a list
 * the user scrolls past, so the Dart side asks only for the rows it can see.
 */
class AppIcons(context: Context) {

    private val packages = context.applicationContext.packageManager

    fun png(packageName: String, sizePx: Int): ByteArray? {
        val drawable = runCatching { packages.getApplicationIcon(packageName) }
            .getOrNull() ?: return null
        val size = sizePx.coerceIn(16, 512)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        return try {
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            @Suppress("DEPRECATION")
            val written = bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            if (written) out.toByteArray() else null
        } catch (_: Exception) {
            // A broken icon must never take the ranking list down with it.
            null
        } finally {
            bitmap.recycle()
        }
    }
}
