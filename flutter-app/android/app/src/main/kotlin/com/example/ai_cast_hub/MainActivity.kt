package com.example.ai_cast_hub

import android.content.Intent
import android.os.Build
import android.util.Log
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
    private val RC_CHANNEL = "ai_cast_hub/remote_control"

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
                "startMediaProjectionService" -> {
                    val started = startMediaProjectionService()
                    result.success(started)
                }
                "stopMediaProjectionService" -> {
                    val stopped = stopMediaProjectionService()
                    result.success(stopped)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RC_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAccessibilityEnabled" -> {
                    val enabled = RemoteControlService.isServiceEnabled(this)
                    result.success(enabled)
                }
                "openAccessibilitySettings" -> {
                    RemoteControlService.openAccessibilitySettings(this)
                    result.success(null)
                }
                "dispatchTap" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val success = RemoteControlService.instance?.dispatchTap(x, y) ?: false
                    result.success(success)
                }
                "dispatchTouchStart" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val success = RemoteControlService.instance?.dispatchTouchStart(x, y) ?: false
                    result.success(success)
                }
                "dispatchTouchMove" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val success = RemoteControlService.instance?.dispatchTouchMove(x, y) ?: false
                    result.success(success)
                }
                "dispatchTouchEnd" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val success = RemoteControlService.instance?.dispatchTouchEnd(x, y) ?: false
                    result.success(success)
                }
                "dispatchScroll" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val deltaX = call.argument<Double>("deltaX") ?: 0.0
                    val deltaY = call.argument<Double>("deltaY") ?: 0.0
                    val success = RemoteControlService.instance?.dispatchScroll(x, y, deltaX, deltaY) ?: false
                    result.success(success)
                }
                "performGlobalAction" -> {
                    val action = call.argument<String>("action") ?: ""
                    val success = RemoteControlService.instance?.performGlobalAction(action) ?: false
                    result.success(success)
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

    /**
     * 启动 MediaProjection 前台服务
     *
     * 必须在 App 处于前台时调用（用户点击"开始投屏"时），
     * 且要在调用 getDisplayMedia() 之前启动，以确保 createVirtualDisplay() 时服务已在运行。
     */
    private fun startMediaProjectionService(): Boolean {
        return try {
            val serviceIntent = Intent(this, MediaProjectionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }

            // startForegroundService() 是异步的：它只是把启动请求交给系统，
            // onStartCommand() 尚未执行。若此时立刻调用
            // MediaProjection.createVirtualDisplay()，Android 14+ 会因为
            // mediaProjection 前台服务还没就绪而抛 SecurityException。
            // 这里同步等待服务真正进入前台（通常几十毫秒内完成）。
            val deadline = System.currentTimeMillis() + 1000
            while (!MediaProjectionService.isRunning && System.currentTimeMillis() < deadline) {
                Thread.sleep(25)
            }
            Log.d("MainActivity", "startMediaProjectionService -> isRunning=${MediaProjectionService.isRunning}")
            MediaProjectionService.isRunning
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun stopMediaProjectionService(): Boolean {
        return try {
            val serviceIntent = Intent(this, MediaProjectionService::class.java)
            stopService(serviceIntent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
