<template>
  <div class="p-6 max-w-[1400px] mx-auto">
    <!-- 顶部状态条 -->
    <div class="flex items-center justify-between mb-6 flex-wrap gap-3">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">服务器运维监控</h1>
        <p class="text-sm text-gray-500 mt-1">自动扫描 · 实时状态 · 一键运维 · Nginx 端口锁定</p>
      </div>
      <div class="flex items-center gap-3">
        <span
          class="inline-flex items-center gap-2 px-3 py-1.5 rounded-full text-sm font-medium"
          :class="store.connected ? 'bg-green-100 text-green-700' : 'bg-yellow-100 text-yellow-700'"
        >
          <span class="w-2 h-2 rounded-full" :class="store.connected ? 'bg-green-500' : 'bg-yellow-500 animate-pulse'"></span>
          {{ store.connected ? '实时连接' : '连接中/断开' }}
        </span>
        <span class="text-xs text-gray-400">角色：{{ store.role === 'admin' ? '管理员' : '只读' }}</span>
      </div>
    </div>

    <!-- 统计卡片 -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
      <StatCard title="项目总数" :value="store.stats.total" icon="📦" tone="default" />
      <StatCard title="运行中" :value="store.stats.running" icon="🟢" tone="green" />
      <StatCard title="已停止" :value="store.stats.stopped" icon="⚪" tone="default" />
      <StatCard title="异常/未运行" :value="store.stats.error" icon="🔴" tone="red" />
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <!-- 系统资源 -->
      <div class="bg-white rounded-xl border border-surface-200 p-5 shadow-sm lg:col-span-2">
        <h2 class="text-lg font-semibold text-surface-900 mb-4">系统资源</h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div class="space-y-1">
            <div class="text-xs text-gray-500">CPU 使用率</div>
            <div class="text-2xl font-bold text-surface-900">{{ pct(system.cpuUsagePercent) }}</div>
            <div class="w-full h-2 bg-surface-100 rounded"><div class="h-2 rounded bg-primary-500" :style="{ width: (system.cpuUsagePercent || 0) + '%' }"></div></div>
          </div>
          <div class="space-y-1">
            <div class="text-xs text-gray-500">内存占用</div>
            <div class="text-2xl font-bold text-surface-900">{{ pct(system.memUsedPercent) }}</div>
            <div class="w-full h-2 bg-surface-100 rounded"><div class="h-2 rounded bg-primary-500" :style="{ width: (system.memUsedPercent || 0) + '%' }"></div></div>
            <div class="text-[10px] text-gray-400">{{ formatBytes(system.memUsedBytes) }} / {{ formatBytes(system.memTotalBytes) }}</div>
          </div>
          <div class="space-y-1">
            <div class="text-xs text-gray-500">磁盘占用</div>
            <div class="text-2xl font-bold text-surface-900">{{ pct(system.disk?.usedPercent) }}</div>
            <div class="w-full h-2 bg-surface-100 rounded"><div class="h-2 rounded bg-amber-500" :style="{ width: (system.disk?.usedPercent || 0) + '%' }"></div></div>
          </div>
          <div class="space-y-1">
            <div class="text-xs text-gray-500">运行时长</div>
            <div class="text-2xl font-bold text-surface-900">{{ formatUptime(system.uptimeSec) }}</div>
            <div class="text-[10px] text-gray-400">{{ system.hostname || '-' }}</div>
          </div>
        </div>

        <div class="mt-4 grid grid-cols-2 md:grid-cols-4 gap-2 text-xs text-gray-500">
          <div>系统：{{ system.platform || '-' }}</div>
          <div>架构：{{ system.arch || '-' }}</div>
          <div>CPU 核数：{{ system.cpuCount || '-' }}</div>
          <div>负载：{{ (system.loadavg || []).map((n) => n.toFixed(2)).join(' / ') }}</div>
        </div>
      </div>

      <!-- 告警 -->
      <div class="bg-white rounded-xl border border-surface-200 p-5 shadow-sm">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-lg font-semibold text-surface-900">实时告警</h2>
          <span class="text-xs text-gray-400">{{ store.alerts.length }} 条</span>
        </div>
        <div class="space-y-2 max-h-64 overflow-y-auto">
          <div v-if="!store.alerts.length" class="text-sm text-gray-400 py-6 text-center">暂无告警</div>
          <div
            v-for="a in store.alerts"
            :key="a.id"
            class="p-2 rounded border-l-4 text-sm"
            :class="a.level === 'error' ? 'border-red-500 bg-red-50' : 'border-yellow-500 bg-yellow-50'"
          >
            <div class="flex items-start justify-between gap-2">
              <div>
                <div class="font-medium text-surface-900">{{ a.message }}</div>
                <div class="text-[10px] text-gray-400">{{ fmtTime(a.time) }}</div>
              </div>
              <button class="text-gray-400 hover:text-gray-600" @click="store.dismissAlert(a.id)">✕</button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- 快捷入口 -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-6">
      <router-link to="/monitor/services" class="block p-5 rounded-xl bg-white border border-surface-200 shadow-sm hover:border-primary-400 hover:shadow transition">
        <div class="text-2xl">📋</div>
        <div class="mt-2 font-semibold text-surface-900">服务列表</div>
        <div class="text-xs text-gray-400 mt-1">查看 / 启停 / 重启全部项目</div>
      </router-link>
      <router-link to="/monitor/nginx" class="block p-5 rounded-xl bg-white border border-surface-200 shadow-sm hover:border-primary-400 hover:shadow transition">
        <div class="text-2xl">🌐</div>
        <div class="mt-2 font-semibold text-surface-900">Nginx 管理</div>
        <div class="text-xs text-gray-400 mt-1">配置编辑 / 重载 / 端口锁定</div>
      </router-link>
      <router-link to="/monitor/audit" class="block p-5 rounded-xl bg-white border border-surface-200 shadow-sm hover:border-primary-400 hover:shadow transition">
        <div class="text-2xl">📝</div>
        <div class="mt-2 font-semibold text-surface-900">操作审计</div>
        <div class="text-xs text-gray-400 mt-1">全部运维操作留痕</div>
      </router-link>
      <router-link to="/monitor/settings" class="block p-5 rounded-xl bg-white border border-surface-200 shadow-sm hover:border-primary-400 hover:shadow transition">
        <div class="text-2xl">⚙️</div>
        <div class="mt-2 font-semibold text-surface-900">监控设置</div>
        <div class="text-xs text-gray-400 mt-1">扫描根 / 深度 / 权限</div>
      </router-link>
    </div>
  </div>
</template>

<script setup>
import { onMounted, inject, computed } from 'vue'
import { useMonitorStore } from '../../stores/monitor'
import StatCard from '../../components/monitor/StatCard.vue'
import { formatBytes, formatUptime } from '../../utils/monitorFormat'

const store = useMonitorStore()
const showToast = inject('showToast', () => {})

const system = computed(() => store.system)

function pct(v) { return v == null ? '-' : `${v}%` }
function fmtTime(t) { return t ? new Date(t).toLocaleTimeString() : '' }

onMounted(() => {
  store.connect()
  store.refreshAll().catch(() => showToast('初始数据加载失败，依赖实时推送', 'warning'))
})
</script>
