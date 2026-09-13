package com.example.ai_cast_hub

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Point
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
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
    private val ANTI_THEFT_CHANNEL = "ai_cast_hub/anti_theft"
    private val APP_CHANNEL = "ai_cast_hub/app"
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 统一申请屏幕采集授权的请求码（供屏幕捕获 + 系统音频内录复用） */
    private val REQUEST_MEDIA_PROJECTION = 9001

    private val systemAudioCapture = SystemAudioCaptureManager()
    private var audioEventSink: EventChannel.EventSink? = null
    private var pendingProjectionResult: MethodChannel.Result? = null
    /** 注册的 MediaProjection 生命周期回调，停止采集时反注册 */
    private var projectionCallback: MediaProjection.Callback? = null

    /** 保留 FlutterEngine 引用，用于把授权 Intent 注入 flutter_webrtc */
    private var flutterEngineRef: FlutterEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 恢复上一次投屏若因进程异常退出而未还原的媒体音量（防手机永久静音）
        SystemAudioCaptureManager.restoreSavedMediaVolume(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngineRef = flutterEngine

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
                "getExternalStorageRoot" -> {
                    // 返回内部存储根目录（如 /storage/emulated/0），用于在「我的手机」中创建可见的 ai-cast-hub 文件夹
                    result.success(android.os.Environment.getExternalStorageDirectory().absolutePath)
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
                // 远程控制诊断：严格区分「设置里已开启」与「服务实例真的已绑定」。
                // 只有 connected=true 时 dispatchGesture 才可能成功；
                // 二者不一致（设置开着但实例为 null）时，Web 端必须提示用户
                // 去系统设置里把本服务「关闭再重新打开」，否则点了永远没反应。
                "getControlDiagnostics" -> {
                    val service = RemoteControlService.instance
                    // 原生侧获取屏幕尺寸可能失败（无障碍 Context 未关联 Display 等），
                    // 绝不能让异常冒泡 —— 否则 Dart 侧只会收到 PlatformException，
                    // 表现为「诊断失败 + screenWidth/Height 恒为 0」。
                    val size = try {
                        service?.screenSizeForDiagnostics()
                    } catch (e: Exception) {
                        RemoteControlService.recordDisplayError(e)
                        Log.w(TAG, "getControlDiagnostics 失败: ${e.message}")
                        null
                    }
                    // 兜底：用 Activity 的真实窗口尺寸（Activity 必然关联 Display），
                    // 保证上报的分辨率永远不为 0，Web 端才能按真实屏幕换算触控坐标。
                    val fallbackSize =
                        if (size == null || size.x <= 0 || size.y <= 0) activityScreenSize() else null
                    val width = size?.x ?: fallbackSize?.x ?: 0
                    val height = size?.y ?: fallbackSize?.y ?: 0
                    result.success(
                        hashMapOf<String, Any?>(
                            "connected" to (service != null),
                            "settingsEnabled" to RemoteControlService.isEnabledInSettings(this),
                            "state" to RemoteControlService.describeDispatchState(this),
                            "screenWidth" to width,
                            "screenHeight" to height,
                            "displayId" to (service?.displayIdForDiagnostics() ?: -1),
                            "lastError" to (RemoteControlService.lastDisplayError ?: ""),
                        )
                    )
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

        // 设备防盗（合规版）：响铃与位置共享均对用户可见且可随时停止。
        // 仅已配对设备经服务端校验后才可下发指令。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ANTI_THEFT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAlarm" -> {
                    AntiTheftService.startAlarm(this)
                    result.success(true)
                }
                "stopAlarm" -> {
                    AntiTheftService.stopAlarm(this)
                    result.success(true)
                }
                "startLocationSharing" -> {
                    AntiTheftService.startLocationSharing(this)
                    result.success(true)
                }
                "stopLocationSharing" -> {
                    AntiTheftService.stopLocationSharing(this)
                    result.success(true)
                }
                "stopAll" -> {
                    AntiTheftService.stopAll(this)
                    result.success(true)
                }
                "isAlarmRunning" -> result.success(AntiTheftService.alarmRunning)
                "isLocationSharing" -> result.success(AntiTheftService.locationSharing)
                else -> result.notImplemented()
            }
        }

        // App 生命周期控制：远程指令到达时把 App 从后台唤醒到前台
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToFront" -> {
                    bringToFront()
                    result.success(null)
                }
                "requestBatteryOptimizationExemption" -> {
                    requestBatteryOptimizationExemption()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把 App 从后台唤醒到前台。
     *
     * 远程响铃/定位时调用：即便 App 在后台，原生前台服务已能响铃/共享位置，
     * 但把 Activity 拉回前台可让用户立即看到界面并手动停止。
     */
    private fun bringToFront() {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            intent?.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            )
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "bringToFront 失败: ${e.message}")
        }
    }

    /**
     * 请求豁免电池优化，保持后台 WebSocket 在熄屏后不被 Doze 断网。
     *
     * 仅引导一次：已加入电池优化白名单则不再弹窗。这是「手机熄屏后 Web 端还能下发
     * 响铃/定位指令」的关键——前台服务 + WakeLock 只能保 CPU，无法绕过 Doze 的网络限制，
     * 必须把 App 加入电池优化白名单，后台网络才能持续。
     */
    private fun requestBatteryOptimizationExemption() {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) return
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "请求电池优化豁免失败: ${e.message}")
        }
    }

    /**
     * 读取 Activity 所在屏幕的真实像素尺寸（兜底用）。
     *
     * Activity 必然关联 Display，因此这个取值不会抛
     * "Tried to obtain display from a Context not associated with one"，
     * 可作为无障碍服务拿不到 Display 时的可靠兜底。
     */
    private fun activityScreenSize(): Point {
        return try {
            val size = Point()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display?.getRealSize(size) ?: windowManager.defaultDisplay.getRealSize(size)
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay.getRealSize(size)
            }
            if (size.x > 0 && size.y > 0) {
                size
            } else {
                val m = resources.displayMetrics
                Point(m.widthPixels, m.heightPixels)
            }
        } catch (e: Exception) {
            Log.w(TAG, "读取 Activity 屏幕尺寸失败: ${e.message}")
            Point(0, 0)
        }
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
     * 申请统一的屏幕采集授权。
     *
     * 该授权 Intent 同时用于：
     *   1. 系统音频内录（AudioPlaybackCapture）
     *   2. flutter_webrtc 屏幕画面捕获
     * 通过反射把 Intent 注入 flutter_webrtc 内部后，getDisplayMedia 不再弹第二次授权，
     * 解决荣耀/华为等 ROM 上双投影冲突、弹两次授权且系统音频无声的问题。
     */
    private fun requestMediaProjection(result: MethodChannel.Result) {
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
            Log.w(TAG, "用户取消了屏幕采集授权")
            pending?.success(false)
            return
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = mpm.getMediaProjection(resultCode, data)
        if (mp == null) {
            Log.e(TAG, "getMediaProjection 返回 null")
            pending?.success(false)
            return
        }
        // 注册生命周期回调：用户从状态栏停止录屏或系统回收投影时，自动停止内录并释放资源
        projectionCallback = object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "系统停止了 MediaProjection（用户停止或系统回收），停止系统内录")
                stopSystemAudioCapture()
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            mp.registerCallback(projectionCallback!!, Handler(Looper.getMainLooper()))
        }
        // 保存统一令牌：屏幕捕获与系统音频内录复用
        SystemAudioProjectionHolder.mediaProjection = mp
        SystemAudioProjectionHolder.mediaProjectionData = data
        SystemAudioProjectionHolder.resultCode = resultCode
        // 把授权 Intent 注入 flutter_webrtc，使其 getDisplayMedia 不再弹第二次授权
        injectMediaProjectionDataIntoFlutterWebRTC(data)
        Log.i(TAG, "已获取统一 MediaProjection 令牌并注入 flutter_webrtc")
        pending?.success(true)
    }

    /**
     * 将授权 Intent 反射注入 flutter_webrtc 的 GetUserMediaImpl.mediaProjectionData。
     *
     * flutter_webrtc 1.5.2 的 getDisplayMedia 在 mediaProjectionData 为 null 时会重新弹授权，
     * 而我们已经通过统一授权拿到了 Intent。注入后，后续 getDisplayMedia 会直接使用该 Intent，
     * 用户只需点一次「开始录制」。
     */
    private fun injectMediaProjectionDataIntoFlutterWebRTC(data: Intent) {
        try {
            val engine = flutterEngineRef ?: return
            val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java)
                ?: throw IllegalStateException("FlutterWebRTCPlugin 未注册")
            val pluginClass = plugin.javaClass

            val methodCallHandlerField = pluginClass.getDeclaredField("methodCallHandler")
            methodCallHandlerField.isAccessible = true
            val methodCallHandler = methodCallHandlerField.get(plugin)
                ?: throw IllegalStateException("methodCallHandler 为空")

            val getUserMediaImplField = methodCallHandler.javaClass.getDeclaredField("getUserMediaImpl")
            getUserMediaImplField.isAccessible = true
            val getUserMediaImpl = getUserMediaImplField.get(methodCallHandler)
                ?: throw IllegalStateException("getUserMediaImpl 为空")

            val mediaProjectionDataField = getUserMediaImpl.javaClass.getDeclaredField("mediaProjectionData")
            mediaProjectionDataField.isAccessible = true
            mediaProjectionDataField.set(getUserMediaImpl, data)

            Log.i(TAG, "已注入 MediaProjection 授权到 flutter_webrtc，后续 getDisplayMedia 不再弹授权")
        } catch (e: Exception) {
            // 注入失败不会阻断功能，只是 getDisplayMedia 会再弹一次授权（回到旧行为）
            Log.w(TAG, "注入 MediaProjection 授权到 flutter_webrtc 失败（将回退到双授权）: ${e.message}")
        }
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
        val started = systemAudioCapture.start(
            this,
            projection,
            { pcm ->
                // EventChannel 必须在主线程回调
                mainHandler.post { audioEventSink?.success(pcm) }
            },
            { err ->
                // 采集致命错误：通知 Dart 层（经调试日志），状态已由 manager 复位
                Log.e(TAG, "系统内录错误回调: $err")
            },
            // 与 flutter_webrtc 屏幕捕获复用同一授权令牌：音频侧为借用方，
            // stop 时只释放 AudioRecord，不 stop 共享投影（否则会掐断屏幕画面）。
            ownsProjection = false
        )
        Log.i(TAG, "startSystemAudioCapture -> $started")
        result.success(started)
    }

    private fun stopSystemAudioCapture() {
        // 反注册投影生命周期回调，避免持有 Activity 引用造成泄漏
        projectionCallback?.let { cb ->
            SystemAudioProjectionHolder.mediaProjection?.unregisterCallback(cb)
            projectionCallback = null
        }
        systemAudioCapture.stop()
        audioEventSink = null
    }

    override fun onDestroy() {
        // 兜底释放：避免 Activity 销毁后仍在后台采集音频 / 残留投影 / 错乱音量
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
