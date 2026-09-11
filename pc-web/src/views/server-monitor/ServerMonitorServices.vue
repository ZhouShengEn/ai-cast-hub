<template>
  <div class="p-6 max-w-[1400px] mx-auto">
    <div class="flex items-center justify-between mb-5 flex-wrap gap-3">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">服务列表</h1>
        <p class="text-sm text-gray-500 mt-1">自动识别项目类型 · 一键启停 · 端口锁定标记</p>
      </div>
      <div class="flex items-center gap-2">
        <button
          class="px-3 py-2 rounded-lg bg-primary-600 text-white text-sm hover:bg-primary-700 disabled:opacity-50"
          :disabled="store.loading"
          @click="forceScan"
        >🔄 重新扫描</button>
        <span
          class="inline-flex items-center gap-2 px-3 py-1.5 rounded-full text-sm"
          :class="store.connected ? 'bg-green-100 text-green-700' : 'bg-yellow-100 text-yellow-700'"
        >
          <span class="w-2 h-2 rounded-full" :class="store.connected ? 'bg-green-500' : 'bg-yellow-500 animate-pulse'"></span>
          {{ store.connected ? '实时' : '离线' }}
        </span>
      </div>
    </div>

    <!-- 搜索 / 排序 -->
    <div class="flex items-center gap-3 mb-4 flex-wrap">
      <input
        v-model="search"
        placeholder="搜索服务名称 / 路径 / 类型"
        class="flex-1 min-w-[200px] px-3 py-2 rounded-lg border border-surface-200 focus:border-primary-500 outline-none text-sm"
      />
      <select v-model="sortKey" class="px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none">
        <option value="name">按名称</option>
        <option value="status">按状态</option>
        <option value="uptime">按时长</option>
        <option value="type">按类型</option>
      </select>
      <button class="px-3 py-2 rounded-lg border border-surface-200 text-sm" @click="sortDir = sortDir === 'asc' ? 'desc' : 'asc'">
        {{ sortDir === 'asc' ? '↑' : '↓' }}
      </button>
    </div>

    <!-- 列表 -->
    <div class="space-y-2">
      <div v-if="!store.services.length" class="text-center text-gray-400 py-16 bg-white rounded-xl border border-surface-200">
        未扫描到项目，请检查扫描根目录设置（监控设置页）。
      </div>

      <div
        v-for="svc in sortedServices"
        :key="svc.id"
        class="bg-white rounded-xl border border-surface-200 shadow-sm"
      >
        <div class="flex items-center gap-4 p-4 flex-wrap">
          <!-- 折叠 -->
          <button class="text-gray-400 hover:text-gray-600" @click="toggle(svc.id)">{{ collapsed.has(svc.id) ? '▶' : '▼' }}</button>

          <!-- 名称 + 类型 -->
          <div class="min-w-[180px] flex-1">
            <div class="flex items-center gap-2">
              <router-link :to="`/monitor/service/${svc.id}`" class="font-semibold text-surface-900 hover:text-primary-600 truncate">
                {{ svc.name }}
              </router-link>
              <span class="px-1.5 py-0.5 rounded bg-surface-100 text-[10px] text-gray-500">{{ typeLabel(svc.type) }}</span>
              <span v-if="svc.source === 'custom'" class="px-1.5 py-0.5 rounded bg-indigo-100 text-[10px] text-indigo-600">自定义脚本</span>
            </div>
            <div class="text-xs text-gray-400 truncate" :title="svc.path">{{ truncatePath(svc.path) }}</div>
          </div>

          <!-- 状态 -->
          <StatusBadge
            :running="svc.running"
            :error="svc.status === 'error' || svc.status === 'start_failed' || svc.status === 'crashed'"
            :starting="svc.status === 'starting'"
            :port-locked="svc.portLocked"
            :text="badgeText(svc)" />

          <!-- 端口 / 时长 -->
          <div class="text-sm text-gray-500 hidden md:block w-40">
            <div>端口：<span class="font-mono">{{ svc.port || '-' }}</span> <span v-if="svc.portLocked" class="text-amber-600">🔒</span></div>
            <div>运行：{{ formatUptime(svc.uptimeSec) }}</div>
          </div>

          <!-- CPU / MEM -->
          <div class="text-sm text-gray-500 hidden lg:block w-32">
            <div>CPU：{{ svc.cpuPercent == null ? '-' : svc.cpuPercent + '%' }}</div>
            <div>内存：{{ svc.memRssMb == null ? '-' : svc.memRssMb + ' MB' }}</div>
          </div>

          <!-- 操作 -->
          <div class="flex items-center gap-2 ml-auto">
            <button v-if="!svc.running" :disabled="!isAdmin || svc.status === 'starting'" class="px-3 py-1.5 rounded-lg bg-green-600 text-white text-xs hover:bg-green-700 disabled:opacity-40" @click="doStart(svc)">
              {{ svc.status === 'starting' ? '启动中...' : '启动' }}
            </button>
            <button v-else :disabled="!isAdmin" class="px-3 py-1.5 rounded-lg bg-gray-200 text-gray-700 text-xs hover:bg-gray-300 disabled:opacity-40" @click="doStop(svc)">停止</button>
            <button :disabled="!isAdmin || !svc.running" class="px-3 py-1.5 rounded-lg bg-amber-500 text-white text-xs hover:bg-amber-600 disabled:opacity-40" @click="doRestart(svc)">重启</button>
            <router-link :to="`/monitor/service/${svc.id}`" class="px-3 py-1.5 rounded-lg border border-surface-200 text-xs text-gray-600 hover:bg-surface-50">详情</router-link>
          </div>
        </div>

        <!-- 折叠详情：Git 状态 + 快速操作 -->
        <div v-if="!collapsed.has(svc.id)" class="px-4 pb-4 border-t border-surface-100 pt-3 text-sm text-gray-500 flex items-center gap-4 flex-wrap">
          <span>
            Git：<span :class="gitInfo(svc).cls">{{ gitInfo(svc).icon }} {{ gitInfo(svc).text }}</span>
            <span v-if="svc.git?.branch" class="text-gray-400">（{{ svc.git.branch }}）</span>
          </span>
          <span v-if="svc.nginxLink" class="text-amber-600">
            🔒 已关联 Nginx：{{ svc.nginxLink.serverName || svc.nginxLink.configFile }} :{{ svc.nginxLink.proxyPort }}
          </span>
          <span v-if="svc.scriptInfo?.notes" class="text-gray-400">脚本：{{ svc.scriptInfo.notes }}</span>
          <span class="ml-auto">
            <button :disabled="!isAdmin" class="px-2 py-1 rounded bg-primary-600 text-white text-xs hover:bg-primary-700 disabled:opacity-40" @click="doBuild(svc)">编译</button>
          </span>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, inject } from 'vue'
