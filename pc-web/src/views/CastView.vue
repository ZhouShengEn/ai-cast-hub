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
        <!-- 未连接 → 显示二维码 -->
        <div v-if="castStore.connectionState !== 'connected'" class="card text-center">
          <h3 class="text-lg font-semibold mb-4">扫描二维码开始投屏</h3>
          <DeviceQRCode
            :data="castStore.qrCodeData"
            :connected="false"
            description="使用 AI Cast Hub App 扫描二维码开始投屏"
            :show-refresh="true"
          />
          <p class="mt-4 text-xs text-gray-400">
            设备 UUID: {{ deviceUuid }}
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
import DeviceQRCode from '../components/cast/DeviceQRCode.vue'
import CastReceiver from '../components/cast/CastReceiver.vue'
import ConnectionBadge from '../components/cast/ConnectionBadge.vue'
import { useCastReceiver } from '../composables/useCastReceiver'

const castStore = useCastStore()
const showToast = inject('showToast', () => {})

const deviceUuid = ref(localStorage.getItem('deviceUuid') || '')
const castReceiverRef = ref(null)

const {
  startReceiving,
  stopReceiving,
  connectionState,
} = useCastReceiver()

/** 初始化：生成投屏二维码，监听 WebSocket 房间事件 */
onMounted(() => {
  castStore.generateQRCode(deviceUuid.value)

  // 注册为投屏接收端
  const roomId = `cast_${deviceUuid.value}_${Date.now()}`
  castStore.roomId = roomId
  // 开始接收（等待手机连接）
  startReceiving(roomId)
})

onUnmounted(() => {
  stopReceiving()
})

/** 停止投屏 */
function stopCasting() {
  stopReceiving()
  showToast('投屏已停止', 'info')
}
</script>
