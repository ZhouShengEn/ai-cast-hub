<template>
  <div class="flex h-screen overflow-hidden">
    <!-- 左侧导航栏 -->
    <aside class="w-64 bg-surface-800 text-white flex flex-col shrink-0">
      <!-- Logo 区域 -->
      <div class="p-6 border-b border-white/10">
        <h1 class="text-xl font-bold tracking-wide">
          <span class="text-primary-500">AI</span> Cast Hub
        </h1>
        <p class="text-xs text-gray-400 mt-1">跨设备 AI 协作平台</p>
      </div>

      <!-- 导航菜单 -->
      <nav class="flex-1 py-4">
        <ul class="space-y-1 px-3">
          <li v-for="item in navItems" :key="item.path">
            <router-link
              :to="item.path"
              class="flex items-center gap-3 px-4 py-3 rounded-lg text-sm font-medium transition-colors"
              :class="isActive(item.path)
                ? 'bg-primary-600 text-white'
                : 'text-gray-300 hover:bg-white/10 hover:text-white'"
            >
              <span class="text-lg">{{ item.icon }}</span>
              <span>{{ item.label }}</span>
            </router-link>
          </li>
        </ul>
      </nav>

      <!-- 底部状态 -->
      <div class="p-4 border-t border-white/10">
        <div class="flex items-center gap-2 text-xs text-gray-400">
          <span class="w-2 h-2 rounded-full" :class="deviceStatusClass"></span>
          <span>{{ deviceStatusText }}</span>
        </div>
      </div>
    </aside>

    <!-- 右侧内容区 -->
    <main class="flex-1 overflow-auto bg-surface-50">
      <router-view v-slot="{ Component }">
        <transition name="fade" mode="out-in">
          <component :is="Component" />
        </transition>
      </router-view>
    </main>

    <!-- 全局 Toast 通知 -->
    <TransitionGroup
      tag="div"
      name="toast"
      class="fixed top-4 right-4 z-50 flex flex-col gap-2"
    >
      <div
        v-for="toast in toasts"
        :key="toast.id"
        class="px-4 py-3 rounded-lg shadow-lg text-sm max-w-sm"
        :class="toastClass(toast.type)"
      >
        {{ toast.message }}
      </div>
    </TransitionGroup>
  </div>
</template>

<script setup>
import { ref, computed, provide, onMounted, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import { useWebSocket } from './composables/useWebSocket'
import { useDeviceStore } from './stores/device'

const route = useRoute()
const deviceStore = useDeviceStore()
const { connect: wsConnect, disconnect: wsDisconnect, onMessage, offMessage } = useWebSocket()

/** 导航菜单项 */
const navItems = [
  { path: '/', label: '首页', icon: '🏠' },
  { path: '/chat', label: 'AI 对话', icon: '💬' },
  { path: '/cast', label: '投屏接收', icon: '📺' },
  { path: '/file', label: '文件传输', icon: '📁' },
]

/** 设备连接状态 */
const deviceConnected = ref(false)

const deviceStatusClass = computed(() =>
  deviceConnected.value ? 'bg-green-400' : 'bg-yellow-400'
)

const deviceStatusText = computed(() =>
  deviceConnected.value ? '设备已连接' : '等待设备连接'
)

/** 判断当前路由是否激活 */
function isActive(path) {
  if (path === '/') {
    return route.path === '/'
  }
  return route.path.startsWith(path)
}

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
  wsConnect()
})

onUnmounted(() => {
  offMessage('device_bound', onDeviceBound)
  wsDisconnect()
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
