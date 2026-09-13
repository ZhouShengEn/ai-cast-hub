package com.example.ai_cast_hub

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Process
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 保存统一的 MediaProjection 授权 Intent 及其 resultCode。
 *
 * 关键设计（荣耀/Android 16 投屏闪退修复）：
 * MediaProjection 授权令牌只允许被消费一次。本项目只弹一次授权，把 Intent 注入 flutter_webrtc，
 * 由它唯一一次消费令牌创建屏幕投影（见 MainActivity.injectMediaProjectionDataIntoFlutterWebRTC）。
 * 系统内录**不复用本 holder 的 mediaProjection**，而是事后从 flutter_webrtc 的
 * OrientationAwareScreenCapturer.mediaProjection 反射取出、作为借用方使用（ownsProjection=false），
 * 否则本端再 getMediaProjection 会与 flutter_webrtc 对同一令牌二次消费 → 国产 ROM 闪退。
 *
 * 因此：
 *   - [mediaProjectionData] / [resultCode]：授权结果，供注入 flutter_webrtc 使用；
 *   - [mediaProjection]：已不再承载音频侧的投影（保留字段仅作兼容/兜底，正常流程为 null）。
 */
object SystemAudioProjectionHolder {
    @Volatile
    var mediaProjection: MediaProjection? = null

    @Volatile
    var mediaProjectionData: Intent? = null

    @Volatile
    var resultCode: Int = android.app.Activity.RESULT_CANCELED
}

/**
 * 系统内部音频采集（Android 10 / API 29+）。
 *
 * 基于 AudioPlaybackCapture：以 MediaProjection 令牌为凭据采集**其他应用播放的音频**，
 * 只采系统播放声，不采麦克风。采集到的 16bit PCM 通过回调吐给上层。
 *
 * 注意：必须在 MediaProjection 型前台服务运行期间采集（本项目已由 MediaProjectionService 提供），
 * 否则 Android 14+ 会拒绝采集。
 *
 * 资源与状态保证：
 *  - 采集线程致命错误（ERROR_INVALID_OPERATION / ERROR_BAD_VALUE）会复位 [capturing]、
 *    释放 AudioRecord 并停止 MediaProjection，杜绝后台残留采集。
 *  - [stop] 会停止并释放 AudioRecord、停止 MediaProjection、恢复被静音的媒体音量。
 *  - 媒体音量在采集开始时保存并静音，结束时恢复；并写入 SharedPreferences 以便
 *    App 进程异常退出后下次冷启动恢复（见 [restoreSavedMediaVolume]）。
 */
class SystemAudioCaptureManager {

    companion object {
        private const val TAG = "SystemAudioCapture"

        /** 采样率：44.1kHz，设备兼容性最好 */
        const val SAMPLE_RATE = 44100

        /** 声道：立体声 */
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO
        const val CHANNEL_COUNT = 2

        /** 位深：16bit PCM */
        const val ENCODING = AudioFormat.ENCODING_PCM_16BIT

        /** 单帧时长：20ms。再小会激增 DataChannel 报文数，再大延迟明显 */
        const val FRAME_MILLIS = 20

        /** 单帧字节数：44100 * 2ch * 2B * 20ms = 3528 */
        const val FRAME_BYTES = SAMPLE_RATE * CHANNEL_COUNT * 2 * FRAME_MILLIS / 1000

        private const val PREFS_NAME = "ai_cast_hub_audio"
        private const val KEY_PENDING_MEDIA_VOLUME = "pending_media_volume"

        /** 系统内录是否可用（Android 10 / API 29 起支持 AudioPlaybackCapture） */
        fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        /**
         * 进程冷启动时尝试恢复上一次投屏因崩溃未还原的媒体音量。
         *
         * 场景：投屏期间 App 进程被系统/用户强杀，[stop] 未被执行，
         * 手机会遗留被静音的媒体音量。此处读取持久化值并恢复，避免永久错乱。
         */
        fun restoreSavedMediaVolume(context: Context) {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val pending = prefs.getInt(KEY_PENDING_MEDIA_VOLUME, -1)
            if (pending < 0) return
            prefs.edit().remove(KEY_PENDING_MEDIA_VOLUME).apply()
            try {
                val am = context.applicationContext.getSystemService(AudioManager::class.java)
                am.setStreamVolume(AudioManager.STREAM_MUSIC, pending, 0)
                Log.i(TAG, "已恢复上一次投屏遗留的媒体音量: $pending")
            } catch (e: Exception) {
                Log.w(TAG, "恢复遗留媒体音量失败: ${e.message}")
            }
        }
    }

