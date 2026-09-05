<template>
  <div ref="containerRef" class="relative w-full aspect-video bg-black rounded-lg overflow-hidden">
    <!-- 视频变换层：双指捏合缩放 / 平移作用于此层，坐标映射按屏幕实际渲染框计算 -->
    <div
      ref="transformRef"
      class="absolute inset-0 flex items-center justify-center will-change-transform"
      :style="transformStyle"
    >
      <!-- 视频区域（始终渲染，确保 videoEl 始终可用） -->
      <video
        ref="videoEl"
        class="w-full h-full object-contain"
        autoplay
        playsinline
        :muted="isMuted"
      ></video>
    </div>

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

    <!-- 缩放复位按钮（双指放大后出现） -->
    <button
      v-if="connectionState === 'connected' && zoom > 1.01"
      class="absolute bottom-3 right-14 w-9 h-9 rounded-lg bg-white/20 hover:bg-white/30 text-white flex items-center justify-center transition-colors z-20 text-base"
      @click.stop="resetZoom"
      title="重置缩放"
    >
      ⤢
    </button>

    <!-- 底部左侧：画质选择 + 手机系统声音开关 + 视频流音轨静音 -->
    <div
      v-if="connectionState === 'connected'"
      class="absolute bottom-3 left-3 z-20 flex items-center gap-2 flex-wrap max-w-[calc(100%-5rem)]"
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
        :class="(systemAudioActive && !systemAudioMuted)
          ? 'bg-green-500/80 hover:bg-green-500'
          : 'bg-white/20 hover:bg-white/30'"
        :title="(systemAudioActive && !systemAudioMuted) ? '静音手机系统声音' : '取消静音'"
        @click.stop="emit('toggle-system-audio-mute')"
      >
        {{ (systemAudioActive && !systemAudioMuted) ? '🔊 系统声音' : '🔇 已静音' }}
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

    <!-- 操作提示（桌面：鼠标/键盘；移动端：触控/手势） -->
    <div
      v-if="connectionState === 'connected'"
      class="absolute top-3 right-3 text-xs text-white/50 z-20 text-right leading-relaxed"
    >
      <template v-if="ui.isMobile">
        👆 单指点击/滑动控制手机<br/>
        🤏 双指捏合缩放画面<br/>
        ⛶ 全屏后横屏观看
      </template>
      <template v-else>
        🖱️ 画布可点击/拖拽控制手机<br/>
        🖱️ 滚轮滚动 · 长按 0.5 秒 = 手机长按<br/>
        ⌨️ H/Bksp/Tab = Home/Back/多任务
      </template>
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
import { useUiStore } from '../../stores/ui'

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
  /** 系统音频是否被本地静音（仅控制播放，不触发权限） */
  systemAudioMuted: { type: Boolean, default: false },
  /** 当前画质档位 key（high/medium/low） */
  currentQuality: { type: String, default: 'high' },
  /** 画质档位表 { key: { label, width, height, fps, bitrate } } */
  qualityProfiles: { type: Object, default: () => ({}) },
})

const emit = defineEmits([
  'control',
  'refresh-status',
  'toggle-system-audio-mute',
  'set-quality',
  'unlock-audio',
])

/** UI 状态（移动端判定） */
const ui = useUiStore()

/** 暴露 video ref 供 composable 绑定 */
const videoEl = ref(null)
const containerRef = ref(null)
const transformRef = ref(null)
defineExpose({ videoEl })

// ---- 双指缩放 / 平移状态 ----
const zoom = ref(1)
const panX = ref(0)
const panY = ref(0)
const MIN_ZOOM = 1
const MAX_ZOOM = 4
/** 当前活跃指针集合（用于区分单指远程控制 / 双指捏合） */
const pointers = new Map()
let pinchActive = false
let pinchStartDist = 0
let pinchStartZoom = 1
let pinchStartPan = { x: 0, y: 0 }
let pinchStartMid = { x: 0, y: 0 }

/** 变换层样式：先平移后缩放，原点居中 */
const transformStyle = computed(() => ({
  transform: `translate(${panX.value}px, ${panY.value}px) scale(${zoom.value})`,
  transformOrigin: 'center center',
}))

/** 缩放复位 */
function resetZoom() {
  zoom.value = 1
  panX.value = 0
  panY.value = 0
}

function _clampPan() {
  const box = containerRef.value?.getBoundingClientRect()
  if (!box) return
  // 限制平移范围，避免画面被拖出可视区
  const maxX = ((zoom.value - 1) * box.width) / 2
  const maxY = ((zoom.value - 1) * box.height) / 2
  panX.value = Math.max(-maxX, Math.min(maxX, panX.value))
  panY.value = Math.max(-maxY, Math.min(maxY, panY.value))
  if (zoom.value <= 1.01) {
    panX.value = 0
    panY.value = 0
  }
}

