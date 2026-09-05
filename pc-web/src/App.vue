<template>
  <!--
    布局已抽到 MainLayout：PC 保持原有左栏 + 右内容；
    移动端自动切换为顶部汉堡栏 + 浮层侧边栏。
  -->
  <MainLayout>
    <router-view v-slot="{ Component }">
      <transition name="fade" mode="out-in">
        <component :is="Component" />
      </transition>
    </router-view>
  </MainLayout>

  <!-- 全局 Toast 通知（移动端下移，避让顶部汉堡栏） -->
  <TransitionGroup
    tag="div"
    name="toast"
    class="fixed right-4 top-4 z-[60] flex flex-col gap-2 md:top-4"
    :class="uiStore.isMobile ? 'top-16' : ''"
  >
    <div
      v-for="toast in toasts"
      :key="toast.id"
      class="px-4 py-3 rounded-lg shadow-lg text-sm max-w-[calc(100vw-2rem)] sm:max-w-sm"
      :class="toastClass(toast.type)"
    >
      {{ toast.message }}
    </div>
  </TransitionGroup>
</template>

<script setup>
import { ref, provide, onMounted, onUnmounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useWebSocket } from './composables/useWebSocket'
import { useDeviceStore } from './stores/device'
import { useMessageStore } from './stores/message'
import { useMessageTransfer } from './composables/useMessageTransfer'
import { useUiStore } from './stores/ui'
import MainLayout from './layout/MainLayout.vue'

const route = useRoute()
const deviceStore = useDeviceStore()
const messageStore = useMessageStore()
const uiStore = useUiStore()
const { connect: wsConnect, disconnect: wsDisconnect, onMessage, offMessage } = useWebSocket()
const { startListening: startMessageListening, disconnect: disconnectMessageChannel } = useMessageTransfer()

/**
 * 设备连接状态。
 * 通过 provide 注入给 MainLayout 渲染侧边栏底部状态点，保持原有逻辑不变。
 */
const deviceConnected = ref(false)

// 监听路由变化，更新消息页面查看状态
watch(() => route.path, (newPath) => {
  messageStore.setViewing(newPath === '/message')
}, { immediate: false })

// ============================================================
// 全局 WebSocket 连接管理（应用级，不随页面切换断开）
// ============================================================

/** 收到设备绑定通知 */
async function onDeviceBound(msg) {
  console.log('[App] 收到设备绑定通知:', msg)
  const deviceName = msg?.payload?.device?.deviceName || '新设备'
  showToast(`设备「${deviceName}」已连接`, 'success')
  deviceConnected.value = true
  try {
    await deviceStore.fetchDeviceList()
  } catch (_) {}
}

/** 收到设备解绑通知 */
async function onDeviceUnbound(msg) {
  console.log('[App] 收到设备解绑通知:', msg)
  const auto = msg?.payload?.reason === 'auto'
  showToast(auto ? '对方设备离线超过10分钟，已自动解除绑定' : '设备绑定已解除', 'warning')
  try {
    await deviceStore.fetchDeviceList()
    deviceConnected.value = deviceStore.pairedDevices.length > 0
  } catch (_) {}
}

/** 收到设备上下线状态通知 */
function onDeviceStatus(msg) {
  const payload = msg?.payload || {}
  const uuid = payload.deviceUuid
  const online = payload.status === 'online'
  if (!uuid) return
  console.log('[App] 收到设备状态变更:', uuid, payload.status)
  deviceStore.setDeviceOnline(uuid, online)
  const name = deviceStore.pairedDevices.find(
    (d) => (d.uuid || d.id || d.deviceUuid) === uuid,
  )?.name || '设备'
  if (online) {
    showToast(`「${name}」已上线`, 'success')
  } else {
    showToast(`「${name}」已离线`, 'warning')
  }
}

onMounted(async () => {
  // 确保有 UUID
  if (!localStorage.getItem('deviceUuid')) {
    localStorage.setItem('deviceUuid', crypto.randomUUID())
  }

  // 确保设备已注册
  try {
    await deviceStore.fetchDeviceInfo()
  } catch (err) {
    console.log('[App] 获取设备信息失败，尝试注册:', err.message)
    try {
      const name = `PC-${navigator.platform || 'Web'}`
      await deviceStore.registerDevice(name)
    } catch (_) {}
  }

  // 检查是否有已绑定设备
  try {
    await deviceStore.fetchDeviceList()
    deviceConnected.value = deviceStore.pairedDevices.length > 0
  } catch (_) {}

  // 全局生成连接码（仅一次，切 Tab 不重新生成）
  await deviceStore.generatePairCode()

  // 注册 WS 监听并建立连接（全局唯一）
  onMessage('device_bound', onDeviceBound)
  onMessage('device_unbound', onDeviceUnbound)
  onMessage('device_status', onDeviceStatus)
  wsConnect()

  // 全局启动消息通道监听（无论是否在消息页面都能收到消息）
  startMessageListening()

  // 注册视口监听：窗口尺寸变化时自动切换 PC / 移动端布局模式
  uiStore.bindViewportListener()
})

onUnmounted(() => {
  offMessage('device_bound', onDeviceBound)
  offMessage('device_unbound', onDeviceUnbound)
  offMessage('device_status', onDeviceStatus)
  disconnectMessageChannel()
  wsDisconnect()
  uiStore.unbindViewportListener()
})

// ============================================================
// 全局 Toast 通知系统
// ============================================================

/** Toast 消息列表 */
const toasts = ref([])
let toastIdCounter = 0

/** 显示 Toast 通知 */
function showToast(message, type = 'info', duration = 3000) {
  const id = ++toastIdCounter
  toasts.value.push({ id, message, type })
  setTimeout(() => {
    toasts.value = toasts.value.filter((t) => t.id !== id)
  }, duration)
}

/** Toast 样式映射 */
function toastClass(type) {
  const map = {
    success: 'bg-green-500 text-white',
    error: 'bg-red-500 text-white',
    warning: 'bg-yellow-500 text-white',
    info: 'bg-primary-600 text-white',
  }
  return map[type] || map.info
}

// 通过 provide 将 showToast 和 deviceConnected 提供给子组件
provide('showToast', showToast)
provide('deviceConnected', deviceConnected)
</script>

<style scoped>
/* 路由过渡动画 */
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

/* Toast 过渡动画 */
.toast-enter-active {
  transition: all 0.3s ease-out;
}
.toast-leave-active {
  transition: all 0.2s ease-in;
}
.toast-enter-from {
  opacity: 0;
  transform: translateX(30px);
}
.toast-leave-to {
  opacity: 0;
  transform: translateX(30px);
}
</style>
