package com.example.ai_cast_hub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * MediaProjection 前台服务
 *
 * Android 14+ (API 34+) 要求：调用 MediaProjection.createVirtualDisplay() 时，
 * 必须有一个 foregroundServiceType="mediaProjection" 的前台服务正在运行，
 * 否则系统会抛出 SecurityException 导致应用崩溃。
 *
 * flutter_webrtc 的 OrientationAwareScreenCapturer 内部直接调用 createVirtualDisplay()，
 * 但不会启动任何前台服务，因此需要由宿主 App 在调用 getDisplayMedia() 之前启动本服务。
 *
 * 启动时机：用户点击"开始投屏"时（App 处于前台），先启动本服务，再调用 getDisplayMedia()。
 * 停止时机：屏幕捕获停止或投屏结束时。
 */
class MediaProjectionService : Service() {
    private val CHANNEL_ID = "ai_cast_hub_media_projection"
    private val NOTIFICATION_ID = 1002

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        // Android 14+ (API 34+) 必须使用 mediaProjection 类型启动前台服务
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "屏幕录制",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "屏幕投射前台服务"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AI Cast Hub")
            .setContentText("正在投射屏幕...")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
