<template>
  <div class="w-full">
    <!-- 进度条轨道 -->
    <div class="w-full h-2.5 bg-gray-200 rounded-full overflow-hidden">
      <div
        class="h-full rounded-full transition-all duration-300"
        :class="barClass"
        :style="{ width: progress + '%' }"
      ></div>
    </div>

    <!-- 百分比 + 状态文字 -->
    <div class="flex items-center justify-between mt-1">
      <span class="text-xs font-medium" :class="textClass">{{ progress }}%</span>
      <span class="text-xs" :class="textClass">{{ statusLabel }}</span>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  /** 进度 0-100 */
  progress: { type: Number, default: 0 },
  /** 状态 */
  status: {
    type: String,
    default: 'pending',
    validator: (v) => ['pending', 'transferring', 'completed', 'failed'].includes(v),
  },
})

const barClass = computed(() => {
  const map = {
    pending: 'bg-gray-300',
    transferring: 'bg-blue-500',
    completed: 'bg-green-500',
    failed: 'bg-red-500',
  }
  return map[props.status] || map.pending
})

const textClass = computed(() => {
  const map = {
    pending: 'text-gray-400',
    transferring: 'text-blue-600',
    completed: 'text-green-600',
    failed: 'text-red-500',
  }
  return map[props.status] || map.pending
})

const statusLabel = computed(() => {
  const map = {
    pending: '等待中',
    transferring: '传输中',
    completed: '已完成',
    failed: '失败',
  }
  return map[props.status] || ''
})
</script>
