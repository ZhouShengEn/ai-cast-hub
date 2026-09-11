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
                <p class="text-xs" :class="statusClass(device)">
                  {{ device.platform || 'android' }} · {{ statusText(device) }}
                </p>
              </div>
              <span
                class="w-2 h-2 rounded-full shrink-0"
                :class="statusDotClass(device)"
                :title="statusText(device)"
              ></span>
              <!-- 离线时：尝试连接按钮 -->
              <button
                v-if="!isDeviceOnline(device)"
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

        <!-- 设备防盗与定位 -->
        <AntiTheftPanel />
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
import AntiTheftPanel from '../components/cast/AntiTheftPanel.vue'
import Spinner from '../components/common/Spinner.vue'

const deviceStore = useDeviceStore()
const { createRoom } = useMessageTransfer()
const showToast = inject('showToast', () => {})
let refreshTimer = null

/**
 * 时间刻度：每 20 秒自增一次，用于驱动 isDeviceOnline 的「lastSeen 超时」判定重算。
 * 不依赖它的话，仅靠 60 秒一次的服务端轮询，离线感知仍会滞后近一分钟。
 */
const nowTick = ref(Date.now())
let tickTimer = null

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
  // 每 20 秒推进一次时间刻度，让离线判定及时生效
  tickTimer = setInterval(() => {
    nowTick.value = Date.now()
  }, 20000)
})

onUnmounted(() => {
  if (tickTimer) {
    clearInterval(tickTimer)
    tickTimer = null
  }
  if (refreshTimer) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
})

/** 格式化时间 */
/**
 * 设备是否在线（前端兜底判定）。
 *
 * 服务端的 isOnline 基于 last_seen_at 有 5 分钟宽限，且 device_status 广播
 * 依赖 PC 端 WS 在线——两者都可能滞后，导致「App 明明已经关了，首页还显示在线」。
 * 这里再加一层：只要 lastSeen 超过心跳周期的合理上限（90 秒）没刷新，
 * 即使服务端仍报 isOnline=true，也按离线显示。
 * 心跳为 30 秒，在线时 lastSeen 不会超过 ~60 秒，故 90 秒阈值不会误判。
 */
const OFFLINE_STALE_MS = 90 * 1000

function isDeviceOnline(device) {
  void nowTick.value // 依赖时间刻度，保证超时后能自动重算并重渲染
  if (!device) return false
  if (!device.isOnline) return false
  const last = device.lastSeen || device.lastSeenAt
  if (!last) return true
  const t = new Date(last).getTime()
  if (!t || Number.isNaN(t)) return true
  return Date.now() - t <= OFFLINE_STALE_MS
}

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

/**
 * 设备状态三态：在线 / 待重连 / 离线（P1-4）
 *
 * 「待重连」= 设备当前离线，但后端仍保留绑定关系与传输密钥，
 * 一旦设备重新上线会自动恢复，用户无需重新扫码配对。
 */
function isPendingReconnect(device) {
  const uuid = device?.uuid || device?.id || device?.deviceUuid
  return !isDeviceOnline(device) && !!deviceStore.pendingReconnect[uuid]
}

function statusText(device) {
  if (isDeviceOnline(device)) return '在线'
  if (isPendingReconnect(device)) return `待重连 — ${formatTime(device.lastSeen)}上线过`
  return `离线 — ${formatTime(device.lastSeen)}`
}

function statusClass(device) {
  if (isDeviceOnline(device)) return 'text-green-500'
  return isPendingReconnect(device) ? 'text-amber-500' : 'text-orange-500'
}

function statusDotClass(device) {
  if (isDeviceOnline(device)) return 'bg-green-400'
  return isPendingReconnect(device) ? 'bg-amber-400 animate-pulse' : 'bg-gray-300'
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
    // 尝试通过 WebSocket 创建房间唤醒对方（createRoom 仅需目标 UUID，第二参数无效）
    const roomId = await createRoom(targetUuid)
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
