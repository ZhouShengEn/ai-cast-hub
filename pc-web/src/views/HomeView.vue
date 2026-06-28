<template>
  <div class="p-8">
    <div class="max-w-2xl mx-auto">
      <h2 class="text-2xl font-bold mb-2">🏠 AI Cast Hub</h2>
      <p class="text-gray-500 mb-6">连接你的设备，开启跨设备 AI 协作</p>

      <div class="card">
        <!-- 步骤引导 -->
        <div class="flex items-center justify-center gap-6 mb-8">
          <div class="flex items-center gap-2">
            <span class="w-8 h-8 rounded-full bg-primary-600 text-white flex items-center justify-center text-sm font-bold">1</span>
            <span class="text-sm text-gray-600">打开手机 App</span>
          </div>
          <span class="text-gray-300">→</span>
          <div class="flex items-center gap-2">
            <span class="w-8 h-8 rounded-full bg-primary-600 text-white flex items-center justify-center text-sm font-bold">2</span>
            <span class="text-sm text-gray-600">输入连接码</span>
          </div>
          <span class="text-gray-300">→</span>
          <div class="flex items-center gap-2">
            <span class="w-8 h-8 rounded-full bg-primary-600 text-white flex items-center justify-center text-sm font-bold">3</span>
            <span class="text-sm text-gray-600">确认连接</span>
          </div>
        </div>

        <!-- 连接码展示 -->
        <DevicePairCode
          :code="deviceStore.pairCode"
          :expires-at="deviceStore.pairCodeExpiresAt"
          :connected="deviceStore.isConnected"
          :connected-text="'已连接到 ' + (deviceStore.pairedDevices[0]?.name || '设备')"
          @refresh="refreshPairCode"
        />

        <!-- 已绑定设备列表 -->
        <div class="mt-8 pt-6 border-t border-gray-100">
          <h3 class="text-lg font-semibold mb-3">已绑定设备</h3>

          <!-- 空列表 -->
          <div
            v-if="deviceStore.pairedDevices.length === 0 && !deviceStore.loading"
            class="text-center py-6 text-gray-400 text-sm"
          >
            <span class="text-3xl block mb-2">📱</span>
            暂无已绑定设备，请在 App 中输入连接码
          </div>

          <!-- 加载中 -->
          <div v-else-if="deviceStore.loading" class="flex justify-center py-6">
            <Spinner />
          </div>

          <!-- 设备列表 -->
          <ul v-else class="space-y-2">
            <li
              v-for="device in deviceStore.pairedDevices"
              :key="device.uuid || device.id"
              class="flex items-center gap-3 p-3 rounded-lg bg-surface-50 hover:bg-surface-100 transition-colors"
            >
              <span class="text-2xl">{{ device.platform === 'ios' ? '🍎' : '📱' }}</span>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-gray-800 truncate">{{ device.name || '未知设备' }}</p>
                <p class="text-xs" :class="device.isOnline ? 'text-green-500' : 'text-gray-400'">
                  {{ device.platform || 'android' }} · {{ device.isOnline ? '在线' : '离线 — ' + formatTime(device.lastSeen) }}
                </p>
              </div>
              <span
                class="w-2 h-2 rounded-full shrink-0"
                :class="device.isOnline ? 'bg-green-400' : 'bg-gray-300'"
                :title="device.isOnline ? '在线' : '离线'"
              ></span>
              <!-- 离线时：尝试连接按钮 -->
              <button
                v-if="!device.isOnline"
                @click.stop="tryConnect(device)"
                class="ml-2 px-2 py-1 text-xs text-blue-500 hover:text-blue-600 hover:bg-blue-50 rounded transition-colors"
                title="尝试连接 App"
              >
                尝试连接
              </button>
              <!-- 断开连接按钮 -->
              <button
                @click.stop="confirmUnbind(device)"
                class="ml-2 px-2 py-1 text-xs text-red-500 hover:text-red-600 hover:bg-red-50 rounded transition-colors"
                title="解除绑定"
              >
                解除绑定
              </button>
            </li>
          </ul>
        </div>
      </div>

      <!-- 错误提示 -->
      <div v-if="deviceStore.error" class="mt-4 p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">
        ⚠️ {{ deviceStore.error }}
      </div>
    </div>
  </div>
</template>

<script setup>
import { onMounted, onUnmounted, inject, ref } from 'vue'
import { useDeviceStore } from '../stores/device'
import { useMessageTransfer } from '../composables/useMessageTransfer'
import DevicePairCode from '../components/cast/DevicePairCode.vue'
import Spinner from '../components/common/Spinner.vue'

const deviceStore = useDeviceStore()
const { createRoom } = useMessageTransfer()
const showToast = inject('showToast', () => {})
let refreshTimer = null

/** 刷新连接码 */
async function refreshPairCode() {
  await deviceStore.generatePairCode()
  showToast('连接码已刷新', 'info')
}

/** 进入页面时：如果连接码不存在或已过期则生成，否则保持不变 */
onMounted(async () => {
  if (!deviceStore.pairCode || (deviceStore.pairCodeExpiresAt && Date.now() > deviceStore.pairCodeExpiresAt)) {
    await deviceStore.generatePairCode()
  }
  // 每 60 秒刷新一次设备在线状态
  refreshTimer = setInterval(() => {
    deviceStore.fetchDeviceList()
  }, 60000)
})

onUnmounted(() => {
  if (refreshTimer) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
})

/** 格式化时间 */
function formatTime(dateStr) {
  if (!dateStr) return '未知'
  const diff = Date.now() - new Date(dateStr).getTime()
  const minutes = Math.floor(diff / 60000)
  if (minutes < 1) return '刚刚'
  if (minutes < 60) return `${minutes}分钟前`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}小时前`
  return new Date(dateStr).toLocaleDateString('zh-CN')
}

/** 确认解除绑定 */
async function confirmUnbind(device) {
  const targetUuid = device.uuid || device.id || device.deviceUuid
  if (!targetUuid) return
  if (!confirm(`确定要解除与「${device.name || '未知设备'}」的绑定吗？\n\n解除后需要重新扫码绑定才能恢复连接。`)) return
  try {
    await deviceStore.unbindDevice(targetUuid)
    showToast('已解除绑定', 'success')
  } catch (err) {
    showToast('解除绑定失败: ' + err.message, 'error')
  }
}

/** 尝试连接离线设备 */
async function tryConnect(device) {
  const targetUuid = device.uuid || device.id || device.deviceUuid
  if (!targetUuid) return

  showToast('正在尝试连接...', 'info')

  try {
    // 尝试通过 WebSocket 创建房间唤醒对方
    const roomId = await createRoom(targetUuid, 'ping')
    if (roomId) {
      showToast('连接请求已发送，请等待 App 响应', 'success')
      // 2秒后刷新设备列表查看是否在线
      setTimeout(() => {
        deviceStore.fetchDeviceList()
      }, 2000)
    }
  } catch (err) {
    showToast('连接失败: ' + (err.message || '网络错误'), 'error')
  }
}
</script>
