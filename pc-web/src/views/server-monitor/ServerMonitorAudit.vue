<template>
  <div class="p-6 max-w-[1400px] mx-auto">
    <div class="flex items-center justify-between mb-5 flex-wrap gap-3">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">操作审计</h1>
        <p class="text-sm text-gray-500 mt-1">所有运维操作留痕 · 支持查询与导出</p>
      </div>
      <button class="px-3 py-2 rounded-lg bg-primary-600 text-white text-sm hover:bg-primary-700" @click="exportAudit">⬇ 导出 JSON</button>
    </div>

    <!-- 过滤 -->
    <div class="flex items-center gap-3 mb-4 flex-wrap">
      <select v-model="actionFilter" class="px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none">
        <option value="">全部操作</option>
        <option value="start">启动</option>
        <option value="stop">停止</option>
        <option value="restart">重启</option>
        <option value="build">编译</option>
        <option value="git_pull">拉取代码</option>
        <option value="nginx_edit">Nginx 配置修改</option>
        <option value="nginx_reload">Nginx 重载</option>
        <option value="set_port">端口设置</option>
      </select>
      <input v-model="serviceFilter" placeholder="服务名筛选" class="px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none flex-1 min-w-[160px]" />
      <button class="px-3 py-2 rounded-lg border border-surface-200 text-sm" @click="fetchList(1)">查询</button>
      <span class="text-xs text-gray-400">共 {{ total }} 条</span>
    </div>

    <!-- 表格 -->
    <div class="bg-white rounded-xl border border-surface-200 shadow-sm overflow-hidden">
      <table class="w-full text-sm">
        <thead class="bg-surface-50 text-gray-500 text-xs">
          <tr>
            <th class="text-left px-4 py-3">时间</th>
            <th class="text-left px-4 py-3">操作人</th>
            <th class="text-left px-4 py-3">操作</th>
            <th class="text-left px-4 py-3">服务</th>
            <th class="text-left px-4 py-3">结果</th>
            <th class="text-left px-4 py-3">详情</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="a in items" :key="a.id" class="border-t border-surface-100 hover:bg-surface-50">
            <td class="px-4 py-3 text-gray-500 whitespace-nowrap">{{ fmt(a.time) }}</td>
            <td class="px-4 py-3 font-mono text-xs">{{ a.operator }}</td>
            <td class="px-4 py-3"><span class="px-2 py-0.5 rounded bg-surface-100 text-xs">{{ actionLabel(a.action) }}</span></td>
            <td class="px-4 py-3">{{ a.serviceName }}</td>
            <td class="px-4 py-3">
              <span :class="a.success ? 'text-green-600' : 'text-red-600'">{{ a.success ? '成功' : '失败' }}</span>
            </td>
            <td class="px-4 py-3 text-gray-500 text-xs max-w-[280px] truncate" :title="a.detail">{{ a.detail }}</td>
          </tr>
          <tr v-if="!items.length"><td colspan="6" class="px-4 py-10 text-center text-gray-400">暂无审计记录</td></tr>
        </tbody>
      </table>
    </div>

    <!-- 分页 -->
    <div class="flex items-center justify-center gap-3 mt-4" v-if="total > pageSize">
      <button class="px-3 py-1.5 rounded-lg border border-surface-200 text-sm disabled:opacity-40" :disabled="page <= 1" @click="fetchList(page - 1)">上一页</button>
      <span class="text-sm text-gray-500">{{ page }}</span>
      <button class="px-3 py-1.5 rounded-lg border border-surface-200 text-sm" @click="fetchList(page + 1)">下一页</button>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, inject } from 'vue'
import { monitorApi } from '../../api/monitor'
import { useMonitorStore } from '../../stores/monitor'

const store = useMonitorStore()
const showToast = inject('showToast', () => {})

const items = ref([])
const total = ref(0)
const page = ref(1)
const pageSize = ref(50)
const actionFilter = ref('')
const serviceFilter = ref('')

const ACTION_LABELS = {
  start: '启动', stop: '停止', restart: '重启', build: '编译',
  git_pull: '拉取代码', nginx_edit: 'Nginx 配置修改', nginx_reload: 'Nginx 重载',
  nginx_start: 'Nginx 启动', nginx_stop: 'Nginx 停止', nginx_restart: 'Nginx 重启',
  set_port: '端口设置', set_env: '环境变量', set_script: '脚本覆盖', nginx_link: 'Nginx 关联', nginx_unlink: '解除关联',
}
function actionLabel(a) { return ACTION_LABELS[a] || a }
function fmt(t) { return t ? new Date(t).toLocaleString() : '' }

async function fetchList(p = 1) {
  page.value = p
  try {
    const r = await monitorApi.getAudit({
      page: p, pageSize: pageSize.value,
      action: actionFilter.value || undefined,
      serviceName: serviceFilter.value || undefined,
    })
    items.value = r.items || []
    total.value = r.total || 0
  } catch (e) { showToast('加载审计失败: ' + e.message, 'error') }
}

async function exportAudit() {
  try {
    const blob = await monitorApi.exportAudit()
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `monitor-audit-${Date.now()}.json`
    a.click()
    URL.revokeObjectURL(url)
  } catch (e) { showToast('导出失败: ' + e.message, 'error') }
}

onMounted(() => { store.connect(); fetchList(1) })
</script>
