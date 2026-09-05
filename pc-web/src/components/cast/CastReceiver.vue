<template>
  <div ref="containerRef" class="relative w-full aspect-video bg-black rounded-lg overflow-hidden">
    <!-- 视频区域（始终渲染，确保 videoEl 始终可用） -->
    <video
      ref="videoEl"
      class="w-full h-full object-contain"
      autoplay
      playsinline
      :muted="isMuted"
    ></video>

    <!-- 等待/加载状态覆盖层 -->
    <div
      v-if="connectionState !== 'connected'"
      class="absolute inset-0 flex flex-col items-center justify-center bg-black/60 text-white"
    >
      <Spinner size="lg" color="white" />
      <p class="mt-4 text-sm">
        {{ stateMessage }}
      </p>
    </div>

    <!-- 远程控制交互层（连接成功后显示） -->
    <div
      v-if="connectionState === 'connected'"
      class="absolute inset-0 cursor-pointer z-10 select-none touch-none"
      @pointerdown="onPointerDown"
      @pointermove="onPointerMove"
      @pointerup="onPointerUp"
      @pointercancel="onPointerCancel"
      @wheel.prevent="onWheel"
    ></div>

    <!-- 顶部连接状态 -->
    <div class="absolute top-3 left-3 z-20">
      <ConnectionBadge :state="connectionState" />
    </div>

    <!-- 全屏按钮 -->
    <button
      v-if="connectionState === 'connected'"
      class="absolute bottom-3 right-3 w-9 h-9 rounded-lg bg-white/20 hover:bg-white/30 text-white flex items-center justify-center transition-colors z-20"
      @click.stop="toggleFullscreen"
      title="全屏"
    >
      ⛶
    </button>

    <!-- 底部左侧：画质选择 + 手机系统声音开关 + 视频流音轨静音 -->
    <div
      v-if="connectionState === 'connected'"
      class="absolute bottom-3 left-3 z-20 flex items-center gap-2"
    >
      <!-- 投屏画质档位：高清 / 流畅 / 省流，切换经 RTCRtpSender 实时生效不打断投屏 -->
      <select
        class="h-9 rounded-lg bg-white/20 hover:bg-white/30 text-white text-sm px-2 outline-none cursor-pointer"
        :value="currentQuality"
        @change="emit('set-quality', $event.target.value)"
        title="投屏画质"
      >
        <option
          v-for="(p, key) in qualityProfiles"
          :key="key"
          :value="key"
          class="text-black"
        >{{ p.label }}</option>
      </select>

      <!--
        手机系统内录音频（AudioPlaybackCapture）。
        点击必须在用户手势中触发，否则浏览器的 AudioContext 无法启动、会没声音。
      -->
      <button
        v-if="systemAudioSupported"
        class="px-3 h-9 rounded-lg text-white text-sm flex items-center gap-1 transition-colors"
        :class="systemAudioActive
          ? 'bg-green-500/80 hover:bg-green-500'
          : 'bg-white/20 hover:bg-white/30'"
        :title="systemAudioActive ? '关闭手机系统声音' : '开启手机系统声音'"
        @click.stop="emit('toggle-system-audio', !systemAudioActive)"
      >
        {{ systemAudioActive ? '🔊 系统声音' : '🔈 开系统声音' }}
      </button>
      <span
        v-else
        class="px-3 h-9 rounded-lg bg-white/10 text-white/40 text-sm flex items-center cursor-not-allowed"
        title="手机系统版本低于 Android 10，不支持系统内录"
      >
        🔈 不支持内录
      </span>

      <!-- 视频流自带音轨的静音（摄像头模式的麦克风声） -->
      <button
        v-if="hasAudioTrack"
        class="w-9 h-9 rounded-lg bg-white/20 hover:bg-white/30 text-white flex items-center justify-center transition-colors"
        @click.stop="toggleMute"
        :title="isMuted ? '取消静音' : '静音'"
      >
        {{ isMuted ? '🔇' : '🔊' }}
      </button>
    </div>

    <!-- 操作提示 -->
    <div
      v-if="connectionState === 'connected'"
      class="absolute top-3 right-3 text-xs text-white/50 z-20 text-right"
    >
      🖱️ 远程控制已开启<br/>
      🖱️ 长按 0.5 秒 = 手机长按<br/>
      ⌨️ Home/Bksp/Tab 快捷操作
    </div>

    <!-- 无障碍服务未开启时提示：否则点击/滑动不会有任何效果 -->
    <div
      v-if="connectionState === 'connected' && accessibilityEnabled === false"
      class="absolute top-12 left-1/2 -translate-x-1/2 z-30 max-w-[92%] px-3 py-2 rounded-lg bg-amber-500/90 text-white text-xs shadow-lg flex items-center gap-2"
    >
      <span>⚠️ 手机端未开启无障碍服务，远程触控不可用</span>
      <button
        class="shrink-0 px-2 py-0.5 rounded bg-white/20 hover:bg-white/30 transition-colors"
        @click.stop="emit('refresh-status')"
      >
        重新检测
      </button>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import Spinner from '../common/Spinner.vue'
