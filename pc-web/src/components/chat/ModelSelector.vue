<template>
  <div class="relative">
    <!-- 触发按钮 -->
    <button
      class="flex items-center gap-2 px-3 py-2 text-sm border border-gray-300 rounded-lg hover:bg-surface-50 transition-colors"
      @click="open = !open"
    >
      <span>{{ selectedModelName }}</span>
      <span class="text-xs text-gray-400">▼</span>
    </button>

    <!-- 下拉面板 -->
    <Teleport to="body">
      <div
        v-if="open"
        class="fixed inset-0 z-50"
        @click="open = false"
      ></div>
    </Teleport>
    <div
      v-if="open"
      class="absolute bottom-full left-0 mb-2 w-72 bg-white rounded-xl shadow-xl border border-gray-200 z-50 max-h-80 overflow-y-auto"
    >
      <div
        v-for="group in groupedModels"
        :key="group.provider"
        class="border-b border-gray-100 last:border-0"
      >
        <!-- 分组标题 -->
        <div class="px-3 py-2 text-xs font-semibold text-gray-400 uppercase flex items-center gap-2">
          <span class="w-1.5 h-1.5 rounded-full" :class="group.hasKey ? 'bg-green-400' : 'bg-gray-300'"></span>
          {{ group.label }}
        </div>

        <!-- 模型列表 -->
        <button
          v-for="model in group.models"
          :key="model.id"
          class="w-full text-left px-4 py-2 text-sm hover:bg-primary-50 transition-colors flex items-center justify-between"
          :class="model.id === selectedModel ? 'bg-primary-50 text-primary-700 font-medium' : 'text-gray-700'"
          @click="selectModel(model.id)"
        >
          <span>{{ model.name }}</span>
          <span v-if="model.id === selectedModel" class="text-primary-600">✓</span>
        </button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'

const props = defineProps({
  /** 模型列表 */
  models: { type: Array, default: () => [] },
  /** 当前选中模型 ID */
  selectedModel: { type: String, default: 'openai:gpt-4o' },
  /** 已配置 API Key 的 provider 列表 */
  configuredProviders: { type: Array, default: () => [] },
})

const emit = defineEmits(['select'])

const open = ref(false)

/** 供应商分组配置 */
const providerGroups = [
  { provider: 'openai', label: 'OpenAI' },
  { provider: 'claude', label: 'Claude (Anthropic)' },
  { provider: 'gemini', label: 'Gemini (Google)' },
  { provider: 'qwen', label: '通义千问' },
  { provider: 'ernie', label: '文心一言' },
  { provider: 'deepseek', label: 'DeepSeek' },
  { provider: 'glm', label: '智谱GLM' },
]

/** 当前选中模型的名称 */
const selectedModelName = computed(() => {
  const found = props.models.find((m) => m.id === props.selectedModel)
  return found ? found.name : props.selectedModel
})

/** 按 provider 分组 */
const groupedModels = computed(() => {
  return providerGroups
    .map((group) => {
      const groupModels = props.models.filter((m) => (m.provider || '').toLowerCase() === group.provider.toLowerCase())
      if (groupModels.length === 0) return null
      return {
        ...group,
        models: groupModels,
        hasKey: props.configuredProviders.includes(group.provider),
      }
    })
    .filter(Boolean)
})

/** 选择模型 */
function selectModel(modelId) {
  emit('select', modelId)
  open.value = false
}
</script>
