<template>
  <div class="h-full flex flex-col">
    <!-- 页面标题 -->
    <div class="px-6 py-3 bg-white border-b border-gray-100 flex items-center justify-between">
      <h2 class="text-lg font-semibold text-gray-800">📺 投屏</h2>
      <div class="flex items-center gap-3">
        <ConnectionBadge :state="castStore.connectionState" />
        <span v-if="castStore.connectionState === 'connected'" class="text-xs text-green-600">🖱️ 远程控制</span>
      </div>
    </div>

    <!-- 内容区 -->
    <div class="flex-1 p-6 overflow-auto">
      <div class="max-w-4xl mx-auto">
        <!-- CastReceiver 始终渲染（v-show 保持 DOM 存在），等待状态由组件内部覆盖层处理 -->
        <CastReceiver
          ref="castReceiverRef"
          :connection-state="castStore.connectionState"
          :stream="castStore.remoteStream"
          :remote-status="remoteStatus"
          :system-audio-supported="systemAudioSupported"
          :system-audio-active="systemAudioActive"
          :current-quality="currentQuality"
          :quality-profiles="qualityProfiles"
          @control="onControl"
          @refresh-status="refreshRemoteStatus"
          @toggle-system-audio="onToggleSystemAudio"
          @set-quality="setQuality"
        />

        <!-- 停止投屏按钮（仅连接后显示） -->
        <div v-if="castStore.connectionState === 'connected'" class="flex justify-center mt-4 gap-4">
          <button
            class="px-4 py-2 text-sm rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 transition-colors"
            @click="sendControl({ type: 'home' })"
          >
            🏠 Home
          </button>
          <button
            class="px-4 py-2 text-sm rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 transition-colors"
            @click="sendControl({ type: 'back' })"
          >
            ← Back
          </button>
          <button
            class="px-4 py-2 text-sm rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 transition-colors"
            @click="sendControl({ type: 'recent' })"
          >
            ○ 多任务
          </button>
          <button
            class="px-4 py-2 text-sm rounded-lg border border-red-300 text-red-600 hover:bg-red-50 transition-colors"
            @click="stopCasting"
          >
            ⏹ 停止接收
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, watch, inject } from 'vue'
import { useCastStore } from '../stores/cast'
import CastReceiver from '../components/cast/CastReceiver.vue'
import ConnectionBadge from '../components/cast/ConnectionBadge.vue'
import { useCastReceiver } from '../composables/useCastReceiver'

const castStore = useCastStore()
const showToast = inject('showToast', () => {})
const castReceiverRef = ref(null)

// 将 CastReceiver 的 videoEl 传入 useCastReceiver，使视频流能正确绑定
const {
  startListening,
  stopReceiving,
  setVideoRef,
  sendControl,
  remoteStatus,
  refreshRemoteStatus,
  systemAudioSupported,
  systemAudioActive,
  toggleSystemAudio,
  currentQuality,
  qualityProfiles,
  setQuality,
} = useCastReceiver(undefined, { showToast })

// 当 CastReceiver 组件渲染后，绑定 video 元素
watch(castReceiverRef, (ref) => {
  if (ref?.videoEl) {
    console.log('[CastView] videoEl已获取，绑定到useCastReceiver')
    setVideoRef(ref.videoEl)
  }
})

onMounted(() => {
  startListening()
})

onUnmounted(() => {
  stopReceiving()
})

function onControl(event) {
  sendControl(event)
}

/** 系统音频开关：控制通道未就绪时给出提示，避免「点了没反应」 */
async function onToggleSystemAudio(enabled) {
  const ok = await toggleSystemAudio(enabled)
  if (!ok) {
    showToast('控制通道未就绪，请稍候重试', 'warn')
  }
}

function stopCasting() {
  stopReceiving()
  showToast('投屏已停止', 'info')
}
</script>
