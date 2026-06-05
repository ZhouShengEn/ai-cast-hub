<template>
  <div class="flex flex-col items-center">
    <!-- 已连接状态 -->
    <div v-if="connected" class="flex flex-col items-center py-8">
      <div class="w-20 h-20 rounded-full bg-green-100 flex items-center justify-center mb-4">
        <span class="text-3xl text-green-500">✓</span>
      </div>
      <p class="text-lg font-medium text-green-700">{{ connectedText }}</p>
    </div>

    <!-- 未连接：二维码 -->
    <div v-else class="flex flex-col items-center">
      <div ref="qrContainer" class="qr-wrapper p-4 bg-white rounded-xl inline-block"></div>
      <p class="mt-4 text-sm text-gray-500 text-center max-w-xs">
        {{ description }}
      </p>
      <button
        v-if="showRefresh"
        class="mt-3 text-xs text-primary-600 hover:text-primary-700 underline"
        @click="generateQR"
      >
        刷新二维码
      </button>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, watch } from 'vue'
import QRCode from 'qrcode'

const props = defineProps({
  /** 二维码数据（JSON 字符串） */
  data: { type: String, default: '' },
  /** 是否已连接 */
  connected: { type: Boolean, default: false },
  /** 已连接时显示的文字 */
  connectedText: { type: String, default: '设备已连接' },
  /** 二维码下方描述文字 */
  description: { type: String, default: '使用 AI Cast Hub App 扫描二维码开始投屏' },
  /** 是否显示刷新按钮 */
  showRefresh: { type: Boolean, default: false },
})

const qrContainer = ref(null)

/** 生成二维码到 canvas */
async function generateQR() {
  if (!qrContainer.value || !props.data) return
  try {
    // 清空容器
    qrContainer.value.innerHTML = ''
    const canvas = document.createElement('canvas')
    await QRCode.toCanvas(canvas, props.data, {
      width: 200,
      margin: 2,
      color: {
        dark: '#1e293b',
        light: '#ffffff',
      },
    })
    canvas.style.width = '200px'
    canvas.style.height = '200px'
    qrContainer.value.appendChild(canvas)
  } catch (err) {
    console.error('QR 生成失败:', err)
  }
}

onMounted(() => {
  generateQR()
})

watch(() => props.data, () => {
  generateQR()
})
</script>

<style scoped>
.qr-wrapper {
  border: 2px dashed #e2e8f0;
  border-radius: 0.75rem;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 216px;
  min-width: 216px;
}
</style>
