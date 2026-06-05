<template>
  <div class="flex items-center justify-center" :class="wrapperClass">
    <div
      class="border-2 rounded-full animate-spin border-t-transparent"
      :class="[sizeClass, colorClass]"
      role="status"
      aria-label="加载中"
    ></div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  size: { type: String, default: 'md', validator: (v) => ['sm', 'md', 'lg'].includes(v) },
  color: { type: String, default: 'primary' },
})

const wrapperClass = computed(() => {
  const map = { sm: 'w-4 h-4', md: 'w-6 h-6', lg: 'w-8 h-8' }
  return map[props.size] || map.md
})

const sizeClass = computed(() => {
  const map = { sm: 'w-4 h-4', md: 'w-6 h-6', lg: 'w-8 h-8' }
  return map[props.size] || map.md
})

const colorClass = computed(() => {
  const map = {
    primary: 'border-primary-600',
    white: 'border-white',
    gray: 'border-gray-400',
  }
  return map[props.color] || map.primary
})
</script>
