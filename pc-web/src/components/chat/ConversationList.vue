<template>
  <aside class="w-[280px] bg-white border-r border-gray-200 flex flex-col shrink-0 h-full">
    <!-- 顶部新建按钮 -->
    <div class="p-3 border-b border-gray-100">
      <button
        class="w-full py-2 px-4 bg-primary-600 text-white rounded-lg hover:bg-primary-700 transition-colors text-sm font-medium"
        @click="$emit('create')"
      >
        ✨ 新建对话
      </button>
    </div>

    <!-- 对话列表 -->
    <div class="flex-1 overflow-y-auto">
      <div v-if="conversations.length === 0" class="p-6 text-center text-gray-400 text-sm">
        <p class="mb-1">暂无对话</p>
        <p class="text-xs">点击上方按钮开始</p>
      </div>

      <ul class="py-1">
        <li
          v-for="conv in conversations"
          :key="conv.id"
          class="group relative cursor-pointer border-l-2 transition-colors"
          :class="conv.id === activeId
            ? 'bg-primary-50 border-l-primary-600'
            : 'border-l-transparent hover:bg-surface-50'"
          @click="$emit('select', conv.id)"
        >
          <div class="px-4 py-3 pr-10">
            <p class="text-sm font-medium text-gray-800 truncate">{{ conv.title || '新对话' }}</p>
            <p class="text-xs text-gray-400 mt-0.5">{{ formatTime(conv.updatedAt || conv.createdAt) }}</p>
          </div>

          <!-- 悬停删除按钮 -->
          <button
            class="absolute right-2 top-1/2 -translate-y-1/2 w-7 h-7 rounded flex items-center justify-center opacity-0 group-hover:opacity-100 text-red-500 hover:bg-red-50 transition-all"
            @click.stop="showDeleteConfirm(conv)"
            title="删除对话"
          >
            🗑
          </button>
        </li>
      </ul>
    </div>

    <!-- 删除确认弹窗 -->
    <Teleport to="body">
      <div
        v-if="deleteTarget"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/30"
        @click.self="deleteTarget = null"
      >
        <div class="bg-white rounded-xl shadow-xl p-6 w-80">
          <h3 class="text-lg font-semibold mb-2">确认删除</h3>
          <p class="text-sm text-gray-500 mb-4">
            确定要删除对话「{{ deleteTarget.title || '新对话' }}」吗？此操作不可撤销。
          </p>
          <div class="flex justify-end gap-3">
            <button
              class="px-4 py-2 text-sm rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-50"
              @click="deleteTarget = null"
            >
              取消
            </button>
            <button
              class="px-4 py-2 text-sm rounded-lg bg-red-500 text-white hover:bg-red-600"
              @click="confirmDelete"
            >
              删除
            </button>
          </div>
        </div>
      </div>
    </Teleport>
  </aside>
</template>

<script setup>
import { ref } from 'vue'

const props = defineProps({
  /** 对话列表 */
  conversations: { type: Array, default: () => [] },
  /** 当前选中对话 ID */
  activeId: { type: String, default: null },
})

const emit = defineEmits(['create', 'select', 'delete'])

/** 待删除的对话 */
const deleteTarget = ref(null)

/** 显示删除确认弹窗 */
function showDeleteConfirm(conv) {
  deleteTarget.value = conv
}

/** 确认删除并发送事件 */
function confirmDelete() {
  if (deleteTarget.value) {
    emit('delete', deleteTarget.value.id)
    deleteTarget.value = null
  }
}

/** 格式化相对时间 */
function formatTime(dateStr) {
  if (!dateStr) return ''
  const now = Date.now()
  const diff = now - new Date(dateStr).getTime()
  const seconds = Math.floor(diff / 1000)
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  const days = Math.floor(hours / 24)

  if (seconds < 60) return '刚刚'
  if (minutes < 60) return `${minutes}分钟前`
  if (hours < 24) return `${hours}小时前`
  if (days === 1) return '昨天'
  if (days < 7) return `${days}天前`
  return new Date(dateStr).toLocaleDateString('zh-CN')
}
</script>
