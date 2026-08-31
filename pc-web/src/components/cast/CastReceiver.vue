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
      class="absolute inset-0 cursor-pointer z-10"
      @mousedown="onMouseDown"
      @mousemove="onMouseMove"
      @mouseup="onMouseUp"
      @mouseleave="onMouseUp"
      @click="onClick"
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

    <!-- 取消静音按钮（浏览器自动播放策略需要用户交互才能播放声音） -->
    <button
      v-if="connectionState === 'connected' && isMuted && hasAudioTrack"
      class="absolute bottom-3 left-3 px-3 h-9 rounded-lg bg-blue-500/80 hover:bg-blue-500 text-white text-sm flex items-center gap-1 transition-colors z-20 animate-pulse"
      @click.stop="unmute"
      title="开启声音"
    >
      🔇 点击开启声音
    </button>
    <button
      v-else-if="connectionState === 'connected' && !isMuted && hasAudioTrack"
      class="absolute bottom-3 left-3 w-9 h-9 rounded-lg bg-white/20 hover:bg-white/30 text-white flex items-center justify-center transition-colors z-20"
      @click.stop="mute"
      title="静音"
    >
      🔊
    </button>

    <!-- 操作提示 -->
    <div
      v-if="connectionState === 'connected'"
      class="absolute top-3 right-3 text-xs text-white/50 z-20 text-right"
    >
      🖱️ 远程控制已开启<br/>
      ⌨️ Home/Bksp/Tab 快捷操作
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
})

const emit = defineEmits(['control'])

/** 暴露 video ref 供 composable 绑定 */
const videoEl = ref(null)
const containerRef = ref(null)
defineExpose({ videoEl })

/** 静音状态（默认静音以满足浏览器自动播放策略，用户可手动取消） */
const isMuted = ref(true)

/** 远程控制状态 */
const isDragging = ref(false)
const dragStart = ref({ x: 0, y: 0 })

/** 获取视频显示区域的实际尺寸（去除黑边） */
function _getVideoRect() {
  if (!videoEl.value || !containerRef.value) return null
  const containerRect = containerRef.value.getBoundingClientRect()
  const video = videoEl.value
  const videoWidth = video.videoWidth || 1920
  const videoHeight = video.videoHeight || 1080
  const aspectRatio = videoWidth / videoHeight
  const containerAspectRatio = containerRect.width / containerRect.height

  let renderWidth, renderHeight, offsetX, offsetY

  if (aspectRatio > containerAspectRatio) {
    renderWidth = containerRect.width
    renderHeight = containerRect.width / aspectRatio
    offsetX = 0
    offsetY = (containerRect.height - renderHeight) / 2
  } else {
    renderHeight = containerRect.height
    renderWidth = containerRect.height * aspectRatio
    offsetX = (containerRect.width - renderWidth) / 2
    offsetY = 0
  }

  return {
    width: renderWidth,
    height: renderHeight,
    offsetX,
    offsetY,
    videoWidth,
    videoHeight,
  }
}

/** 将鼠标坐标转换为手机屏幕百分比 */
function _mapToPhonePercent(clientX, clientY) {
  const videoRect = _getVideoRect()
  if (!videoRect) return null

  const containerRect = containerRef.value.getBoundingClientRect()
  const x = clientX - containerRect.left - videoRect.offsetX
  const y = clientY - containerRect.top - videoRect.offsetY

  if (x < 0 || x > videoRect.width || y < 0 || y > videoRect.height) {
    return null
  }

  return {
    x: Math.round((x / videoRect.width) * 100) / 100,
    y: Math.round((y / videoRect.height) * 100) / 100,
  }
}

/** 鼠标按下 */
function onMouseDown(e) {
  if (e.button !== 0) return
  isDragging.value = true
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    dragStart.value = percent
    emit('control', {
      type: 'touch_start',
      x: percent.x,
      y: percent.y,
    })
  }
}

/** 鼠标移动 */
function onMouseMove(e) {
  if (!isDragging.value) return
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    emit('control', {
      type: 'touch_move',
      x: percent.x,
      y: percent.y,
      startX: dragStart.value.x,
      startY: dragStart.value.y,
    })
  }
}

/** 鼠标松开 */
function onMouseUp(e) {
  if (!isDragging.value) return
  isDragging.value = false
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    emit('control', {
      type: 'touch_end',
      x: percent.x,
      y: percent.y,
    })
  }
}

/** 鼠标点击 */
function onClick(e) {
  if (isDragging.value) return
  const percent = _mapToPhonePercent(e.clientX, e.clientY)
  if (percent) {
    emit('control', {
      type: 'tap',
      x: percent.x,
      y: percent.y,
    })
  }
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

/** 取消静音 */
function unmute() {
  isMuted.value = false
  if (videoEl.value) {
    videoEl.value.muted = false
    videoEl.value.play().catch(() => {})
  }
}

/** 静音 */
function mute() {
  isMuted.value = true
  if (videoEl.value) {
    videoEl.value.muted = true
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
  if (videoEl.value) {
    videoEl.value.srcObject = null
  }
  window.removeEventListener('keydown', _handleKeyDown)
})
</script>
