<template>
  <div class="flex flex-col bg-surface-900 rounded-lg overflow-hidden h-full">
    <!-- 工具栏 -->
    <div class="flex items-center gap-2 px-3 py-2 bg-surface-800 text-white text-xs flex-wrap">
      <label class="flex items-center gap-1">
        过滤
        <input
          v-model="keyword"
          placeholder="关键词"
          class="bg-surface-900 text-white text-xs rounded px-2 py-1 w-32 outline-none border border-surface-700 focus:border-primary-500"
        />
      </label>
      <label class="flex items-center gap-1 cursor-pointer">
        <input type="checkbox" v-model="caseSensitive" /> 区分大小写
      </label>
      <label class="flex items-center gap-1 cursor-pointer">
        <input type="checkbox" v-model="autoScroll" /> 自动滚动
      </label>
      <button class="ml-auto px-2 py-1 rounded bg-surface-700 hover:bg-surface-600" @click="emit('clear')">清空</button>
      <span class="text-gray-400">{{ filtered.length }} 行</span>
    </div>
    <!-- 日志区 -->
    <div ref="scrollRef" class="flex-1 overflow-y-auto p-3 font-mono text-xs leading-relaxed space-y-0.5">
      <div
        v-for="(l, i) in filtered"
        :key="i"
        :class="lineCls(l.level)"
        class="whitespace-pre-wrap break-all"
      >{{ l.line }}</div>
      <div v-if="!filtered.length" class="text-gray-500">暂无日志</div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, nextTick } from 'vue'

const props = defineProps({
  lines: { type: Array, default: () => [] },
})
const emit = defineEmits(['clear'])

const keyword = ref('')
const caseSensitive = ref(false)
const autoScroll = ref(true)
const scrollRef = ref(null)

const filtered = computed(() => {
  if (!keyword.value) return props.lines
  const kw = caseSensitive.value ? keyword.value : keyword.value.toLowerCase()
  return props.lines.filter((l) =>
    caseSensitive.value ? l.line.includes(kw) : l.line.toLowerCase().includes(kw)
  )
})

function lineCls(level) {
  switch (level) {
    case 'ERROR': return 'text-red-400'
    case 'WARN': return 'text-yellow-300'
    case 'DEBUG': return 'text-sky-300'
    default: return 'text-gray-300'
  }
}

watch(filtered, () => {
  if (autoScroll.value && scrollRef.value) {
    nextTick(() => { scrollRef.value.scrollTop = scrollRef.value.scrollHeight })
  }
})
</script>
