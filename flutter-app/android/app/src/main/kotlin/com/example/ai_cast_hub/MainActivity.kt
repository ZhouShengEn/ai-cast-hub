package com.example.ai_cast_hub

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLConnection
import java.util.Locale

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
    private val FILE_CHANNEL = "ai_cast_hub/file"
    private val AUDIO_CHANNEL = "ai_cast_hub/system_audio"
    private val AUDIO_PCM_EVENT = "ai_cast_hub/system_audio/pcm"
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 独立申请屏幕采集授权的请求码（取 MediaProjection 令牌用于系统内录） */
    private val REQUEST_MEDIA_PROJECTION = 9001

    private val systemAudioCapture = SystemAudioCaptureManager()
    private var audioEventSink: EventChannel.EventSink? = null
    private var pendingProjectionResult: MethodChannel.Result? = null

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
                    startMediaProjectionService(result)
                }
                "stopMediaProjectionService" -> {
                    val stopped = stopMediaProjectionService()
                    result.success(stopped)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openFile" -> openFile(
                    call.argument<String>("path"),
                    call.argument<String>("mimeType"),
                    result
                )
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
                    dispatchGestureSafe("dispatchTap", result) { it.dispatchTap(x, y) }
                }
                "dispatchLongPress" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val duration = call.argument<Int>("duration") ?: 600
                    dispatchGestureSafe("dispatchLongPress", result) {
                        it.dispatchLongPress(x, y, duration.toLong())
                    }
                }
                "dispatchSwipe" -> {
                    val startX = call.argument<Double>("startX") ?: 0.0
                    val startY = call.argument<Double>("startY") ?: 0.0
                    val endX = call.argument<Double>("endX") ?: 0.0
                    val endY = call.argument<Double>("endY") ?: 0.0
                    val duration = call.argument<Int>("duration") ?: 300
                    dispatchGestureSafe("dispatchSwipe", result) {
                        it.dispatchSwipe(startX, startY, endX, endY, duration)
                    }
                }
                "dispatchTouchStart" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    dispatchGestureSafe("dispatchTouchStart", result) { it.dispatchTouchStart(x, y) }
                }
                "dispatchTouchMove" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    dispatchGestureSafe("dispatchTouchMove", result) { it.dispatchTouchMove(x, y) }
                }
                "dispatchTouchEnd" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    dispatchGestureSafe("dispatchTouchEnd", result) { it.dispatchTouchEnd(x, y) }
                }
                "dispatchScroll" -> {
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    val deltaX = call.argument<Double>("deltaX") ?: 0.0
                    val deltaY = call.argument<Double>("deltaY") ?: 0.0
                    dispatchGestureSafe("dispatchScroll", result) {
                        it.dispatchScroll(x, y, deltaX, deltaY)
                    }
                }
                "performGlobalAction" -> {
                    val action = call.argument<String>("action") ?: ""
                    dispatchGestureSafe("performGlobalAction", result) {
                        it.performGlobalAction(action)
                    }
                }
                "dispatchVolumeAdjust" -> {
                    val direction = call.argument<Int>("direction") ?: 0
                    dispatchGestureSafe("dispatchVolumeAdjust", result) {
                        it.dispatchVolumeAdjust(direction)
                    }
                }
                "clearGestureState" -> {
                    // 投屏结束时释放手势运行态，服务未连接也视为清理成功
                    RemoteControlService.instance?.clearGestureState()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 系统内录（AudioPlaybackCapture）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(SystemAudioCaptureManager.isSupported())
                "requestProjection" -> requestMediaProjection(result)
                "startCapture" -> startSystemAudioCapture(result)
                "stopCapture" -> {
                    stopSystemAudioCapture()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_PCM_EVENT).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    audioEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    audioEventSink = null
                }
            }
        )
    }

    companion object {
        private const val TAG = "MainActivity"
    }

    /**
     * 统一下发无障碍手势，并在服务实例缺失时输出可定位的日志。
     *
     * 此前每个分支直接写 `RemoteControlService.instance?.xxx() ?: false`，
     * 实例为 null 时静默返回 false、不留任何痕迹，导致「指令收得到但手机没反应」
     * 这类问题完全无法定位。这里把两种情况区分开：
     *   - instance == null → 无障碍服务未连接（配置未生效 / 服务被解绑）
     *   - 返回 false       → 已下发但被系统拒绝
     */
    private fun dispatchGestureSafe(
        name: String,
        result: MethodChannel.Result,
        block: (RemoteControlService) -> Boolean,
    ) {
        val service = RemoteControlService.instance
        if (service == null) {
            Log.w(
                TAG,
                "$name 未执行: RemoteControlService.instance == null。" +
                    "请确认系统「无障碍」中已开启本服务；若刚修改过 " +
                    "accessibility_service_config.xml，必须关闭再重新开启一次才会生效。"
            )
            result.success(false)
            return
        }
        val ok = block(service)
        if (!ok) {
            Log.w(TAG, "$name 已下发但被系统拒绝(返回 false)")
        }
        result.success(ok)
    }

    // ---- 系统内录（AudioPlaybackCapture）----

    /**
     * 申请一次独立的屏幕采集授权。
     *
     * flutter_webrtc 内部的 MediaProjection 令牌拿不到（私有字段无 getter），
     * 所以系统内录必须自己再申请一次。代价是用户会看到两次录屏授权弹窗。
     */
    private fun requestMediaProjection(result: MethodChannel.Result) {
        if (!SystemAudioCaptureManager.isSupported()) {
            Log.w(TAG, "系统版本低于 Android 10(API 29)，不支持系统内录")
            result.success(false)
            return
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingProjectionResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_MEDIA_PROJECTION) return

        val pending = pendingProjectionResult
        pendingProjectionResult = null
        if (resultCode != android.app.Activity.RESULT_OK || data == null) {
            Log.w(TAG, "用户取消了屏幕采集授权，无法进行系统内录")
            pending?.success(false)
            return
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        SystemAudioProjectionHolder.mediaProjection = mpm.getMediaProjection(resultCode, data)
        Log.i(TAG, "已获取独立 MediaProjection 令牌，系统内录可用")
        pending?.success(true)
    }

    private fun startSystemAudioCapture(result: MethodChannel.Result) {
        if (!SystemAudioCaptureManager.isSupported()) {
            result.success(false)
            return
        }
        val projection = SystemAudioProjectionHolder.mediaProjection
        if (projection == null) {
            Log.w(TAG, "尚未取得 MediaProjection 令牌，请先调用 requestProjection")
            result.success(false)
            return
        }
        val started = systemAudioCapture.start(projection) { pcm ->
            // EventChannel 必须在主线程回调
            mainHandler.post { audioEventSink?.success(pcm) }
        }
        Log.i(TAG, "startSystemAudioCapture -> $started")
        result.success(started)
    }

    private fun stopSystemAudioCapture() {
        systemAudioCapture.stop()
        audioEventSink = null
    }

    override fun onDestroy() {
        // 兜底释放：避免 Activity 销毁后仍在后台采集音频
        stopSystemAudioCapture()
        SystemAudioProjectionHolder.mediaProjection = null
        super.onDestroy()
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
     * 必须在 App 处于前台且用户完成录屏授权后调用，并在调用
     * getDisplayMedia() 前确认服务已进入前台。
     */
    private fun startMediaProjectionService(result: MethodChannel.Result) {
        try {
            val requestId = SystemClock.elapsedRealtimeNanos()
            val serviceIntent = Intent(this, MediaProjectionService::class.java).apply {
                putExtra(MediaProjectionService.EXTRA_START_REQUEST_ID, requestId)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }

            // startForegroundService() 是异步的：它只是把启动请求交给系统，
            // 服务回调也运行在主线程，不能在这里 Thread.sleep/while 阻塞。
            // 用本次请求 ID 非阻塞等待 onStartCommand/startForeground 完成，
            // 避免快速停止后重启时误读上一次遗留的 isRunning=true。
            waitForMediaProjectionService(
                result,
                requestId,
                SystemClock.elapsedRealtime() + 3000
            )
        } catch (e: Exception) {
            Log.e("MainActivity", "启动 MediaProjection 前台服务失败", e)
            result.success(false)
        }
    }

    private fun waitForMediaProjectionService(
        result: MethodChannel.Result,
        requestId: Long,
        deadlineMillis: Long
    ) {
        when {
            MediaProjectionService.lastHandledRequestId == requestId -> {
                val started = MediaProjectionService.lastStartSucceeded &&
                        MediaProjectionService.isRunning
                Log.d("MainActivity", "MediaProjection 前台服务启动结果: $started")
                result.success(started)
            }
            SystemClock.elapsedRealtime() >= deadlineMillis -> {
                Log.e("MainActivity", "等待 MediaProjection 前台服务就绪超时")
                stopService(Intent(this, MediaProjectionService::class.java))
                result.success(false)
            }
            else -> mainHandler.postDelayed(
                {
                    waitForMediaProjectionService(
                        result,
                        requestId,
                        deadlineMillis
                    )
                },
                25
            )
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

    private fun openFile(
        filePath: String?,
        declaredMimeType: String?,
        result: MethodChannel.Result
    ) {
        if (filePath.isNullOrBlank()) {
            showFileToast("文件路径无效")
            result.success(false)
            return
        }

        try {
            val file = File(filePath).canonicalFile
            if (!file.exists() || !file.isFile) {
                showFileToast("文件不存在或已被删除")
                result.success(false)
                return
            }

            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val mimeType = resolveMimeType(file, declaredMimeType)
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                clipData = ClipData.newRawUri(file.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            @Suppress("DEPRECATION")
            val handlers = packageManager.queryIntentActivities(
                viewIntent,
                PackageManager.MATCH_DEFAULT_ONLY
            )
            if (handlers.isEmpty()) {
                showFileToast("没有可打开此文件的应用")
                result.success(false)
                return
            }

            val chooser = Intent.createChooser(viewIntent, "选择打开方式").apply {
                clipData = ClipData.newRawUri(file.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(chooser)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            Log.w("MainActivity", "没有应用可打开文件: $filePath", e)
            showFileToast("没有可打开此文件的应用")
            result.success(false)
        } catch (e: IllegalArgumentException) {
            Log.e("MainActivity", "文件不在 FileProvider 允许的目录中: $filePath", e)
            showFileToast("无法安全共享此文件")
            result.error("FILE_NOT_SHAREABLE", e.message, null)
        } catch (e: SecurityException) {
            Log.e("MainActivity", "打开文件权限不足: $filePath", e)
            showFileToast("没有权限打开此文件")
            result.error("FILE_PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            Log.e("MainActivity", "打开文件失败: $filePath", e)
            showFileToast("打开文件失败")
            result.error("OPEN_FILE_FAILED", e.message, null)
        }
    }

    private fun resolveMimeType(file: File, declaredMimeType: String?): String {
        val extension = file.extension.lowercase(Locale.ROOT)
        if (extension.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?.let { return it }
            URLConnection.guessContentTypeFromName(file.name)?.let { return it }
        }

        val normalizedDeclaredType = declaredMimeType
            ?.substringBefore(';')
            ?.trim()
            ?.lowercase(Locale.ROOT)
        if (!normalizedDeclaredType.isNullOrEmpty() &&
            Regex("^[a-z0-9][a-z0-9.+-]*/[a-z0-9*][a-z0-9.+*-]*$")
                .matches(normalizedDeclaredType)
        ) {
            return normalizedDeclaredType
        }

        return "application/octet-stream"
    }

    private fun showFileToast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }
}