import ConnectionBadge from './ConnectionBadge.vue'

const props = defineProps({
  /** 连接状态 */
  connectionState: { type: String, default: 'disconnected' },
  /** 远程视频流 */
  stream: { type: Object, default: null },
  /** 手机端上报的远程控制状态：{ accessibilityEnabled, platform } */
  remoteStatus: { type: Object, default: null },
  /** 手机端是否支持系统内录（Android 10+） */
  systemAudioSupported: { type: Boolean, default: false },
  /** 系统内录是否已开启 */
  systemAudioActive: { type: Boolean, default: false },
  /** 当前画质档位 key（high/medium/low） */
  currentQuality: { type: String, default: 'high' },
  /** 画质档位表 { key: { label, width, height, fps, bitrate } } */
  qualityProfiles: { type: Object, default: () => ({}) },
})

const emit = defineEmits(['control', 'refresh-status', 'toggle-system-audio', 'set-quality'])

/** 暴露 video ref 供 composable 绑定 */
const videoEl = ref(null)
const containerRef = ref(null)
defineExpose({ videoEl })

/** 静音状态（默认静音以满足浏览器自动播放策略，用户可手动取消） */
const isMuted = ref(true)

/** 远程控制状态 */
const activePointerId = ref(null)
const gestureStart = ref(null)
const gestureLast = ref(null)
const gestureStartedAt = ref(0)
const gestureDistance = ref(0)
const TAP_THRESHOLD_PX = 8

/** 长按判定阈值：按住且位移未超 tap 阈值，持续超过该时长即触发 long_press */
const LONG_PRESS_MS = 500
let longPressTimer = null
let longPressFired = false

/**
 * 手机端无障碍服务是否可用。
 * null 表示手机端尚未上报状态（例如旧版本 App），此时不显示提示，避免误报。
 */
const accessibilityEnabled = computed(() => {
  if (!props.remoteStatus) return null
  return props.remoteStatus.accessibilityEnabled === true
})

/**
 * 获取视频实际渲染区域（扣除 object-contain 产生的 letterbox 黑边）
 *
 * 关键兜底：视频原始宽高未知时（流刚建立、首帧未到）不再返回 null，
 * 而是退回 video 元素的盒子。原实现此刻直接 return null，
 * 使得 onPointerDown 静默退出 —— 表现就是「点画面完全没反应」。
 */
function _getVideoRect() {
  const video = videoEl.value
  if (!video) return null

  const box = containerRef.value
    ? containerRef.value.getBoundingClientRect()
    : video.getBoundingClientRect()
  if (!box.width || !box.height) return null

  const videoWidth = video.videoWidth
  const videoHeight = video.videoHeight

  // 原始宽高未知 → 算不出黑边，按元素盒子处理，保证点击仍可用
  if (!videoWidth || !videoHeight) {
    return {
      width: box.width,
      height: box.height,
      offsetX: 0,
      offsetY: 0,
      videoWidth,
      videoHeight,
      fallback: true,
    }
  }

  const aspectRatio = videoWidth / videoHeight
  const containerAspectRatio = box.width / box.height

  let renderWidth, renderHeight, offsetX, offsetY

  if (aspectRatio > containerAspectRatio) {
    renderWidth = box.width
    renderHeight = box.width / aspectRatio
    offsetX = 0
    offsetY = (box.height - renderHeight) / 2
  } else {
    renderHeight = box.height
    renderWidth = box.height * aspectRatio
    offsetX = (box.width - renderWidth) / 2
    offsetY = 0
  }

  return {
    width: renderWidth,
    height: renderHeight,
    offsetX,
    offsetY,
    videoWidth,
    videoHeight,
    fallback: false,
  }
}

