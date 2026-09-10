package com.example.ai_cast_hub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 设备防盗服务（合规版）
 *
 * 设计原则：任何由 Web 端远程触发的行为，都必须对设备持有者**可见、可随时停止**。
 *   - 响铃：常驻通知 + App 内停止界面；用户可随时停止；无人干预时超时自动停止
 *   - 位置共享：仅在「正在共享位置」的前台通知下存活，用户可随时停止
 *
 * 不做熄屏静默定位、不做 WakeLock 强行保活（前台服务自身已保证可见存活）。
 */
class AntiTheftService : Service() {

    companion object {
        private const val TAG = "AntiTheftService"

        const val ACTION_START_ALARM = "com.example.ai_cast_hub.antitheft.START_ALARM"
        const val ACTION_STOP_ALARM = "com.example.ai_cast_hub.antitheft.STOP_ALARM"
        const val ACTION_START_LOCATION = "com.example.ai_cast_hub.antitheft.START_LOCATION"
        const val ACTION_STOP_LOCATION = "com.example.ai_cast_hub.antitheft.STOP_LOCATION"
        const val ACTION_STOP_ALL = "com.example.ai_cast_hub.antitheft.STOP_ALL"

        private const val CHANNEL_ID = "ai_cast_hub_anti_theft"
        private const val NOTIFICATION_ID = 2001

        /** 响铃超时（5 分钟）：无人干预时自动停止，避免长时间外放 */
        private const val ALARM_TIMEOUT_MS = 5 * 60 * 1000L

        private const val REQ_CONTENT = 1
        private const val REQ_STOP_ALARM = 2
        private const val REQ_STOP_LOCATION = 3

        /** 当前状态（进程内有效，供 Flutter 侧查询） */
        @Volatile var alarmRunning = false
            private set

        @Volatile var locationSharing = false
            private set

        fun startAlarm(context: Context) = sendAction(context, ACTION_START_ALARM)

        fun stopAlarm(context: Context) = sendAction(context, ACTION_STOP_ALARM)

        fun startLocationSharing(context: Context) = sendAction(context, ACTION_START_LOCATION)

        fun stopLocationSharing(context: Context) = sendAction(context, ACTION_STOP_LOCATION)

        fun stopAll(context: Context) = sendAction(context, ACTION_STOP_ALL)

        private fun sendAction(context: Context, action: String) {
            val intent = Intent(context, AntiTheftService::class.java).apply {
                this.action = action
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "启动防盗服务失败 action=$action", e)
            }
        }
    }

    private var mediaPlayer: MediaPlayer? = null
    private var originalAlarmVolume = -1
    private val handler = Handler(Looper.getMainLooper())

    private val alarmTimeoutRunnable = Runnable {
        Log.i(TAG, "响铃超时，自动停止")
        stopAlarmInternal()
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_ALARM -> startAlarmInternal()
            ACTION_STOP_ALARM -> stopAlarmInternal()
            ACTION_START_LOCATION -> locationSharing = true
            ACTION_STOP_LOCATION -> locationSharing = false
            ACTION_STOP_ALL -> {
                stopAlarmInternal()
                locationSharing = false
            }
        }

        if (!alarmRunning && !locationSharing) {
            Log.i(TAG, "响铃与位置共享均已停止，退出前台服务")
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundCompat(buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        stopAlarmInternal()
        locationSharing = false
    }

    // ---- 响铃 ----

    private fun startAlarmInternal() {
        if (alarmRunning) return

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        originalAlarmVolume = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
        audioManager.setStreamVolume(AudioManager.STREAM_ALARM, maxVolume, 0)

        val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

        if (alarmUri == null) {
            Log.w(TAG, "无可用铃声音源，仅调整音量")
        } else {
            try {
                mediaPlayer = MediaPlayer().apply {
                    setDataSource(this@AntiTheftService, alarmUri)
                    applyAlarmAudioAttributes(this)
                    isLooping = true
                    setOnPreparedListener { player ->
                        try {
                            player.start()
                        } catch (e: Exception) {
                            Log.e(TAG, "铃声播放失败", e)
                        }
                    }
                    prepareAsync()
                }
            } catch (e: Exception) {
                Log.e(TAG, "MediaPlayer 初始化失败", e)
            }
        }

        alarmRunning = true
        handler.removeCallbacks(alarmTimeoutRunnable)
        handler.postDelayed(alarmTimeoutRunnable, ALARM_TIMEOUT_MS)
        Log.i(TAG, "响铃已启动（用户可随时停止，5 分钟后自动停止）")
    }

    private fun applyAlarmAudioAttributes(player: MediaPlayer) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        } else {
            @Suppress("DEPRECATION")
            player.setAudioStreamType(AudioManager.STREAM_ALARM)
        }
    }

    private fun stopAlarmInternal() {
        handler.removeCallbacks(alarmTimeoutRunnable)

        mediaPlayer?.apply {
            try {
                if (isPlaying) stop()
            } catch (_: Exception) {
            }
            release()
        }
        mediaPlayer = null

        if (originalAlarmVolume >= 0) {
            try {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, originalAlarmVolume, 0)
            } catch (e: Exception) {
                Log.w(TAG, "恢复原始音量失败", e)
            }
            originalAlarmVolume = -1
        }

        if (alarmRunning) {
            alarmRunning = false
            Log.i(TAG, "响铃已停止，音量已恢复")
        }
    }

    // ---- 通知（始终对用户可见，并带有停止入口）----

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "设备防盗",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "响铃与位置共享状态（用户可见，可随时停止）"
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val title = when {
            alarmRunning && locationSharing -> "设备正在响铃并共享位置"
            alarmRunning -> "设备正在响铃"
            else -> "正在共享设备位置"
        }
        val text = when {
            alarmRunning -> "由已配对的 PC 触发，点击可打开 App 停止"
            else -> "由已配对的 PC 触发，可随时停止共享"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(buildContentIntent())
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)

        if (alarmRunning) {
            builder.addAction(
                android.R.drawable.ic_lock_idle_alarm,
                "停止响铃",
                buildActionIntent(ACTION_STOP_ALARM, REQ_STOP_ALARM)
            )
        }
        if (locationSharing) {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "停止共享位置",
                buildActionIntent(ACTION_STOP_LOCATION, REQ_STOP_LOCATION)
            )
        }

        return builder.build()
    }

    private fun buildContentIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        return PendingIntent.getActivity(
            this,
            REQ_CONTENT,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun buildActionIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, AntiTheftService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
