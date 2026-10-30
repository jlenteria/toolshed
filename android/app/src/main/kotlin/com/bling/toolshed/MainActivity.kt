package com.bling.toolshed

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * All app-specific Android work hangs off this engine. The bridge is created
 * here and nowhere else: `toolshed` has no other native surface, and there is
 * deliberately no background service — Android 14 would not let one stop
 * another app's processes anyway.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MemReaperChannel(
            applicationContext,
            io.flutter.plugin.common.MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                MemReaperChannel.NAME,
            ),
        )
    }
}