/** 将鼠标坐标转换为手机屏幕归一化坐标（0~1） */
function _mapToPhonePercent(clientX, clientY) {
  const videoRect = _getVideoRect()
  if (!videoRect) {
    console.warn('[CastReceiver] ⚠️ 定位不到视频区域，本次点击被忽略')
    return null
  }

  const box = containerRef.value
    ? containerRef.value.getBoundingClientRect()
    : videoEl.value.getBoundingClientRect()
  const x = clientX - box.left - videoRect.offsetX
  const y = clientY - box.top - videoRect.offsetY

  if (x < 0 || x > videoRect.width || y < 0 || y > videoRect.height) {
    // 落在黑边内，属于画面之外的点击，静默忽略
    return null
  }

  return {
    x: Number((x / videoRect.width).toFixed(6)),
    y: Number((y / videoRect.height).toFixed(6)),
  }
}

/** Pointer Events 同时覆盖鼠标、触控笔和浏览器触摸事件。 */
function onPointerDown(e) {
  // 上一个手势没正常收尾（指针在容器外抬起、页面切走、断点调试等）时强制复位。
  // 原实现里 activePointerId 一旦残留就永久非 null，之后每一次点击都会被这里吞掉。
  if (activePointerId.value !== null) {
    console.warn('[CastReceiver] 上一个手势未正常收尾，强制复位')
    _resetPointerGesture()
  }
  if (e.pointerType === 'mouse' && e.button !== 0) return

  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (!percent) return

  activePointerId.value = e.pointerId
  gestureStart.value = { ...percent, clientX: e.clientX, clientY: e.clientY }
  gestureLast.value = percent
  gestureStartedAt.value = performance.now()
  gestureDistance.value = 0
  longPressFired = false

  // 长按检测：按住不动达到阈值即触发，触发后 onPointerUp 不再补发 tap
  longPressTimer = setTimeout(() => {
    longPressTimer = null
    if (gestureDistance.value <= TAP_THRESHOLD_PX && gestureLast.value) {
      longPressFired = true
      const held = Math.round(performance.now() - gestureStartedAt.value)
      emit('control', {
        type: 'long_press',
        x: gestureLast.value.x,
        y: gestureLast.value.y,
        duration: Math.max(500, Math.min(3000, held)),
      })
    }
  }, LONG_PRESS_MS)

  e.currentTarget.setPointerCapture?.(e.pointerId)
  e.preventDefault()
}

function onPointerMove(e) {
  if (activePointerId.value !== e.pointerId || !gestureStart.value) return
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    gestureLast.value = percent
    gestureDistance.value = Math.max(
      gestureDistance.value,
      Math.hypot(e.clientX - gestureStart.value.clientX, e.clientY - gestureStart.value.clientY),
    )
    // 位移超过阈值即认定为滑动，取消长按计时
    if (gestureDistance.value > TAP_THRESHOLD_PX) {
      _clearLongPressTimer()
    }
  }
  e.preventDefault()
}

function onPointerUp(e) {
  if (activePointerId.value !== e.pointerId || !gestureStart.value) return
  _clearLongPressTimer()
  const end = _mapToPhonePercent(e.clientX, e.clientY) || gestureLast.value
  const start = gestureStart.value
  const duration = Math.max(50, Math.min(2000, Math.round(performance.now() - gestureStartedAt.value)))

  // 长按已触发时不再补发 tap，避免点击与长按重复执行
  if (end && !longPressFired) {
    if (gestureDistance.value <= TAP_THRESHOLD_PX) {
      console.log('[CastReceiver] 🖱️ tap', end.x, end.y)
      emit('control', { type: 'tap', x: end.x, y: end.y })
    } else {
      console.log('[CastReceiver] 🖱️ swipe', start, '→', end, `${duration}ms`)
      emit('control', {
        type: 'swipe',
        startX: start.x,
        startY: start.y,
        endX: end.x,
        endY: end.y,
        duration,
      })
    }
  }

  e.currentTarget.releasePointerCapture?.(e.pointerId)
  _resetPointerGesture()
  e.preventDefault()
}

function onPointerCancel(e) {
  if (activePointerId.value !== e.pointerId) return
  e.currentTarget.releasePointerCapture?.(e.pointerId)
  _resetPointerGesture()
}

