import { ref } from 'vue'

/**
 * PCM 播放器（Web Audio API）
 *
 * DataChannel 送来的 16bit PCM 帧不带时间戳，网络抖动会直接表现为爆音/断音，
 * 因此这里做两件事：
 *   1. 抖动缓冲 —— 先攒够 PREBUFFER_FRAMES 帧再开播；缓冲见底就停下重新攒，
 *      宁可短暂停顿也不连续爆音。
 *   2. 前瞻调度 —— 用 AudioContext 的采样时钟排下一帧的播放时刻，
 *      而不是 setTimeout 逐帧播（后者的时钟误差会累积成明显抖动）。
 *
 * 浏览器自动播放策略：AudioContext 初始为 suspended，必须在用户手势
 * （点击开关）里 resume，否则无声。
 */
export function usePcmPlayer() {
  /** 是否正在发声 */
  const isPlaying = ref(false)

  let ctx = null
  /** 待播放的 AudioBuffer 队列 */
  let queue = []
  /** 下一帧的播放时刻（AudioContext 时间轴，秒） */
  let nextStartTime = 0
  let sampleRate = 44100
  let channels = 2
  let schedulerTimer = null

  /** 预缓冲帧数：20ms/帧 × 4 = 80ms，足以吸收常见抖动 */
  const PREBUFFER_FRAMES = 4
  /** 队列上限：超过则丢最旧的帧，防止延迟不断累积 */
  const MAX_QUEUE_FRAMES = 50
  /** 前瞻窗口：始终排好未来 200ms 的音频 */
  const LOOKAHEAD_SEC = 0.2

  /** 按手机端上报的格式初始化（sampleRate / channels 必须与采集端一致） */
  function configure(format) {
    if (!format) return
    sampleRate = format.sampleRate || 44100
    channels = format.channels || 2
    console.log('[PcmPlayer] 音频格式:', sampleRate, 'Hz /', channels, 'ch')
  }

  function ensureContext() {
    if (ctx) return ctx
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) {
      console.warn('[PcmPlayer] 当前浏览器不支持 Web Audio API')
      return null
    }
    ctx = new AC()
    return ctx
  }

  /**
   * 16bit 有符号小端 PCM（交错）→ AudioBuffer
   * Int16Array 用的是平台原生字节序，Android PCM 为小端，二者一致。
   */
  function _toAudioBuffer(int16) {
    const frameCount = Math.floor(int16.length / channels)
    const buffer = ctx.createBuffer(channels, frameCount, sampleRate)
    for (let ch = 0; ch < channels; ch++) {
      const data = buffer.getChannelData(ch)
      for (let i = 0; i < frameCount; i++) {
        // 32768 = 2^15，映射到 -1.0 ~ 1.0
        data[i] = int16[i * channels + ch] / 32768
      }
    }
    return buffer
  }

  /** 前瞻调度：把队列里的帧按采样时钟排进播放时间轴 */
  function _schedule() {
    if (!ctx) return

    if (queue.length === 0) {
      // 缓冲见底：停止发声，等重新攒够再播
      if (isPlaying.value) {
        console.log('[PcmPlayer] 缓冲见底，暂停等待')
      }
      isPlaying.value = false
      nextStartTime = 0
      return
    }

    while (queue.length > 0 && nextStartTime < ctx.currentTime + LOOKAHEAD_SEC) {
      const buf = queue.shift()
      const source = ctx.createBufferSource()
      source.buffer = buf
      source.connect(ctx.destination)
      const startAt = Math.max(nextStartTime, ctx.currentTime)
      source.start(startAt)
      nextStartTime = startAt + buf.duration
      isPlaying.value = true
    }
  }

  /** 送入一帧 PCM（Int16Array 或可转为 Int16Array 的 ArrayBuffer） */
  function enqueue(raw) {
    const context = ensureContext()
    if (!context) return

    const int16 = raw instanceof Int16Array ? raw : new Int16Array(raw)
    if (int16.length === 0) return

    queue.push(_toAudioBuffer(int16))
    while (queue.length > MAX_QUEUE_FRAMES) queue.shift()

    if (!isPlaying.value && queue.length >= PREBUFFER_FRAMES) {
      // 起播留 20ms 余量，避免刚排好就到点
      nextStartTime = Math.max(nextStartTime, context.currentTime + 0.02)
    }

    _schedule()
    if (!schedulerTimer) {
      schedulerTimer = setInterval(_schedule, 40)
    }
  }

  /**
   * 在用户手势中调用以解除浏览器自动播放限制。
   * 返回是否可用。
   */
  async function unlock() {
    const context = ensureContext()
    if (!context) return false
    if (context.state === 'suspended') {
      try {
        await context.resume()
      } catch (err) {
        console.warn('[PcmPlayer] AudioContext resume 失败:', err)
        return false
      }
    }
    return context.state === 'running'
  }

  /** 停止播放并释放 AudioContext */
  function stop() {
    if (schedulerTimer) {
      clearInterval(schedulerTimer)
      schedulerTimer = null
    }
    queue = []
    nextStartTime = 0
    isPlaying.value = false
    if (ctx) {
      try {
        ctx.close()
      } catch (err) {
        console.warn('[PcmPlayer] 关闭 AudioContext 失败:', err)
      }
      ctx = null
    }
  }

  return { isPlaying, configure, enqueue, unlock, stop }
}
