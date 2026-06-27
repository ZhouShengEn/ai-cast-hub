<template>
  <div class="h-full flex flex-col">
    <!-- 页面标题 -->
    <div class="px-6 py-3 bg-white border-b border-gray-100 flex items-center justify-between">
      <h2 class="text-lg font-semibold text-gray-800">📺 投屏</h2>
      <ConnectionBadge :state="castStore.connectionState" />
    </div>

    <!-- 内容区 -->
    <div class="flex-1 p-6 overflow-auto">
      <div class="max-w-4xl mx-auto">
        <!-- 未连接 → 等待投屏 -->
        <div v-if="castStore.connectionState !== 'connected'" class="card text-center py-12">
          <div class="text-6xl mb-4">📱→💻</div>
          <h3 class="text-lg font-semibold mb-2">等待手机投屏</h3>
          <p class="text-sm text-gray-500">
            请先在手机 App 输入首页的连接码完成设备绑定<br/>
            然后在手机端发起投屏，画面将显示在此处
          </p>
        </div>

        <!-- 已连接 → 显示投屏视频 -->
        <div v-else>
          <CastReceiver
            ref="castReceiverRef"
            :connection-state="castStore.connectionState"
            :stream="castStore.remoteStream"
          />
          <div class="flex justify-center mt-4">
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
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, inject } from 'vue'
import { useCastStore } from '../stores/cast'
import CastReceiver from '../components/cast/CastReceiver.vue'
import ConnectionBadge from '../components/cast/ConnectionBadge.vue'
import { useCastReceiver } from '../composables/useCastReceiver'

const castStore = useCastStore()
const showToast = inject('showToast', () => {})
const castReceiverRef = ref(null)

// 将 CastReceiver 的 videoEl 传入 useCastReceiver，使视频流能正确绑定
const { startListening, stopReceiving, connectionState, setVideoRef } = useCastReceiver()

onMounted(() => {
  // 等待 DOM 渲染完成后绑定 video 元素
  if (castReceiverRef.value?.videoEl) {
    setVideoRef(castReceiverRef.value.videoEl)
  }
  startListening()
})

onUnmounted(() => {
  stopReceiving()
})

function stopCasting() {
  stopReceiving()
  showToast('投屏已停止', 'info')
}
</script>
