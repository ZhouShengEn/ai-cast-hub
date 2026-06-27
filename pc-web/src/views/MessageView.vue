<template>
  <div class="h-full flex flex-col">
    <div class="px-6 py-3 bg-white border-b border-gray-100 flex items-center justify-between">
      <h2 class="text-lg font-semibold text-gray-800">消息</h2>
      <div class="flex items-center gap-3">
        <span v-if="store.isConnected" class="text-xs text-green-600">已连接</span>
        <span v-else-if="store.messages.length > 0" class="text-xs text-orange-500">已断开</span>
        <span v-else class="text-xs text-gray-400">等待连接</span>
        <button v-if="store.isConnected" @click="disconnectChannel" class="text-xs text-red-500 hover:text-red-600 underline">断开</button>
      </div>
    </div>

    <!-- 断开连接横幅 -->
    <div v-if="!store.isConnected && store.messages.length > 0"
      class="px-4 py-2 bg-orange-50 border-b border-orange-200 flex items-center justify-between">
      <span class="text-sm text-orange-600">连接已断开，等待 App 端重连</span>
    </div>

    <!-- 文件接收确认弹窗 -->
    <Teleport to="body">
      <div v-if="pendingFile" class="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
        <div class="bg-white rounded-xl shadow-2xl p-6 w-96">
          <div class="text-center mb-4">
            <span class="text-4xl">📁</span>
          </div>
          <h3 class="text-lg font-semibold text-center mb-2">接收文件确认</h3>
          <p class="text-sm text-gray-500 text-center mb-2">手机端发送了一个文件</p>
          <p class="text-sm font-medium text-center text-gray-800 mb-1">
            {{ pendingFile.fileName }}
          </p>
          <p class="text-xs text-center text-gray-400 mb-5">
            {{ formatSize(pendingFile.fileSize) }}
          </p>
          <div class="flex gap-3">
            <button
              class="flex-1 py-2 text-sm rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50 transition-colors"
              @click="rejectFile(pendingFile.id)">
              拒绝
            </button>
            <button
              class="flex-1 py-2 text-sm rounded-lg bg-blue-500 text-white hover:bg-blue-600 transition-colors"
              @click="confirmFile(pendingFile.id)">
              接收
            </button>
          </div>
        </div>
      </div>
    </Teleport>

    <!-- 消息列表 -->
    <div ref="msgList" class="flex-1 overflow-y-auto p-4 space-y-3">
      <div v-if="store.messages.length === 0" class="flex flex-col items-center justify-center h-full text-gray-400">
        <span class="text-4xl mb-3"></span>
        <p>暂无消息</p>
        <p class="text-xs mt-1">等待手机端发起消息连接</p>
      </div>

      <div v-for="msg in store.messages" :key="msg.id"
        :class="['flex', msg.isFromMe ? 'justify-end' : 'justify-start']">

        <!-- 对方头像 -->
        <div v-if="!msg.isFromMe" class="w-8 h-8 rounded-full bg-blue-100 flex items-center justify-center mr-2 shrink-0">
          <span class="text-sm"></span>
        </div>

        <div class="max-w-[75%]">
          <div :class="[
            'rounded-xl px-4 py-2.5',
            msg.isFromMe ? 'bg-blue-500 text-white' : 'bg-gray-100 text-gray-800'
          ]">
            <!-- Text -->
            <p v-if="msg.type === 'text'">{{ msg.text }}</p>

            <!-- File -->
            <div v-if="msg.type === 'file'" class="flex items-center gap-2">
              <span class="text-xl">📄</span>
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium truncate">{{ msg.fileName }}</p>
                <p class="text-xs opacity-70">{{ formatSize(msg.fileSize) }}</p>
                <!-- Progress (receiving/sending) -->
                <div v-if="msg.status === 'receiving' || msg.status === 'sending'" class="mt-1">
                  <div class="w-full h-1.5 rounded-full bg-gray-300 dark:bg-gray-600">
                    <div class="h-full rounded-full transition-all" :class="msg.isFromMe ? 'bg-white' : 'bg-blue-400'"
                      :style="{ width: ((msg.progress || 0) * 100) + '%' }"></div>
                  </div>
                  <p class="text-xs mt-0.5">{{ Math.round((msg.progress || 0) * 100) }}%</p>
                  <button v-if="msg.status === 'sending'" @click="cancelTransfer(msg.id)"
                    class="text-xs mt-1 underline opacity-70 hover:opacity-100">取消</button>
                </div>
                <!-- 已接收：下载 + 移除按钮 -->
                <div v-if="msg.status === 'received'" class="mt-1.5 flex items-center gap-2">
                  <button @click="downloadFile(msg.id)"
                    class="text-xs px-2 py-1 rounded bg-green-100 text-green-700 hover:bg-green-200 transition-colors">
                    ⬇ 下载
                  </button>
                  <button @click="removeFileMsg(msg.id)"
                    class="text-xs px-2 py-1 rounded bg-gray-100 text-gray-500 hover:bg-gray-200 transition-colors">
                    ✕ 移除
                  </button>
                </div>
                <p v-if="msg.status === 'sent'" class="text-xs text-green-600 mt-0.5">已发送 ✓</p>
                <p v-if="msg.status === 'cancelled'" class="text-xs text-red-400 mt-0.5">已取消</p>
              </div>
            </div>

            <p class="text-xs mt-1 opacity-60 text-right">{{ msg.timestamp }}</p>
          </div>

          <!-- 状态标注 -->
          <div class="flex items-center justify-end gap-1 mt-0.5 px-1">
            <span v-if="msg.isFromMe && msg.status === 'sending'" class="text-xs text-gray-400">发送中...</span>
            <span v-if="msg.isFromMe && msg.status === 'sent' && msg.readStatus !== 'read'" class="text-xs text-gray-400">已发送</span>
            <span v-if="msg.isFromMe && msg.readStatus === 'read'" class="text-xs text-blue-500 font-medium">已读</span>
            <span v-if="msg.isFromMe && msg.status === 'failed'" class="text-xs text-red-500">发送失败</span>
            <span v-if="!msg.isFromMe && msg.readStatus === 'unread'" class="text-xs text-blue-500 bg-blue-50 px-1.5 py-0.5 rounded">未读</span>
          </div>
        </div>

        <!-- 自己头像 -->
        <div v-if="msg.isFromMe" class="w-8 h-8 rounded-full bg-blue-500 flex items-center justify-center ml-2 shrink-0">
          <span class="text-sm text-white"></span>
        </div>
      </div>
    </div>

    <!-- 输入栏 -->
    <div v-if="store.isConnected" class="p-3 border-t border-gray-100 bg-white">
      <div class="flex items-center gap-2">
        <button @click="pickAndSendFile" class="w-9 h-9 rounded-lg hover:bg-gray-100 flex items-center justify-center text-gray-500"
          title="发送文件">📎</button>
        <input v-model="textInput" @keyup.enter="sendTextMsg" placeholder="输入消息..."
          class="flex-1 px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:border-blue-400" />
        <button @click="sendTextMsg" :disabled="!textInput.trim()"
          class="w-9 h-9 rounded-lg bg-blue-500 hover:bg-blue-600 disabled:bg-gray-300 text-white flex items-center justify-center"
          title="发送">▶</button>
      </div>
    </div>
    <div v-else-if="store.messages.length === 0" class="p-4 text-center text-sm text-gray-400">
      等待手机端发起消息连接...
    </div>
    <div v-else class="p-4 text-center text-sm text-orange-500">
      连接已断开，等待 App 端重新连接...
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick, watch } from 'vue'
import { useMessageStore } from '../stores/message'
import { useMessageTransfer } from '../composables/useMessageTransfer'

