<template>
  <div class="flex h-full">
    <!-- 左侧对话列表 -->
    <Transition name="slide">
      <ConversationList
        v-if="showSidebar"
        :conversations="store.sortedConversations"
        :active-id="store.activeConversationId"
        @create="handleCreate"
        @select="handleSelect"
        @delete="handleDelete"
      />
    </Transition>

    <!-- 中间：消息区 -->
    <div class="flex-1 flex flex-col min-w-0">
      <!-- 顶部工具栏 -->
      <div class="flex items-center justify-between px-4 py-2 border-b border-gray-100 bg-white shrink-0">
        <div class="flex items-center gap-2">
          <!-- 侧栏切换按钮 -->
          <button
            class="lg:hidden w-8 h-8 rounded flex items-center justify-center hover:bg-gray-100"
            @click="showSidebar = !showSidebar"
          >
            ☰
          </button>
          <h2 class="text-sm font-semibold text-gray-700 truncate max-w-[200px]">
            {{ store.activeConversation?.title || 'AI 对话' }}
          </h2>
        </div>

        <div class="flex items-center gap-2">
          <ModelSelector
            :models="models"
            :selected-model="store.selectedModel"
            :configured-providers="configuredProviders"
            @select="handleModelSelect"
          />
          <button
            class="w-8 h-8 rounded flex items-center justify-center hover:bg-gray-100 text-gray-500 relative"
            @click="showTokenUsage = !showTokenUsage"
            title="Token 用量"
          >
            📊
          </button>
        </div>
      </div>

      <!-- Token 用量面板（可折叠） -->
      <div v-if="showTokenUsage" class="px-4 py-2 bg-white border-b border-gray-100">
        <TokenUsage :stats="tokenStats" />
      </div>

      <!-- 消息列表 -->
      <div ref="messageContainer" class="flex-1 overflow-y-auto px-4 py-4">
        <div v-if="store.messages.length === 0 && !store.streaming" class="flex flex-col items-center justify-center h-full text-gray-400">
          <span class="text-5xl mb-4">💬</span>
          <p class="text-lg font-medium mb-1">开始与 AI 对话</p>
          <p class="text-sm">支持 GPT-4o、Claude、Gemini 等 7 大模型</p>
        </div>

        <div v-else class="space-y-1">
          <ChatMessage
            v-for="msg in store.messages"
            :key="msg.id"
            :role="msg.role"
            :content="msg.content"
            :created-at="msg.createdAt"
            :streaming="msg.streaming || false"
          />
        </div>
      </div>

      <!-- 底部输入区 -->
      <div class="px-4 py-3 border-t border-gray-100 bg-white">
        <ChatInput
          :streaming="store.streaming"
          @send="handleSend"
          @stop="handleStop"
        />
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, nextTick, inject } from 'vue'
import { useChatStore } from '../../stores/chat'
import { useDeviceStore } from '../../stores/device'
import modelApi from '../../api/model'
import statsApi from '../../api/stats'
import ConversationList from './ConversationList.vue'
import ChatMessage from './ChatMessage.vue'
import ChatInput from './ChatInput.vue'
import ModelSelector from './ModelSelector.vue'
import TokenUsage from './TokenUsage.vue'

const showToast = inject('showToast', () => {})

const store = useChatStore()
const deviceStore = useDeviceStore()

const showSidebar = ref(true)
const showTokenUsage = ref(false)
const models = ref([])
const configuredProviders = ref([])
const tokenStats = ref({ todayInput: 0, todayOutput: 0, totalConversations: 0, byModel: [] })
const messageContainer = ref(null)

// ======== 初始化 ========

/** 加载模型列表和 API Keys */
async function loadModels() {
  try {
    const [modelData, keyData] = await Promise.all([
      modelApi.getModels(),
      modelApi.getApiKeys(),
    ])
    models.value = Array.isArray(modelData) ? modelData : []
    configuredProviders.value = (Array.isArray(keyData) ? keyData : []).map((k) => k.provider)
  } catch (err) {
    showToast('加载模型列表失败: ' + err.message, 'error')
  }
}

/** 加载 Token 统计 */
async function loadTokenStats() {
  try {
    const [stats, byModel] = await Promise.all([
      statsApi.getTokenStats({ period: 'today' }),
      statsApi.getTokenStatsByModel({ period: 'today' }),
    ])
    tokenStats.value = {
      todayInput: stats?.inputTokens || 0,
      todayOutput: stats?.outputTokens || 0,
      totalConversations: stats?.conversationCount || 0,
      byModel: Array.isArray(byModel) ? byModel : [],
    }
  } catch {
    // 静默失败，统计数据不影响核心功能
  }
}

loadModels()
loadTokenStats()

// ======== 操作 ========

/** 新建对话 */
function handleCreate() {
  store.createConversation()
  showToast('已创建新对话', 'info')
}

/** 选择对话 */
async function handleSelect(convId) {
  try {
    await store.selectConversation(convId)
    scrollToBottom()
  } catch (err) {
    showToast('加载消息失败: ' + err.message, 'error')
  }
}

/** 删除对话 */
async function handleDelete(convId) {
  try {
    await store.deleteConversation(convId)
    showToast('对话已删除', 'success')
  } catch (err) {
    showToast('删除失败: ' + err.message, 'error')
  }
}

/** 发送消息 */
async function handleSend(content) {
  if (store.streaming) return

  // 如果没有选中对话，自动创建
  if (!store.activeConversationId) {
    store.createConversation()
  }

  const convId = store.activeConversationId
  scrollToBottom()

  try {
    await store.sendMessage(convId, content, store.selectedModel, {
      onToken: () => {
        scrollToBottom()
      },
      onDone: () => {
        scrollToBottom()
        loadTokenStats()
      },
      onError: (err) => {
        showToast('消息发送失败: ' + err.message, 'error')
      },
    })
    // 更新对话列表排序
    store.fetchConversations()
  } catch (err) {
    showToast('请求失败: ' + err.message, 'error')
  }
}

/** 停止流式输出 */
function handleStop() {
  store.cancelStream()
}

/** 切换模型 */
function handleModelSelect(modelId) {
  store.setModel(modelId)
  showToast(`已切换模型: ${modelId}`, 'info')
}

/** 滚动到消息底部 */
function scrollToBottom() {
  nextTick(() => {
    if (messageContainer.value) {
      messageContainer.value.scrollTop = messageContainer.value.scrollHeight
    }
  })
}
</script>

<style scoped>
.slide-enter-active,
.slide-leave-active {
  transition: all 0.25s ease;
}
.slide-enter-from,
.slide-leave-to {
  transform: translateX(-100%);
  width: 0;
}
</style>
