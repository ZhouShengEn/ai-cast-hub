<template>
  <span
    class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium"
    :class="badgeCls"
  >
    <span class="w-2 h-2 rounded-full" :class="dotCls"></span>
    <span>{{ text }}</span>
    <span v-if="portLocked" class="ml-1 px-1.5 py-0.5 rounded bg-amber-200 text-amber-800 text-[10px]" title="端口已与 Nginx 关联锁定">
      🔒锁定
    </span>
  </span>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  running: { type: Boolean, default: false },
  error: { type: Boolean, default: false },
  starting: { type: Boolean, default: false },
  portLocked: { type: Boolean, default: false },
  text: { type: String, default: '' },
})

const badgeCls = computed(() => {
  if (props.error) return 'bg-red-100 text-red-700'
  if (props.starting) return 'bg-blue-100 text-blue-700'
  return props.running ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-600'
})
const dotCls = computed(() => {
  if (props.error) return 'bg-red-500'
  if (props.starting) return 'bg-blue-500 animate-pulse'
  return props.running ? 'bg-green-500' : 'bg-gray-400'
})
</script>
