package com.example.ai_cast_hub

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity — 使用 flutter_webrtc 内置的屏幕捕获能力。
 *
 * flutter_webrtc 插件通过其自身的 FlutterWebRTCPlugin 注册 MethodChannel，
 * 并在内部处理 MediaProjection 权限请求和 ForegroundService 生命周期。
 *
 * 新增：后台连接保持服务的 MethodChannel 支持
 */
class MainActivity : FlutterActivity() {
    private val CHANNEL = "ai_cast_hub/background"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val started = startBackgroundService()
                    result.success(started)
                }
                "stopService" -> {
                    val stopped = stopBackgroundService()
                    result.success(stopped)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "AI Cast Hub"
                    val content = call.argument<String>("content") ?: "保持连接中..."
                    updateServiceNotification(title, content)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startBackgroundService(): Boolean {
        return try {
            val serviceIntent = Intent(this, BackgroundConnectionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun stopBackgroundService(): Boolean {
        return try {
            val serviceIntent = Intent(this, BackgroundConnectionService::class.java)
            stopService(serviceIntent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun updateServiceNotification(title: String, content: String) {
        // 通过 Intent 发送更新指令（简化实现）
        val serviceIntent = Intent(this, BackgroundConnectionService::class.java).apply {
            action = "UPDATE_NOTIFICATION"
            putExtra("title", title)
            putExtra("content", content)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }
}