const store = useMessageStore()
const {
  sendText, pickAndSendFile, cancelTransfer, disconnect,
  pendingFile, confirmFile, rejectFile, downloadFile,
} = useMessageTransfer()

const textInput = ref('')
const msgList = ref(null)

function sendTextMsg() {
  const t = textInput.value.trim()
  if (!t) return
  sendText(t)
  textInput.value = ''
}

function disconnectChannel() {
  disconnect()
}

function removeFileMsg(id) {
  // 释放 blob URL 并移除消息
  const msg = store.messages.find(m => m.id === id)
  if (msg && msg.blobUrl) {
    URL.revokeObjectURL(msg.blobUrl)
  }
  store.removeMessage(id)
}

function scrollBottom() {
  nextTick(() => {
    if (msgList.value) msgList.value.scrollTop = msgList.value.scrollHeight
  })
}

function formatSize(bytes) {
  if (!bytes) return ''
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB'
  if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB'
  return (bytes / 1073741824).toFixed(2) + ' GB'
}

watch(() => store.messages.length, () => scrollBottom())

// 进入页面标记为查看中（清零未读+通知App已读），离开页面只取消查看状态（不断连）
onMounted(() => {
  store.setViewing(true)
  scrollBottom()
})
onUnmounted(() => {
  store.setViewing(false)
  // 注意：不调用 disconnect()，保持全局连接
})
</script>
