<template>
  <header class="h-14 flex items-center justify-between px-6 bg-white border-b border-gray-200 shrink-0">
    <div class="flex items-center gap-3">
      <span class="text-xl font-bold tracking-wide">
        <span class="text-primary-600">AI</span> Cast Hub
      </span>
    </div>
    <div class="flex items-center gap-2 text-sm">
      <span class="w-2 h-2 rounded-full" :class="statusClass"></span>
      <span class="text-gray-500">{{ statusText }}</span>
    </div>
  </header>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  /** 设备连接状态 */
  connected: {
    type: Boolean,
    default: false,
  },
})

const statusClass = computed(() =>
  props.connected ? 'bg-green-400' : 'bg-gray-300'
)

const statusText = computed(() =>
  props.connected ? '设备已连接' : '未连接设备'
)
</script>
