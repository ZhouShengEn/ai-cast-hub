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
        var isRunning = false
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "MediaProjectionService onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "MediaProjectionService onStartCommand")

        // 严禁从 onStartCommand 向外抛异常！
        // onStartCommand 运行在主线程，异常会一路抛到 ActivityThread 导致进程直接崩溃，
        // 表现就是用户看到的「一点投屏 App 就闪退」。
        // Android 14+ (targetSdk 34/35) 在未取得 MediaProjection 用户授权前，
        // 启动 FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION 类型的前台服务会抛
        // SecurityException，因此这里做成多级降级，任何一级失败都不能让进程挂掉。
        var started = false

        // 级别1：带 mediaProjection 类型启动（Android 14+ 合规做法）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            started = tryStartForeground(withMediaProjectionType = true)
            if (!started) {
                Log.w(TAG, "mediaProjection 类型前台服务启动失败，尝试降级启动")
            }
        }

        // 级别2：不带类型启动（Android 13 及以下 / 降级兼容）
        if (!started) {
            started = tryStartForeground(withMediaProjectionType = false)
        }

        isRunning = started

        if (!started) {
            // 两级都失败：只记录日志并停止自己，绝不让异常外泄
            Log.e(TAG, "MediaProjectionService 前台服务启动失败（已降级重试），停止服务")
            stopSelf()
            return START_NOT_STICKY
        }

        Log.d(TAG, "MediaProjectionService started successfully")
        return START_NOT_STICKY
    }

    /**
     * 尝试启动前台服务，失败返回 false 而不抛异常
     */
    private fun tryStartForeground(withMediaProjectionType: Boolean): Boolean {
        return try {
            val notification = buildNotification()
            if (withMediaProjectionType && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
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
                "startForeground 失败 (type=$withMediaProjectionType): ${e.javaClass.simpleName}: ${e.message}",
                e
            )
            false
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "MediaProjectionService onDestroy")
        isRunning = false
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