    private val capturing = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null

    /** 本次采集使用的 MediaProjection 令牌 */
    private var mediaProjectionRef: MediaProjection? = null

    /**
     * 本管理器是否持有 MediaProjection 的所有权。
     * 当与 flutter_webrtc 屏幕捕获复用同一个 MediaProjection 时，所有权归屏幕捕获侧，
     * 音频 stop 时只释放 AudioRecord，不能 stop MediaProjection，否则会把屏幕画面也掐断。
     */
    private var ownsMediaProjection = true

    /** 应用上下文（applicationContext，避免内存泄漏），用于恢复音量 */
    private var appContext: Context? = null

    /** 致命错误回调，用于通知上层采集已死 */
    private var onError: ((String) -> Unit)? = null

    /** 采集开始前保存的原始媒体音量；<0 表示未保存 */
    private var originalMediaVolume = -1

    val isCapturing: Boolean
        get() = capturing.get()

    @SuppressLint("MissingPermission")
    fun start(
        context: Context,
        mediaProjection: MediaProjection,
        onPcm: (ByteArray) -> Unit,
        onError: ((String) -> Unit)? = null,
        ownsProjection: Boolean = true,
    ): Boolean {
        if (!isSupported()) {
            Log.w(TAG, "当前系统不支持内录（需要 Android 10 / API 29+）")
            return false
        }
        if (capturing.get()) {
            Log.w(TAG, "已在采集中，忽略重复 start")
            return true
        }
        this.appContext = context.applicationContext
        this.onError = onError
        // 记录投影所有权：与 flutter_webrtc 复用同一授权令牌时应为 false（借用方），
        // 此时 stop() 只释放 AudioRecord，不 stop 共享投影，避免掐断屏幕画面。
        this.ownsMediaProjection = ownsProjection

        // 保存原始媒体音量并静音（音量仅在录屏授权成功后改动，见 MainActivity 门控）
        saveAndMuteMediaVolume()

        return try {
            val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING)
            if (minBuffer <= 0) {
                Log.e(TAG, "getMinBufferSize 返回非法值: $minBuffer")
                restoreMediaVolume()
                return false
            }
            val bufferSize = maxOf(minBuffer, FRAME_BYTES * 4)

            // 采集尽可能多的「可捕获应用播放声」：
            // - AudioPlaybackCaptureConfiguration 默认 allowedCapturePolicy 即为 ALLOW_CAPTURE_BY_ALL，
            //   故无需显式调用 setAllowedCapturePolicy（该 API 在部分 compileSdk 下不可见，省略不影响范围）；
            // - 通过 addMatchingUsage 匹配常见 usage，尽量覆盖媒体/游戏/语音/通知/辅助音。
            // 注意：被 App 标记为禁止捕获(ALLOW_CAPTURE_BY_NONE) 的音频（如部分 DRM 内容），
            // 或非「应用播放声」（键盘音、系统 UI 音、通话底层），Android 仍不允许非 root 应用采集。
            val builder = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .addMatchingUsage(AudioAttributes.USAGE_ALARM)
                .addMatchingUsage(AudioAttributes.USAGE_NOTIFICATION)
                .addMatchingUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .addMatchingUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_REQUEST)
                .addMatchingUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                .addMatchingUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_DELAYED)
                .addMatchingUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                .addMatchingUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .addMatchingUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .addMatchingUsage(AudioAttributes.USAGE_ASSISTANT)
            val config = builder.build()

            val record = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(CHANNEL_CONFIG)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord 初始化失败, state=${record.state}")
                record.release()
                restoreMediaVolume()
                return false
            }

            mediaProjectionRef = mediaProjection
            audioRecord = record
            capturing.set(true)
            record.startRecording()

            captureThread = Thread {
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
                val buffer = ByteArray(FRAME_BYTES)
                while (capturing.get()) {
                    // 3 参数 read 为阻塞读，无需 READ_BLOCKING（避免 API 23 限制）
                    val read = record.read(buffer, 0, buffer.size)
                    when {
                        read > 0 -> onPcm(buffer.copyOf(read))
                        read == AudioRecord.ERROR_INVALID_OPERATION -> {
                            Log.e(TAG, "AudioRecord 读取返回 ERROR_INVALID_OPERATION，停止采集")
                            handleCaptureError("ERROR_INVALID_OPERATION")
                            break
                        }
                        read == AudioRecord.ERROR_BAD_VALUE -> {
                            Log.e(TAG, "AudioRecord 读取返回 ERROR_BAD_VALUE，停止采集")
                            handleCaptureError("ERROR_BAD_VALUE")
                            break
                        }
                        read < 0 -> {
                            Log.e(TAG, "AudioRecord 读取返回未知错误码: $read，停止采集")
                            handleCaptureError("unknown($read)")
                            break
                        }
                    }
                }
                Log.d(TAG, "采集线程已退出")
            }.apply {
                name = "system-audio-capture"
                start()
            }

            Log.i(
                TAG,
                "系统内录已启动: ${SAMPLE_RATE}Hz / ${CHANNEL_COUNT}ch / 16bit, " +
                    "帧=${FRAME_BYTES}B, 缓冲=${bufferSize}B"
            )
            true
        } catch (e: Exception) {
            Log.e(TAG, "启动系统内录失败", e)
            capturing.set(false)
            // 释放已持有的投影令牌与 AudioRecord，避免半初始化状态下后台残留（P0-1）
            releaseAudioRecordInternal()
            restoreMediaVolume()
            false
        }
    }

    /** 采集线程内的致命错误处理：复位状态、释放资源、停止投影、通知上层 */
    private fun handleCaptureError(reason: String) {
        Log.e(TAG, "采集线程致命错误: $reason")
        releaseAudioRecordInternal()
        restoreMediaVolume()
        try {
            onError?.invoke(reason)
        } catch (e: Exception) {
            Log.w(TAG, "onError 回调异常: ${e.message}")
        }
    }

    /**
     * 仅释放 AudioRecord + 停止 MediaProjection（不 join 线程，可在采集线程内安全调用）。
     */
    private fun releaseAudioRecordInternal() {
        capturing.set(false)
        try {
            if (audioRecord?.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                audioRecord?.stop()
            }
        } catch (e: Exception) {
            Log.w(TAG, "停止 AudioRecord 失败: ${e.message}")
        }
        try {
            audioRecord?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 AudioRecord 失败: ${e.message}")
        }
        audioRecord = null

        // 停止并释放本路独立 MediaProjection 令牌（不影响屏幕画面投屏）
        try {
            mediaProjectionRef?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "停止 MediaProjection 失败: ${e.message}")
        }
        mediaProjectionRef = null
        SystemAudioProjectionHolder.mediaProjection = null
    }

    /** 保存原始媒体音量并静音（仅采集开始时调用） */
    private fun saveAndMuteMediaVolume() {
        val ctx = appContext ?: return
        try {
            val am = ctx.getSystemService(AudioManager::class.java) ?: return
            originalMediaVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            am.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
            // 持久化，供进程崩溃后冷启动恢复
            ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putInt(KEY_PENDING_MEDIA_VOLUME, originalMediaVolume)
                .apply()
            Log.i(TAG, "已保存并静音媒体音量（原值=$originalMediaVolume）")
        } catch (e: Exception) {
            Log.w(TAG, "保存/静音媒体音量失败: ${e.message}")
            originalMediaVolume = -1
        }
    }

    /** 恢复媒体音量并清除持久化标记 */
    private fun restoreMediaVolume() {
        if (originalMediaVolume < 0) return
        val value = originalMediaVolume
        originalMediaVolume = -1
        val ctx = appContext
        try {
            ctx?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                ?.edit()
                ?.remove(KEY_PENDING_MEDIA_VOLUME)
                ?.apply()
            val am = ctx?.getSystemService(AudioManager::class.java)
            am?.setStreamVolume(AudioManager.STREAM_MUSIC, value, 0)
            Log.i(TAG, "已恢复媒体音量: $value")
        } catch (e: Exception) {
            Log.w(TAG, "恢复媒体音量失败: ${e.message}")
        }
    }

    /** 停止采集并彻底释放 AudioRecord 与 MediaProjection，防止后台持续录音造成泄漏 */
    fun stop() {
        if (!capturing.get() && audioRecord == null && mediaProjectionRef == null) return

        capturing.set(false)

        try {
            captureThread?.join(500)
        } catch (e: Exception) {
            Log.w(TAG, "等待采集线程退出中断: ${e.message}")
        } finally {
            captureThread = null
        }

        releaseAudioRecordInternal()
        restoreMediaVolume()

        Log.i(TAG, "系统内录已停止，AudioRecord 与 MediaProjection 已释放，音量已恢复")
    }
}
