<template>
  <div class="bg-white rounded-xl border border-surface-200 p-4 shadow-sm">
    <div class="flex items-center justify-between">
      <span class="text-sm text-gray-500">{{ title }}</span>
      <span class="text-xl" :class="iconCls">{{ icon }}</span>
    </div>
    <div class="mt-2 text-3xl font-bold" :class="valueCls">{{ value }}</div>
    <div v-if="sub" class="mt-1 text-xs text-gray-400">{{ sub }}</div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  title: String,
  value: [String, Number],
  sub: String,
  icon: { type: String, default: '📊' },
  tone: { type: String, default: 'default' }, // default | green | red | amber
})

const valueCls = computed(() => ({
  default: 'text-surface-900',
  green: 'text-green-600',
  red: 'text-red-600',
  amber: 'text-amber-600',
}[props.tone] || 'text-surface-900'))

const iconCls = computed(() => (props.tone === 'red' ? 'text-red-400' : 'text-surface-200'))
</script>
