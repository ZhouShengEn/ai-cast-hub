<template>
  <div class="flex items-end gap-2">
    <!-- 输入框 -->
    <textarea
      ref="inputRef"
      v-model="text"
      class="flex-1 resize-none border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent disabled:bg-gray-100 disabled:cursor-not-allowed"
      :class="inputHeight"
      :placeholder="placeholder"
      :disabled="disabled"
      :rows="rows"
      @keydown="handleKeydown"
    ></textarea>

    <!-- 发送/停止按钮 -->
    <button
      class="shrink-0 w-10 h-10 rounded-lg flex items-center justify-center transition-colors"
      :class="buttonClass"
      :disabled="!streaming && !text.trim() && !disabled"
      @click="handleClick"
      :title="streaming ? '停止生成' : '发送消息'"
    >
      <span v-if="!streaming" class="text-lg">→</span>
      <span v-else class="text-lg">■</span>
    </button>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'

const props = defineProps({
  /** 是否正在流式输出 */
  streaming: { type: Boolean, default: false },
  /** 是否禁用 */
  disabled: { type: Boolean, default: false },
  /** 占位文字 */
  placeholder: { type: String, default: '输入消息, Enter 发送, Shift+Enter 换行' },
})

const emit = defineEmits(['send', 'stop'])

const text = ref('')
const inputRef = ref(null)
const rows = ref(1)

const inputHeight = computed(() => {
  return rows.value > 1 ? 'min-h-[60px]' : 'h-10'
})

const buttonClass = computed(() => {
  if (props.streaming) {
    return 'bg-red-500 text-white hover:bg-red-600'
  }
  if (!text.value.trim() || props.disabled) {
    return 'bg-gray-300 text-gray-500 cursor-not-allowed'
  }
  return 'bg-primary-600 text-white hover:bg-primary-700'
})

/** 处理键盘事件 */
function handleKeydown(e) {
  // Shift+Enter 换行（默认行为）
  if (e.key === 'Enter' && e.shiftKey) {
    return
  }
  // Enter 发送
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault()
    sendMessage()
  }
}

/** 点击按钮 */
function handleClick() {
  if (props.streaming) {
    emit('stop')
    return
  }
  sendMessage()
}

/** 发送消息 */
function sendMessage() {
  const content = text.value.trim()
  if (!content || props.disabled) return
  emit('send', content)
  text.value = ''
  rows.value = 1
  // 聚焦输入框
  if (inputRef.value) {
    inputRef.value.focus()
  }
}

/** 暴露聚焦方法 */
defineExpose({ focus: () => inputRef.value?.focus() })
</script>
