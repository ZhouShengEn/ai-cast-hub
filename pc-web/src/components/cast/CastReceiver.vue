<template>
  <div class="relative w-full aspect-video bg-black rounded-lg overflow-hidden">
    <!-- 视频区域 -->
    <video
      ref="videoEl"
      class="w-full h-full object-contain"
      autoplay
      playsinline
      muted
    ></video>

    <!-- 加载状态 -->
    <div
      v-if="connectionState !== 'connected'"
      class="absolute inset-0 flex flex-col items-center justify-center bg-black/60 text-white"
    >
      <Spinner size="lg" color="white" />
      <p class="mt-4 text-sm">
        {{ stateMessage }}
      </p>
    </div>

    <!-- 顶部连接状态 -->
    <div class="absolute top-3 left-3">
      <ConnectionBadge :state="connectionState" />
    </div>

    <!-- 全屏按钮 -->
    <button
      v-if="connectionState === 'connected'"
      class="absolute bottom-3 right-3 w-9 h-9 rounded-lg bg-white/20 hover:bg-white/30 text-white flex items-center justify-center transition-colors"
      @click="toggleFullscreen"
      title="全屏"
    >
      ⛶
    </button>
  </div>
</template>

<script setup>
import { ref, computed, watch, onUnmounted } from 'vue'
import Spinner from '../common/Spinner.vue'
import ConnectionBadge from './ConnectionBadge.vue'

const props = defineProps({
  /** 连接状态 */
  connectionState: { type: String, default: 'disconnected' },
  /** 远程视频流 */
  stream: { type: Object, default: null },
})

/** 暴露 video ref 供 composable 绑定 */
const videoEl = ref(null)
defineExpose({ videoEl })

const stateMessage = computed(() => {
  const map = {
    connecting: '正在连接手机...',
    disconnected: '等待手机连接...',
    error: '连接失败，请重试',
    reconnecting: '正在重新连接...',
  }
  return map[props.connectionState] || '等待手机连接...'
})

/** 绑定/解绑 MediaStream */
watch(
  () => props.stream,
  (stream) => {
    if (videoEl.value) {
      videoEl.value.srcObject = stream || null
    }
  }
)

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

onUnmounted(() => {
  if (videoEl.value) {
    videoEl.value.srcObject = null
  }
})
</script>