function _distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y)
}
function _midpoint(a, b) {
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
}

/** 双指捏合开始 */
function _startPinch() {
  pinchActive = true
  const pts = [...pointers.values()]
  pinchStartDist = _distance(pts[0], pts[1]) || 1
  pinchStartZoom = zoom.value
  pinchStartPan = { x: panX.value, y: panY.value }
  pinchStartMid = _midpoint(pts[0], pts[1])
}

/** 双指捏合 / 平移更新 */
function _updatePinch() {
  const pts = [...pointers.values()]
  if (pts.length < 2) return
  const dist = _distance(pts[0], pts[1])
  zoom.value = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, (pinchStartZoom * dist) / pinchStartDist))
  const mid = _midpoint(pts[0], pts[1])
  panX.value = pinchStartPan.x + (mid.x - pinchStartMid.x)
  panY.value = pinchStartPan.y + (mid.y - pinchStartMid.y)
  _clampPan()
}

/** 若正在远程控制，先补发 up 释放手机端按压，避免卡住 */
function _releaseRemoteIfActive() {
  if (gestureLast.value) {
    emit('control', {
      type: 'remote_touch',
      action: 'up',
      nx: gestureLast.value.x,
      ny: gestureLast.value.y,
    })
  }
  _resetPointerGesture()
}

/** 静音状态（默认静音以满足浏览器自动播放策略，用户可手动取消） */
const isMuted = ref(true)

/** 远程控制状态 */
const activePointerId = ref(null)
const gestureStart = ref(null)
const gestureLast = ref(null)
/** 上一次已下发 move 的归一化坐标，用于节流判断 */
const gestureLastSent = ref(null)
const gestureStartedAt = ref(0)
const gestureDistance = ref(0)
const TAP_THRESHOLD_PX = 8

/** 长按判定阈值：按住且位移未超 tap 阈值，持续超过该时长即触发 long_press */
const LONG_PRESS_MS = 500
let longPressTimer = null
let longPressFired = false

/** move 节流：最小时间间隔与最小位移，避免高频 PointerMove 淹没控制通道 */
const MOVE_THROTTLE_MS = 16
const MOVE_MIN_DELTA = 0.004
let lastMoveSentAt = 0

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
 * 直接使用 video 元素自身的屏幕矩形（含祖先 transform 缩放/平移），
 * 因此对双指缩放/平移同样准确。
 *
 * 关键兜底：视频原始宽高未知时（流刚建立、首帧未到）不再返回 null，
 * 而是退回 video 元素的盒子。原实现此刻直接 return null，
 * 使得 onPointerDown 静默退出 —— 表现就是「点画面完全没反应」。
 */
function _getVideoRect() {
  const video = videoEl.value
  if (!video) return null

  const rect = video.getBoundingClientRect()
  if (!rect.width || !rect.height) return null

  const videoWidth = video.videoWidth
  const videoHeight = video.videoHeight

  // 原始宽高未知 → 算不出黑边，按元素盒子处理，保证点击仍可用
  if (!videoWidth || !videoHeight) {
    return {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      offsetX: 0,
      offsetY: 0,
      videoWidth,
      videoHeight,
      fallback: true,
    }
  }

  const aspectRatio = videoWidth / videoHeight
  const boxAspectRatio = rect.width / rect.height

  let renderWidth, renderHeight, offsetX, offsetY

  if (aspectRatio > boxAspectRatio) {
    renderWidth = rect.width
    renderHeight = rect.width / aspectRatio
    offsetX = 0
    offsetY = (rect.height - renderHeight) / 2
  } else {
    renderHeight = rect.height
    renderWidth = rect.height * aspectRatio
    offsetX = (rect.width - renderWidth) / 2
    offsetY = 0
  }

  return {
    left: rect.left,
    top: rect.top,
    width: renderWidth,
    height: renderHeight,
    offsetX,
    offsetY,
    videoWidth,
    videoHeight,
    fallback: false,
  }
}

