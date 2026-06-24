<template>
  <div class="flex flex-col items-center">
    <!-- 已连接状态 -->
    <div v-if="connected" class="flex flex-col items-center py-8">
      <div class="w-20 h-20 rounded-full bg-green-100 flex items-center justify-center mb-4">
        <span class="text-3xl text-green-500">✓</span>
      </div>
      <p class="text-lg font-medium text-green-700">{{ connectedText }}</p>
    </div>

    <!-- 未连接：连接码展示 -->
    <div v-else class="flex flex-col items-center w-full">
      <div class="pair-code-card p-8 bg-white rounded-2xl shadow-sm border border-gray-100 w-full max-w-xs">
        <p class="text-center text-sm text-gray-500 mb-2">设备连接码</p>
        <p class="text-center text-xs text-gray-400 mb-6">在手机 App 中输入此码完成绑定</p>

        <!-- 连接码 -->
        <div class="flex justify-center gap-2 mb-4">
          <div
            v-for="(digit, i) in codeDigits"
            :key="i"
            class="w-12 h-14 flex items-center justify-center rounded-lg bg-primary-50 border-2 border-primary-200 text-2xl font-bold text-primary-700 font-mono"
          >
            {{ digit }}
          </div>
        </div>

        <!-- 倒计时 -->
        <div class="text-center">
          <p v-if="remainingSeconds > 0" class="text-sm" :class="remainingSeconds < 60 ? 'text-orange-500' : 'text-gray-400'">
            {{ Math.floor(remainingSeconds / 60) }}:{{ String(remainingSeconds % 60).padStart(2, '0') }} 后失效
          </p>
          <p v-else class="text-sm text-red-500">连接码已失效</p>
        </div>
      </div>

      <button
        class="mt-4 px-4 py-2 text-sm text-primary-600 hover:text-primary-700 border border-primary-300 rounded-lg hover:bg-primary-50 transition-colors"
        @click="$emit('refresh')"
      >
        刷新连接码
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from 'vue'

const props = defineProps({
  /** 连接码（6 位数字字符串） */
  code: { type: String, default: '' },
  /** 过期时间戳（毫秒） */
  expiresAt: { type: Number, default: 0 },
  /** 是否已连接 */
  connected: { type: Boolean, default: false },
  /** 已连接时显示的文字 */
  connectedText: { type: String, default: '设备已连接' },
})

defineEmits(['refresh'])

const now = ref(Date.now())
let timer = null

const codeDigits = computed(() => {
  if (!props.code) return ['-', '-', '-', '-', '-', '-']
  return props.code.padEnd(6, '-').split('').slice(0, 6)
})

const remainingSeconds = computed(() => {
  if (!props.expiresAt) return 0
  const diff = Math.floor((props.expiresAt - now.value) / 1000)
  return diff > 0 ? diff : 0
})

onMounted(() => {
  timer = setInterval(() => { now.value = Date.now() }, 1000)
})

onUnmounted(() => {
  if (timer) clearInterval(timer)
})

// 监听 code 变化重置计时
watch(() => props.code, () => { now.value = Date.now() })
</script>

<style scoped>
.pair-code-card {
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.05);
}
</style>