import { useMonitorStore } from '../../stores/monitor'
import StatusBadge from '../../components/monitor/StatusBadge.vue'
import { typeLabel, formatUptime, gitLabel, truncatePath } from '../../utils/monitorFormat'

const store = useMonitorStore()
const showToast = inject('showToast', () => {})
const search = ref('')
const sortKey = ref('status')
const sortDir = ref('asc')
const collapsed = ref(new Set())
const isAdmin = computed(() => store.role === 'admin')

function toggle(id) {
  const s = new Set(collapsed.value)
  s.has(id) ? s.delete(id) : s.add(id)
  collapsed.value = s
}
function badgeText(svc) {
function badgeText(svc) {
  // 细分状态优先：启动中 / 启动失败 / 异常退出 都要如实展示，
  // 不能像以前那样「进程还在就算运行中、进程没了就显示未启动」。
  switch (svc.status) {
    case 'starting': return '启动中'
    case 'start_failed': return '启动失败'
    case 'crashed': return '异常退出'
    case 'error': return '异常'
    default: return svc.running ? '运行中' : '已停止'
  }
}
}
function gitInfo(svc) {
  const g = svc.git?.status ? gitLabel(svc.git.status) : { text: '-', icon: '', cls: '' }
  return g
}

const sortedServices = computed(() => {
  let list = store.services.slice()
  const kw = search.value.toLowerCase()
  if (kw) list = list.filter((s) => (s.name + s.path + s.type).toLowerCase().includes(kw))
  const dir = sortDir.value === 'asc' ? 1 : -1
  list.sort((a, b) => {
    let va, vb
    switch (sortKey.value) {
      case 'name': va = a.name; vb = b.name; break
      case 'uptime': va = a.uptimeSec || 0; vb = b.uptimeSec || 0; break
      case 'type': va = a.type; vb = b.type; break
      default: va = a.running ? 0 : 1; vb = b.running ? 0 : 1
    }
    if (va < vb) return -1 * dir
    if (va > vb) return 1 * dir
    return 0
  })
  return list
})

async function forceScan() {
  try { await store.scan(); await store.refreshAll(); showToast('扫描完成', 'success') }
  catch (e) { showToast('扫描失败: ' + e.message, 'error') }
}
async function doStart(svc) { try { await store.start(svc.id); showToast(`已启动 ${svc.name}`, 'success') } catch (e) { showToast('启动失败: ' + e.message, 'error') } }
async function doStop(svc) {
  if (!confirm(`确认停止「${svc.name}」？`)) return
  try { await store.stop(svc.id); showToast(`已停止 ${svc.name}`, 'info') } catch (e) { showToast('停止失败: ' + e.message, 'error') }
}
async function doRestart(svc) {
  if (!confirm(`确认重启「${svc.name}」？`)) return
  try { await store.restart(svc.id); showToast(`已重启 ${svc.name}`, 'success') } catch (e) { showToast('重启失败: ' + e.message, 'error') }
}
async function doBuild(svc) {
  if (!confirm(`确认编译「${svc.name}」？（实时日志见详情页）`)) return
  try { await store.build(svc.id); showToast('编译已触发，请到详情页查看日志', 'info') } catch (e) { showToast('编译失败: ' + e.message, 'error') }
}

onMounted(() => { store.connect(); store.refreshAll().catch(() => {}) })
</script>
