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
import android.util.Log
import androidx.core.app.NotificationCompat

class MediaProjectionService : Service() {
    companion object {
        private const val TAG = "MediaProjectionService"
        private const val CHANNEL_ID = "ai_cast_hub_media_projection"
        private const val NOTIFICATION_ID = 1002
        const val EXTRA_START_REQUEST_ID = "start_request_id"

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var lastHandledRequestId = Long.MIN_VALUE
            private set

        @Volatile
        var lastStartSucceeded = false
            private set
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = false
        Log.d(TAG, "MediaProjectionService onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "MediaProjectionService onStartCommand")
        val requestId = intent?.getLongExtra(
            EXTRA_START_REQUEST_ID,
            startId.toLong()
        ) ?: startId.toLong()

        // Android 14+ 要求用户先完成 MediaProjection 授权，再启动声明为
        // mediaProjection 类型的前台服务。授权时序由 Flutter 层保证。
        val started = tryStartForeground()
        isRunning = started
        lastStartSucceeded = started
        lastHandledRequestId = requestId
        if (!started) {
            Log.e(TAG, "MediaProjectionService 前台服务启动失败，停止服务")
            stopSelf(startId)
            return START_NOT_STICKY
        }

        Log.d(TAG, "MediaProjectionService started successfully")
        return START_NOT_STICKY
    }

    /**
     * 尝试启动前台服务，失败返回 false 而不抛异常
     */
    private fun tryStartForeground(): Boolean {
        return try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            Log.e(
                TAG,
                "startForeground 失败: ${e.javaClass.simpleName}: ${e.message}",
                e
            )
            false
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "MediaProjectionService onDestroy")
        isRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "屏幕录制",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "屏幕投射前台服务"
                    setShowBadge(false)
                    enableVibration(false)
                    enableLights(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AI Cast Hub")
            .setContentText("正在投射屏幕...")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .build()
    }
}
