<template>
  <Transition name="toast-slide">
    <div
      v-if="visible"
      class="fixed top-4 right-4 z-50 px-4 py-3 rounded-lg shadow-lg text-sm max-w-sm flex items-center gap-2"
      :class="typeClass"
    >
      <span class="text-base">{{ iconMap[type] || 'ℹ️' }}</span>
      <span>{{ message }}</span>
    </div>
  </Transition>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  message: { type: String, default: '' },
  type: { type: String, default: 'info', validator: (v) => ['success', 'error', 'info', 'warning'].includes(v) },
  visible: { type: Boolean, default: false },
  duration: { type: Number, default: 3000 },
})

const iconMap = {
  success: '✅',
  error: '❌',
  info: 'ℹ️',
  warning: '⚠️',
}

const typeClass = computed(() => {
  const map = {
    success: 'bg-green-500 text-white',
    error: 'bg-red-500 text-white',
    warning: 'bg-yellow-500 text-white',
    info: 'bg-primary-600 text-white',
  }
  return map[props.type] || map.info
})
</script>

<style scoped>
.toast-slide-enter-active {
  transition: all 0.3s ease-out;
}
.toast-slide-leave-active {
  transition: all 0.2s ease-in;
}
.toast-slide-enter-from {
  opacity: 0;
  transform: translateX(30px);
}
.toast-slide-leave-to {
  opacity: 0;
  transform: translateX(30px);
}
</style>
