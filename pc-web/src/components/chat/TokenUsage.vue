<template>
  <div class="card">
    <!-- 标题栏 -->
    <div class="flex items-center justify-between mb-4">
      <h3 class="text-sm font-semibold text-gray-700">📊 Token 用量</h3>
      <button
        class="text-xs text-primary-600 hover:text-primary-700"
        @click="collapsed = !collapsed"
      >
        {{ collapsed ? '展开' : '收起' }}
      </button>
    </div>

    <!-- 今日概览 -->
    <div class="grid grid-cols-2 gap-3 mb-4">
      <div class="bg-blue-50 rounded-lg p-3 text-center">
        <p class="text-xs text-gray-500">📥 输入 Tokens</p>
        <p class="text-lg font-bold text-blue-700">{{ formatNum(todayInput) }}</p>
      </div>
      <div class="bg-green-50 rounded-lg p-3 text-center">
        <p class="text-xs text-gray-500">📤 输出 Tokens</p>
        <p class="text-lg font-bold text-green-700">{{ formatNum(todayOutput) }}</p>
      </div>
    </div>

    <div class="flex justify-between text-xs text-gray-400 mb-3">
      <span>总计: {{ formatNum(todayInput + todayOutput) }}</span>
      <span>会话数: {{ totalConversations }}</span>
    </div>

    <!-- 按模型统计（可折叠） -->
    <div v-if="!collapsed">
      <h4 class="text-xs font-semibold text-gray-500 mb-2 uppercase">按模型统计</h4>
      <div class="space-y-2">
        <div v-for="item in modelStats" :key="item.model" class="flex items-center gap-2">
          <span class="text-xs text-gray-600 w-24 truncate" :title="item.model">
            {{ item.modelName || item.model }}
          </span>
          <div class="flex-1 h-2 bg-gray-200 rounded-full overflow-hidden">
            <div
              class="h-full bg-primary-500 rounded-full transition-all duration-300"
              :style="{ width: barWidth(item) + '%' }"
            ></div>
          </div>
          <span class="text-xs text-gray-500 w-16 text-right">
            {{ formatNum(item.totalTokens || 0) }}
          </span>
        </div>
      </div>

      <!-- 空状态 -->
      <p v-if="!modelStats.length" class="text-xs text-gray-400 text-center py-3">
        暂无数据，开始对话后自动统计
      </p>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'

const props = defineProps({
  /** Token 统计数据 */
  stats: {
    type: Object,
    default: () => ({
      todayInput: 0,
      todayOutput: 0,
      totalConversations: 0,
      byModel: [],
    }),
  },
})

const collapsed = ref(true)

const todayInput = computed(() => props.stats.todayInput || 0)
const todayOutput = computed(() => props.stats.todayOutput || 0)
const totalConversations = computed(() => props.stats.totalConversations || 0)
const modelStats = computed(() => props.stats.byModel || [])

/** 进度条宽度 */
const maxTokens = computed(() => {
  const max = Math.max(...modelStats.value.map((m) => m.totalTokens || 0), 1)
  return max
})

function barWidth(item) {
  if (!maxTokens.value) return 0
  return Math.round(((item.totalTokens || 0) / maxTokens.value) * 100)
}

/** 格式化数字 */
function formatNum(n) {
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M'
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K'
  return String(n)
}
</script>
