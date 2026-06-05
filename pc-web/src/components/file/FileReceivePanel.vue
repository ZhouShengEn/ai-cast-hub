<template>
  <div class="flex flex-col h-full">
    <!-- 标题栏 -->
    <div class="flex items-center justify-between mb-4">
      <h2 class="text-lg font-semibold text-gray-800">📥 文件接收</h2>
      <span class="text-xs text-gray-400">等待手机发送文件</span>
    </div>

    <!-- 待确认弹窗 -->
    <Teleport to="body">
      <div
        v-if="fileStore.showConfirm && fileStore.pendingTransfer"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      >
        <div class="bg-white rounded-xl shadow-2xl p-6 w-96">
          <div class="text-center mb-4">
            <span class="text-4xl">📁</span>
          </div>
          <h3 class="text-lg font-semibold text-center mb-2">接收文件确认</h3>
          <p class="text-sm text-gray-500 text-center mb-2">
            手机想发送文件
          </p>
          <p class="text-sm font-medium text-center text-gray-800 mb-1">
            「{{ fileStore.pendingTransfer.fileName }}」
          </p>
          <p class="text-xs text-center text-gray-400 mb-5">
            {{ formatSize(fileStore.pendingTransfer.fileSize) }}
          </p>
          <div class="flex gap-3">
            <button
              class="flex-1 py-2 text-sm rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 transition-colors"
              @click="fileStore.rejectTransfer()"
            >
              拒绝
            </button>
            <button
              class="flex-1 py-2 text-sm rounded-lg bg-primary-600 text-white hover:bg-primary-700 transition-colors"
              @click="handleConfirm"
            >
              接收
            </button>
          </div>
        </div>
      </div>
    </Teleport>

    <!-- 传输列表 -->
    <div class="flex-1 overflow-y-auto -mx-2 px-2">
      <!-- 空状态 -->
      <div
        v-if="fileStore.transfers.length === 0"
        class="flex flex-col items-center justify-center py-16 text-gray-400"
      >
        <span class="text-5xl mb-4">📤</span>
        <p class="text-sm">暂无传输</p>
        <p class="text-xs mt-1">等待手机发送文件</p>
      </div>

      <!-- 传输项列表 -->
      <div v-else class="space-y-2">
        <div
          v-for="transfer in fileStore.transfers"
          :key="transfer.id"
          class="card !p-4"
        >
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-2 min-w-0">
              <span class="text-lg shrink-0">📄</span>
              <span class="text-sm font-medium text-gray-700 truncate">
                {{ transfer.fileName }}
              </span>
            </div>
            <span class="text-xs text-gray-400 shrink-0 ml-2">
              {{ formatSize(transfer.fileSize) }}
            </span>
          </div>

          <!-- 进度条 -->
          <ProgressBar
            :progress="transfer.progress"
            :status="transfer.status"
          />

          <!-- 操作按钮 -->
          <div class="flex justify-end gap-2 mt-2">
            <!-- 下载按钮（完成时） -->
            <a
              v-if="transfer.status === 'completed' && transfer.blobUrl"
              :href="transfer.blobUrl"
              :download="transfer.fileName"
              class="text-xs px-3 py-1 rounded bg-green-100 text-green-700 hover:bg-green-200 transition-colors"
            >
              ⬇ 下载
            </a>
            <!-- 取消按钮（传输中） -->
            <button
              v-if="transfer.status === 'transferring'"
              class="text-xs px-3 py-1 rounded bg-gray-100 text-gray-500 hover:bg-gray-200 transition-colors"
              @click="fileStore.removeTransfer(transfer.id)"
            >
              取消
            </button>
            <!-- 删除按钮（已完成/失败） -->
            <button
              v-if="['completed', 'failed'].includes(transfer.status)"
              class="text-xs px-3 py-1 rounded bg-gray-100 text-gray-500 hover:bg-gray-200 transition-colors"
              @click="fileStore.removeTransfer(transfer.id)"
            >
              ✕ 移除
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- 底部提示 -->
    <div class="mt-4 p-4 border-2 border-dashed border-gray-200 rounded-xl text-center text-gray-400">
      <span class="text-2xl">📲</span>
      <p class="text-xs mt-1">文件由手机端发起发送</p>
    </div>
  </div>
</template>

<script setup>
import { inject } from 'vue'
import { useFileStore } from '../../stores/file'
import ProgressBar from './ProgressBar.vue'

const fileStore = useFileStore()
const showToast = inject('showToast', () => {})

/** 处理确认接收 */
function handleConfirm() {
  fileStore.confirmTransfer()
  showToast('已开始接收文件', 'info')
}

/** 格式化文件大小 */
function formatSize(bytes) {
  if (!bytes || bytes === 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB']
  let i = 0
  let size = bytes
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024
    i++
  }
  return size.toFixed(i === 0 ? 0 : 1) + ' ' + units[i]
}
</script>
