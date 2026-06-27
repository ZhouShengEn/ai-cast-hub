<template>
  <div class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium" :class="badgeClass">
    <span class="w-1.5 h-1.5 rounded-full" :class="dotClass"></span>
    <span>{{ label }}</span>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  /** 连接状态 */
  state: {
    type: String,
    default: 'disconnected',
    validator: (v) => ['connecting', 'connected', 'disconnected', 'error', 'reconnecting'].includes(v),
  },
})

const config = computed(() => {
  const map = {
    connecting: { dot: 'bg-yellow-400', badge: 'bg-yellow-50 text-yellow-700', label: '连接中...' },
    connected: { dot: 'bg-green-400', badge: 'bg-green-50 text-green-700', label: '已连接' },
    disconnected: { dot: 'bg-gray-300', badge: 'bg-gray-50 text-gray-500', label: '未连接' },
    error: { dot: 'bg-red-400', badge: 'bg-red-50 text-red-700', label: '连接失败' },
    reconnecting: { dot: 'bg-orange-400', badge: 'bg-orange-50 text-orange-700', label: '重连中...' },
  }
  return map[props.state] || map.disconnected
})

const dotClass = computed(() => config.value.dot)
const badgeClass = computed(() => config.value.badge)
const label = computed(() => config.value.label)
</script>