/** 取消长按计时器 */
function _clearLongPressTimer() {
  if (longPressTimer !== null) {
    clearTimeout(longPressTimer)
    longPressTimer = null
  }
}

function _resetPointerGesture() {
  _clearLongPressTimer()
  longPressFired = false
  activePointerId.value = null
  gestureStart.value = null
  gestureLast.value = null
  gestureStartedAt.value = 0
  gestureDistance.value = 0
}

/** 鼠标滚轮 */
function onWheel(e) {
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    emit('control', {
      type: 'scroll',
      x: percent.x,
      y: percent.y,
      deltaX: e.deltaX,
      deltaY: e.deltaY,
    })
  }
}

const stateMessage = computed(() => {
  const map = {
    connecting: '正在连接手机...',
    disconnected: '等待手机投屏…',
    error: '连接失败，请重试',
    reconnecting: '正在重新连接...',
  }
  return map[props.connectionState] || '等待手机投屏…'
})

/** 远端流是否包含音频轨 —— 无音频时不显示「开启声音」按钮，避免误导 */
const hasAudioTrack = ref(false)

/** 绑定远程流到 video 元素 */
function _bindStream(stream) {
  if (!videoEl.value) return
  videoEl.value.srcObject = stream || null
  if (stream) {
    const tracks = stream.getTracks()
    hasAudioTrack.value = tracks.some((t) => t.kind === 'audio')
    console.log(
      '[CastReceiver] video.srcObject 已绑定, tracks:',
      tracks.map((t) => `${t.kind}(id=${t.id.substring(0, 8)})`).join(', '),
    )

    // 音频轨可能晚于视频轨到达（SDP 协商或 addTrack 时序差异），
    // 监听轨道变化，确保「开启声音」按钮能及时出现
    stream.onaddtrack = (e) => {
      if (e.track?.kind === 'audio') {
        hasAudioTrack.value = true
        console.log('[CastReceiver] 检测到新增音频轨')
      }
    }
    stream.onremovetrack = () => {
      const stillHasAudio = stream.getAudioTracks().length > 0
      hasAudioTrack.value = stillHasAudio
      if (!stillHasAudio) {
        console.log('[CastReceiver] 音频轨已移除，恢复静音')
        isMuted.value = true
        if (videoEl.value) videoEl.value.muted = true
      }
    }
  } else {
    hasAudioTrack.value = false
    console.log('[CastReceiver] video.srcObject 已解绑')
  }
}

onMounted(() => {
  // 组件挂载后，如果 stream 已存在（可能在挂载前就已到达），立即绑定
  if (props.stream) {
    console.log('[CastReceiver] 挂载时绑定已有流:', props.stream.id)
    _bindStream(props.stream)
  }
  window.addEventListener('keydown', _handleKeyDown)
})

/** 监听 stream prop 变化 */
watch(
  () => props.stream,
  (stream) => {
    console.log('[CastReceiver] watch stream变化:', stream ? `有新流(id=${stream.id.substring(0, 8)})` : 'null')
    _bindStream(stream)
  },
)

/** 切换视频流自带音轨的静音（浏览器自动播放策略要求由用户手势触发） */
function toggleMute() {
  isMuted.value = !isMuted.value
  if (videoEl.value) {
    videoEl.value.muted = isMuted.value
    if (!isMuted.value) {
      videoEl.value.play().catch(() => {})
    }
  }
}

/** 全屏切换 */
function toggleFullscreen() {
  const el = videoEl.value?.parentElement || videoEl.value
  if (!el) return
  if (document.fullscreenElement) {
    document.exitFullscreen()
  } else {
    el.requestFullscreen()
  }
}

/** 键盘快捷键处理 */
function _handleKeyDown(e) {
  if (props.connectionState !== 'connected') return

  const keyMap = {
    'h': 'home',
    'H': 'home',
    'Backspace': 'back',
    'Tab': 'recent',
  }

  const action = keyMap[e.key]
  if (action) {
    e.preventDefault()
    emit('control', { type: action })
    console.log('[CastReceiver] 快捷键触发:', action)
  }
}

onUnmounted(() => {
  _clearLongPressTimer()
  if (videoEl.value) {
    videoEl.value.srcObject = null
  }
  window.removeEventListener('keydown', _handleKeyDown)
})
</script>
