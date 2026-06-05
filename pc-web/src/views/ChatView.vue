<template>
  <div class="h-full flex flex-col">
    <!-- 页面标题 -->
    <div class="px-6 py-3 bg-white border-b border-gray-100">
      <h2 class="text-lg font-semibold text-gray-800">💬 AI 对话</h2>
    </div>

    <!-- 对话面板（填充剩余空间） -->
    <div class="flex-1 min-h-0">
      <ChatPanel />
    </div>
  </div>
</template>

<script setup>
import ChatPanel from '../components/chat/ChatPanel.vue'
</script>
