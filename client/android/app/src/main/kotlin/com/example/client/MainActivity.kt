package com.example.client

import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ar_car/media")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveImageToGallery") {
                    val bytes = call.argument<ByteArray>("bytes")
                    val filename = call.argument<String>("filename") ?: "AutoCraft_${System.currentTimeMillis()}.jpg"
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("INVALID_BYTES", "Image bytes cannot be empty", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val uriString = saveImageToMediaStore(bytes, filename)
                        if (uriString != null) {
                            result.success(uriString)
                        } else {
                            result.error("SAVE_FAILED", "Failed to create MediaStore entry", null)
                        }
                    } catch (e: Exception) {
                        result.error("IO_ERROR", e.localizedMessage, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun saveImageToMediaStore(bytes: ByteArray, filename: String): String? {
        val resolver = contentResolver
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + File.separator + "AutoCraft")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues) ?: return null

        try {
            resolver.openOutputStream(uri)?.use { stream ->
                stream.write(bytes)
                stream.flush()
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentValues.clear()
                contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, contentValues, null, null)
            }

            // Also trigger media scanner
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(uri.toString()),
                arrayOf("image/jpeg"),
                null
            )
            return uri.toString()
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
