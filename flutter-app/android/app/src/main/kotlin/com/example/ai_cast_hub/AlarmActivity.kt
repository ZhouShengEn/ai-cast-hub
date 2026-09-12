package com.example.ai_cast_hub

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 响铃锁屏亮屏界面
 *
 * 由 AntiTheftService 在响铃时通过通知的 fullScreenIntent 拉起。
 * 即便手机处于熄屏 / 锁屏状态，也会点亮屏幕并置顶显示，
 * 用户可一键停止响铃。响铃停止后由通知的「停止响铃」动作或本界面按钮关闭。
 */
class AlarmActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 锁屏也能亮屏并显示（API 27+ 用官方 API，低版本用 WindowManager flag）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        // 亮屏期间保持屏幕常亮，避免刚亮起就熄灭
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(0xFF1F2937.toInt())
            setPadding(48, 48, 48, 48)
        }

        val tip = TextView(this).apply {
            text = "设备正在响铃\n（由已配对的 PC 触发）"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 22f
            gravity = Gravity.CENTER
        }

        val btn = Button(this).apply {
            text = "停止响铃"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 18f
            setBackgroundColor(0xFFDC2626.toInt())
            setOnClickListener {
                AntiTheftService.stopAlarm(this@AlarmActivity)
                finish()
            }
        }

        root.addView(tip)
        root.addView(btn)
        setContentView(root)
    }
}
