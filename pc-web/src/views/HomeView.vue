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
            <span class="text-sm text-gray-600">扫描二维码</span>
          </div>
          <span class="text-gray-300">→</span>
          <div class="flex items-center gap-2">
            <span class="w-8 h-8 rounded-full bg-primary-600 text-white flex items-center justify-center text-sm font-bold">3</span>
            <span class="text-sm text-gray-600">确认连接</span>
          </div>
        </div>

        <!-- 设备二维码 -->
        <DeviceQRCode
          :data="deviceStore.qrCodeData"
          :connected="deviceStore.isConnected"
          :connected-text="'已连接到 ' + (deviceStore.pairedDevices[0]?.name || '设备')"
          description="使用 AI Cast Hub App 扫描二维码完成设备绑定"
          :show-refresh="true"
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
            暂无已绑定设备，请扫描二维码绑定
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
                <p class="text-xs text-gray-400">
                  {{ device.platform || 'android' }} · 最后在线: {{ formatTime(device.lastSeen) }}
                </p>
              </div>
              <span class="w-2 h-2 rounded-full bg-green-400" title="在线"></span>
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
import { onMounted, inject } from 'vue'
import { useDeviceStore } from '../stores/device'
import DeviceQRCode from '../components/cast/DeviceQRCode.vue'
import Spinner from '../components/common/Spinner.vue'

const deviceStore = useDeviceStore()
const showToast = inject('showToast', () => {})

/** 初始化设备信息 */
onMounted(async () => {
  try {
    // 确保先有 UUID（如果不存在则先生成）
    if (!localStorage.getItem('deviceUuid')) {
      localStorage.setItem('deviceUuid', crypto.randomUUID())
    }
    
    // 检查是否已注册（尝试获取设备信息）
    const uuid = localStorage.getItem('deviceUuid')
    if (uuid) {
      try {
        await deviceStore.fetchDeviceInfo()
      } catch (err) {
        // 获取失败可能是未注册，尝试重新注册
        console.log('[HomeView] 获取设备信息失败，尝试注册:', err.message)
        const name = `PC-${navigator.platform || 'Web'}`
        await deviceStore.registerDevice(name)
        showToast('设备已注册', 'success')
      }
    } else {
      // 首次注册
      const name = `PC-${navigator.platform || 'Web'}`
      await deviceStore.registerDevice(name)
      showToast('设备已注册', 'success')
    }
    
    // 生成二维码（确保一定执行）
    deviceStore.generateQRCode()
    
    // 验证二维码数据是否生成成功
    if (!deviceStore.qrCodeData) {
      console.error('[HomeView] 二维码数据为空')
      throw new Error('二维码生成失败')
    }
  } catch (err) {
    console.error('[HomeView] 初始化失败:', err)
    // 最后的兜底：强制生成二维码
    if (!localStorage.getItem('deviceUuid')) {
      localStorage.setItem('deviceUuid', crypto.randomUUID())
    }
    deviceStore.generateQRCode()
    
    if (!deviceStore.qrCodeData) {
      showToast('设备初始化失败: ' + err.message, 'error')
    }
  }
  
  // 定期刷新设备列表和二维码
  setInterval(async () => {
    try {
      await deviceStore.fetchDeviceList()
      deviceStore.generateQRCode()
    } catch (_) {}
  }, 30000) // 每 30 秒刷新一次
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
</script>
