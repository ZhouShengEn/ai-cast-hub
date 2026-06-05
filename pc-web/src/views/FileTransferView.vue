<template>
  <div class="h-full flex flex-col">
    <!-- 页面标题 -->
    <div class="px-6 py-3 bg-white border-b border-gray-100">
      <h2 class="text-lg font-semibold text-gray-800">📁 文件传输</h2>
    </div>

    <!-- 内容区 -->
    <div class="flex-1 p-6 overflow-auto">
      <div class="max-w-3xl mx-auto h-full">
        <FileReceivePanel />
      </div>
    </div>
  </div>
</template>

<script setup>
import FileReceivePanel from '../components/file/FileReceivePanel.vue'
</script>
