package com.example.ai_cast_hub

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Process
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 保存自建的 MediaProjection 令牌。
 *
 * flutter_webrtc 内部的 MediaProjection 授权 Intent 是其 GetUserMediaImpl 的私有字段且无 getter，
 * Dart 层拿不到，所以系统内录必须由我们自己再申请一次屏幕采集授权，并在此保存令牌。
 */
object SystemAudioProjectionHolder {
    @Volatile
    var mediaProjection: MediaProjection? = null
}

/**
 * 系统内部音频采集（Android 10 / API 29+）。
 *
 * 基于 AudioPlaybackCapture：以 MediaProjection 令牌为凭据采集**其他应用播放的音频**，
 * 只采系统播放声，不采麦克风。采集到的 16bit PCM 通过回调吐给上层。
 *
 * 注意：必须在 MediaProjection 型前台服务运行期间采集（本项目已由 MediaProjectionService 提供），
 * 否则 Android 14+ 会拒绝采集。
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

        /** 系统内录是否可用（Android 10 / API 29 起支持 AudioPlaybackCapture） */
        fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    private val capturing = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null

    val isCapturing: Boolean
        get() = capturing.get()

    @SuppressLint("MissingPermission")
    fun start(mediaProjection: MediaProjection, onPcm: (ByteArray) -> Unit): Boolean {
        if (!isSupported()) {
            Log.w(TAG, "当前系统不支持内录（需要 Android 10 / API 29+）")
            return false
        }
        if (capturing.get()) {
            Log.w(TAG, "已在采集中，忽略重复 start")
            return true
        }

        return try {
            val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING)
            if (minBuffer <= 0) {
                Log.e(TAG, "getMinBufferSize 返回非法值: $minBuffer")
                return false
            }
            val bufferSize = maxOf(minBuffer, FRAME_BYTES * 4)

            val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .build()

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
                return false
            }

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
                            break
                        }
                        read == AudioRecord.ERROR_BAD_VALUE -> {
                            Log.e(TAG, "AudioRecord 读取返回 ERROR_BAD_VALUE，停止采集")
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
            audioRecord = null
            false
        }
    }

    /** 停止采集并彻底释放 AudioRecord，防止后台持续录音造成泄漏 */
    fun stop() {
        if (!capturing.get() && audioRecord == null) return

        capturing.set(false)

        try {
            if (audioRecord?.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                audioRecord?.stop()
            }
        } catch (e: Exception) {
            Log.w(TAG, "停止 AudioRecord 失败: ${e.message}")
        }

        try {
            captureThread?.join(500)
        } catch (e: Exception) {
            Log.w(TAG, "等待采集线程退出中断: ${e.message}")
        } finally {
            captureThread = null
        }

        try {
            audioRecord?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 AudioRecord 失败: ${e.message}")
        }
        audioRecord = null

        Log.i(TAG, "系统内录已停止，AudioRecord 已释放")
    }
}
