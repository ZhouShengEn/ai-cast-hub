<template>
  <div
    class="flex mb-4"
    :class="role === 'user' ? 'justify-end' : 'justify-start'"
  >
    <!-- AI 头像 -->
    <div v-if="role === 'assistant'" class="w-8 h-8 mr-2 shrink-0">
      <div class="w-8 h-8 rounded-full bg-primary-100 flex items-center justify-center text-sm">
        🤖
      </div>
    </div>

    <!-- 消息气泡 -->
    <div class="max-w-[75%]">
      <div
        class="px-4 py-2.5 rounded-2xl text-sm leading-relaxed"
        :class="bubbleClass"
      >
        <!-- Markdown 渲染区域 -->
        <div v-if="role === 'assistant'" v-html="renderedContent" class="break-words"></div>
        <div v-else class="break-words whitespace-pre-wrap">{{ content }}</div>

        <!-- 流式光标 -->
        <span
          v-if="streaming"
          class="inline-block w-2 h-4 bg-current ml-0.5 align-middle stream-cursor"
        ></span>
      </div>

      <!-- 消息时间 -->
      <p class="text-xs text-gray-400 mt-1" :class="role === 'user' ? 'text-right' : 'text-left'">
        {{ formatTime(createdAt) }}
      </p>
    </div>

    <!-- User 头像 -->
    <div v-if="role === 'user'" class="w-8 h-8 ml-2 shrink-0">
      <div class="w-8 h-8 rounded-full bg-primary-600 flex items-center justify-center text-sm text-white">
        👤
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  /** 消息角色 */
  role: { type: String, default: 'user', validator: (v) => ['user', 'assistant', 'system'].includes(v) },
  /** 消息内容 */
  content: { type: String, default: '' },
  /** 消息时间 */
  createdAt: { type: String, default: '' },
  /** 是否正在流式输出 */
  streaming: { type: Boolean, default: false },
})

/** 气泡样式 */
const bubbleClass = computed(() => {
  if (props.role === 'user') {
    return 'bg-primary-600 text-white rounded-br-md'
  }
  return 'bg-surface-100 text-gray-800 rounded-bl-md'
})

/**
 * 简单 Markdown 渲染
 *
 * 支持：代码块 (```lang ... ```)、行内代码 (`...`)、
 * 加粗 (**text**)、斜体 (*text*)、无序列表
 */
const renderedContent = computed(() => {
  if (!props.content && props.streaming) return ''
  let html = props.content || ''

  // 转义 HTML
  html = html.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

  // 代码块 (```...```)
  html = html.replace(/```(\w*)\n([\s\S]*?)```/g, (_match, lang, code) => {
    return `<pre class="bg-gray-800 text-gray-100 rounded-lg p-3 my-2 overflow-x-auto text-xs"><code>${code.trim()}</code></pre>`
  })

  // 行内代码 (`...`)
  html = html.replace(/`([^`]+)`/g, '<code class="bg-gray-200 text-pink-600 px-1 py-0.5 rounded text-xs">$1</code>')

  // 加粗 **text**
  html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')

  // 斜体 *text*
  html = html.replace(/\*(.+?)\*/g, '<em>$1</em>')

  // 换行
  html = html.replace(/\n/g, '<br>')

  return html
})

/** 格式化时间 HH:mm */
function formatTime(dateStr) {
  if (!dateStr) return ''
  const d = new Date(dateStr)
  return d.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })
}
</script>

<style scoped>
.stream-cursor {
  animation: blink 0.8s infinite;
}

@keyframes blink {
  0%, 50% { opacity: 1; }
  51%, 100% { opacity: 0; }
}
</style>
