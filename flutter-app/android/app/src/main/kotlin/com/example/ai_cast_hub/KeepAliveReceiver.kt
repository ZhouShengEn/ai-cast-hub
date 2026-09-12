package com.example.ai_cast_hub

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

/**
 * 周期唤醒接收器：解决「手机熄屏后 WebSocket 断连、呼叫响铃/定位指令到不了」的问题。
 *
 * 原理：Android Doze 模式会冻结后台进程的网络与定时器，仅靠前台服务 + WakeLock + WifiLock
 * 仍无法让 WebSocket 在熄屏下主动重连（重连定时器被一并冻结）。本接收器由 AlarmManager
 * 以 [INTERVAL_MS] 为周期、用 setExactAndAllowWhileIdle（Doze 下仍精准唤醒）触发：
 *   - 短暂持有 PARTIAL_WAKE_LOCK，把进程从 Doze 挂起中唤醒；
 *   - 唤醒窗口内 Flutter 侧 WebSocketService 的指数退避重连定时器得以执行，恢复连接；
 *   - 服务器补投的离线防盗指令（响铃/定位）随之送达，App 被唤醒响铃。
 * 每次触发后再排定下一次，形成稳定周期（比 setRepeating 更抗 Doze 延迟）。
 */
class KeepAliveReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "com.example.ai_cast_hub.KEEP_ALIVE"
        const val INTERVAL_MS = 15_000L
        private const val REQUEST_CODE = 0x4B41 // "KA"

        /** 排定下一次周期唤醒 */
        fun schedule(context: Context) {
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, KeepAliveReceiver::class.java).apply { action = ACTION }
                val pi = PendingIntent.getBroadcast(
                    context,
                    REQUEST_CODE,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                val triggerAt = System.currentTimeMillis() + INTERVAL_MS
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            } catch (e: Exception) {
                Log.w("KeepAliveReceiver", "排定周期唤醒失败: ${e.message}")
            }
        }

        /** 取消已排定的周期唤醒 */
        fun cancel(context: Context) {
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, KeepAliveReceiver::class.java).apply { action = ACTION }
                val pi = PendingIntent.getBroadcast(
                    context,
                    REQUEST_CODE,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                am.cancel(pi)
            } catch (e: Exception) {
                Log.w("KeepAliveReceiver", "取消周期唤醒失败: ${e.message}")
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION) return
        // 短暂唤醒 CPU（最多 5s），让 Flutter 侧 WebSocket 重连定时器在脱离 Doze 挂起后运行。
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AIContainerHub::KeepAlive")
        try {
            wl.acquire(5000)
        } catch (e: Exception) {
            Log.w("KeepAliveReceiver", "acquire wakeLock 失败: ${e.message}")
        }
        // 5s 超时后系统自动释放 PARTIAL_WAKE_LOCK，无需手动 release（避免跨线程释放竞态）。
        // 排定下一轮周期唤醒
        schedule(context)
    }
}