/** 将屏幕坐标转换为手机屏幕归一化坐标（0~1） */
function _mapToPhonePercent(clientX, clientY) {
  const videoRect = _getVideoRect()
  if (!videoRect) {
    console.warn('[CastReceiver] ⚠️ 定位不到视频区域，本次点击被忽略')
    return null
  }

  const x = clientX - videoRect.left - videoRect.offsetX
  const y = clientY - videoRect.top - videoRect.offsetY

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
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

  // 双指及以上 → 进入捏合缩放，先释放可能正在进行的远程控制
  if (pointers.size >= 2) {
    if (activePointerId.value !== null) {
      _releaseRemoteIfActive()
    }
    _startPinch()
    e.preventDefault()
    return
  }

  // 上一个手势没正常收尾（指针在容器外抬起、页面切走、断点调试等）时强制复位。
  // 原实现里 activePointerId 一旦残留就永久非 null，之后每一次点击都会被这里吞掉。
  if (activePointerId.value !== null) {
    console.warn('[CastReceiver] 上一个手势未正常收尾，强制复位')
    _resetPointerGesture()
  }
  if (e.pointerType === 'mouse' && e.button !== 0) return

  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (!percent) return

  // 用户手势内解锁 AudioContext（系统音频自动播放兼容）
  emit('unlock-audio')

  activePointerId.value = e.pointerId
  gestureStart.value = { ...percent, clientX: e.clientX, clientY: e.clientY }
  gestureLast.value = percent
  gestureLastSent.value = percent
  gestureStartedAt.value = performance.now()
  gestureDistance.value = 0
  longPressFired = false
  lastMoveSentAt = 0

  // 下发按下：归一化坐标 nx/ny（0~1）
  emit('control', { type: 'remote_touch', action: 'down', nx: percent.x, ny: percent.y })

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
  if (!pointers.has(e.pointerId)) return
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

  // 捏合缩放中：更新缩放与平移，不触发远程控制
  if (pinchActive && pointers.size >= 2) {
    _updatePinch()
    e.preventDefault()
    return
  }
  if (pinchActive) return

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
    // 节流下发 move：满足最小时间间隔 + 最小位移，避免高频事件淹没控制通道
    const now = performance.now()
    const dx = percent.x - gestureLastSent.value.x
    const dy = percent.y - gestureLastSent.value.y
    const movedEnough = Math.hypot(dx, dy) >= MOVE_MIN_DELTA
    if (movedEnough && now - lastMoveSentAt >= MOVE_THROTTLE_MS) {
      emit('control', { type: 'remote_touch', action: 'move', nx: percent.x, ny: percent.y })
      gestureLastSent.value = percent
      lastMoveSentAt = now
    }
  }
  e.preventDefault()
}

function onPointerUp(e) {
  pointers.delete(e.pointerId)

  // 捏合过程中：手指逐一抬起，全部抬起后才结束捏合（不恢复远程控制，避免误触）
  if (pinchActive) {
    if (pointers.size < 2) {
      pinchActive = false
    }
    e.preventDefault()
    return
  }

  if (activePointerId.value !== e.pointerId || !gestureStart.value) return
  _clearLongPressTimer()
  const end = _mapToPhonePercent(e.clientX, e.clientY) || gestureLast.value

  // 下发抬起；Kotlin 端在「无位移的 up」会自动补一次点击，因此 down→up 即点击
  if (end && !longPressFired) {
    emit('control', { type: 'remote_touch', action: 'up', nx: end.x, ny: end.y })
  }

  e.currentTarget.releasePointerCapture?.(e.pointerId)
  _resetPointerGesture()
  e.preventDefault()
}

function onPointerCancel(e) {
  pointers.delete(e.pointerId)
  if (pinchActive) {
    if (pointers.size < 2) pinchActive = false
    return
  }
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
  gestureLastSent.value = null
  gestureStartedAt.value = 0
  gestureDistance.value = 0
}

/** 鼠标滚轮 → 滚动指令 */
function onWheel(e) {
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    emit('control', {
      type: 'remote_touch',
      action: 'scroll',
      nx: percent.x,
      ny: percent.y,
      scrollDeltaY: e.deltaY,
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
  document.addEventListener('fullscreenchange', _onFullscreenChange)
})

/** 监听 stream prop 变化 */
watch(
  () => props.stream,
  (stream) => {
    console.log('[CastReceiver] watch stream变化:', stream ? `有新流(id=${stream.id.substring(0, 8)})` : 'null')
    _bindStream(stream)
  },
)

/** 全屏状态变化：退出全屏时解除方向锁定 */
function _onFullscreenChange() {
  if (!document.fullscreenElement) {
    _unlockOrientation()
  }
}

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

/** 全屏切换（移动端进入全屏时尝试锁定横屏，获得更大观看区域） */
async function toggleFullscreen() {
  const el = containerRef.value || videoEl.value?.parentElement || videoEl.value
  if (!el) return
  try {
    if (document.fullscreenElement) {
      await document.exitFullscreen()
      _unlockOrientation()
    } else {
      await el.requestFullscreen()
      if (ui.isMobile) {
        try {
          await screen.orientation?.lock?.('landscape')
        } catch (_) {
          // 部分浏览器/上下文不支持锁定方向，忽略
        }
      }
    }
  } catch (_) {}
}

/** 解除方向锁定 */
function _unlockOrientation() {
  try {
    screen.orientation?.unlock?.()
  } catch (_) {}
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
  document.removeEventListener('fullscreenchange', _onFullscreenChange)
  _unlockOrientation()
})
</script>
