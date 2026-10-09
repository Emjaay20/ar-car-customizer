package com.example.client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ar_car/apk")
            .setMethodCallHandler { call, result ->
                if (call.method == "sourceDir") {
                    result.success(applicationInfo.sourceDir)
                } else {
                    result.notImplemented()
                }
            }
    }
}
