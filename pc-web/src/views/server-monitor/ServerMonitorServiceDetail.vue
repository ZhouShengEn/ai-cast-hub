<template>
  <div class="p-6 max-w-[1400px] mx-auto" v-if="detail">
    <!-- 头部 -->
    <div class="flex items-center justify-between mb-5 flex-wrap gap-3">
      <div class="flex items-center gap-3">
        <router-link to="/monitor/services" class="text-gray-400 hover:text-gray-600">← 返回</router-link>
        <h1 class="text-2xl font-bold text-surface-900">{{ detail.name }}</h1>
        <span class="px-2 py-0.5 rounded bg-surface-100 text-xs text-gray-500">{{ typeLabel(detail.type) }}</span>
        <StatusBadge :running="detail.running" :error="['error','start_failed','crashed'].includes(detail.status)" :port-locked="!!detail.nginxLink" :text="detail.running ? '运行中' : '已停止'" />
        <span v-if="detail.portLocked" class="text-amber-600 text-xs">🔒 端口被 Nginx 锁定</span>
      </div>
      <div class="flex items-center gap-2">
        <button v-if="!detail.running" :disabled="!isAdmin" class="px-4 py-2 rounded-lg bg-green-600 text-white text-sm hover:bg-green-700 disabled:opacity-40" @click="doStart">启动</button>
        <button v-else :disabled="!isAdmin" class="px-4 py-2 rounded-lg bg-gray-200 text-gray-700 text-sm hover:bg-gray-300 disabled:opacity-40" @click="doStop">停止</button>
        <button :disabled="!isAdmin || !detail.running" class="px-4 py-2 rounded-lg bg-amber-500 text-white text-sm hover:bg-amber-600 disabled:opacity-40" @click="doRestart">重启</button>
        <button :disabled="!isAdmin || !isGit" class="px-4 py-2 rounded-lg bg-primary-600 text-white text-sm hover:bg-primary-700 disabled:opacity-40" @click="doPull">拉取代码</button>
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <!-- 左：状态信息 -->
      <div class="space-y-4">
        <div class="bg-white rounded-xl border border-surface-200 p-5 shadow-sm">
          <h2 class="font-semibold text-surface-900 mb-3">运行时状态</h2>
          <dl class="text-sm space-y-2">
            <div class="flex justify-between"><dt class="text-gray-500">PID</dt><dd class="font-mono">{{ detail.pid || '-' }}</dd></div>
            <div class="flex justify-between"><dt class="text-gray-500">端口</dt><dd class="font-mono">{{ detail.port || '-' }} <span v-if="detail.portLocked" class="text-amber-600">🔒</span></dd></div>
            <div class="flex justify-between"><dt class="text-gray-500">运行时长</dt><dd>{{ formatUptime(detail.uptimeSec) }}</dd></div>
            <div class="flex justify-between"><dt class="text-gray-500">CPU</dt><dd>{{ detail.cpuPercent == null ? '-' : detail.cpuPercent + '%' }}</dd></div>
            <div class="flex justify-between"><dt class="text-gray-500">内存</dt><dd>{{ detail.memRssMb == null ? '-' : detail.memRssMb + ' MB' }}</dd></div>
            <div class="flex justify-between"><dt class="text-gray-500">路径</dt><dd class="font-mono text-xs text-right max-w-[200px] truncate" :title="detail.path">{{ detail.path }}</dd></div>
          </dl>
        </div>

        <!-- Git -->
        <div class="bg-white rounded-xl border border-surface-200 p-5 shadow-sm">
          <div class="flex items-center justify-between mb-2">
            <h2 class="font-semibold text-surface-900">Git 状态</h2>
            <span :class="gitInfo.cls" class="text-sm">{{ gitInfo.icon }} {{ gitInfo.text }}</span>
          </div>
          <div v-if="detail.git?.branch" class="text-xs text-gray-400 mb-2">分支：{{ detail.git.branch }} · 领先 {{ detail.git.ahead || 0 }} / 落后 {{ detail.git.behind || 0 }}</div>
          <label class="flex items-center gap-2 text-xs text-gray-500 mb-2">
            <input type="checkbox" v-model="rebase" /> 使用 rebase 模式拉取
          </label>
          <p v-if="detail.git?.dirty" class="text-xs text-amber-600">⚠️ 存在未提交修改，拉取可能冲突或覆盖本地改动。</p>
        </div>

        <!-- Nginx 关联 -->
        <div v-if="detail.nginxLink" class="bg-amber-50 rounded-xl border border-amber-200 p-5 shadow-sm">
          <h2 class="font-semibold text-amber-800 mb-2">🔒 Nginx 端口锁定</h2>
          <div class="text-xs text-amber-700 space-y-1">
            <div>代理端口：<span class="font-mono">{{ detail.nginxLink.proxyPort }}</span></div>
            <div>域名：{{ detail.nginxLink.serverName || '-' }}</div>
            <div class="truncate" :title="detail.nginxLink.configFile">配置：{{ detail.nginxLink.configFile }}</div>
          </div>
          <button v-if="isAdmin" class="mt-3 px-3 py-1.5 rounded-lg bg-amber-600 text-white text-xs hover:bg-amber-700" @click="unlink">解除关联并解锁端口</button>
        </div>
      </div>

      <!-- 右：日志 + 配置 -->
      <div class="lg:col-span-2 space-y-6">
        <!-- 日志 -->
        <div class="bg-white rounded-xl border border-surface-200 p-4 shadow-sm" style="height: 420px; display:flex; flex-direction:column;">
          <div class="flex items-center justify-between mb-2">
            <h2 class="font-semibold text-surface-900">实时日志</h2>
            <span class="text-xs text-gray-400">自动分级着色 · 流式推送</span>
          </div>
          <div class="flex-1 min-h-0">
            <LogViewer :lines="logs" @clear="store.clearLogs(detail.id)" />
          </div>
        </div>

        <!-- 配置 -->
        <div class="bg-white rounded-xl border border-surface-200 p-5 shadow-sm space-y-5">
          <h2 class="font-semibold text-surface-900">项目配置</h2>

          <!-- 显示名 -->
          <div>
            <label class="text-xs text-gray-500">显示名称</label>
            <div class="flex gap-2 mt-1">
              <input v-model="displayName" class="flex-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500" placeholder="自定义展示名" />
              <button :disabled="!isAdmin" class="px-3 py-2 rounded-lg bg-primary-600 text-white text-sm disabled:opacity-40" @click="saveName">保存</button>
            </div>
          </div>

          <!-- 端口 -->
          <div>
            <label class="text-xs text-gray-500">服务端口</label>
            <div class="flex gap-2 mt-1">
              <input v-model="portInput" :disabled="detail.portLocked" type="number" class="flex-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500 disabled:bg-gray-100" :placeholder="detail.portLocked ? '已锁定，请先解除 Nginx 关联' : '端口号'" />
              <button :disabled="!isAdmin || detail.portLocked" class="px-3 py-2 rounded-lg bg-primary-600 text-white text-sm disabled:opacity-40" @click="savePort">保存</button>
            </div>
            <p v-if="detail.portLocked" class="text-xs text-amber-600 mt-1">端口已与 Nginx 反向代理锁定，修改需先解除关联或同步修改 proxy_pass。</p>
          </div>

          <!-- 环境变量 -->
          <div>
            <label class="text-xs text-gray-500">环境变量（每行 KEY=VALUE）</label>
            <textarea v-model="envText" rows="4" :disabled="!isAdmin" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none focus:border-primary-500 disabled:bg-gray-100" placeholder="PORT=3000&#10;NODE_ENV=production"></textarea>
            <button :disabled="!isAdmin" class="mt-2 px-3 py-2 rounded-lg bg-primary-600 text-white text-sm disabled:opacity-40" @click="saveEnv">保存环境变量</button>
          </div>

          <!-- 脚本覆盖 -->
          <div>
            <label class="text-xs text-gray-500">自定义类型与启停脚本（覆盖自动识别）</label>
            <select v-model="customType" :disabled="!isAdmin" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none disabled:bg-gray-100">
              <option value="">（保持自动识别：{{ typeLabel(detail.type) }}）</option>
              <option v-for="t in allTypes" :key="t" :value="t">{{ typeLabel(t) }}</option>
            </select>
            <input v-model="customStart" :disabled="!isAdmin" class="w-full mt-2 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none disabled:bg-gray-100" placeholder="启动命令（shell 片段，如：npm run start）" />
            <input v-model="customStop" :disabled="!isAdmin" class="w-full mt-2 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none disabled:bg-gray-100" placeholder="停止命令（如：停止脚本或留空用 PID 终止）" />
            <input v-model="customBuild" :disabled="!isAdmin" class="w-full mt-2 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none disabled:bg-gray-100" placeholder="编译命令（如：mvn package -DskipTests）" />
            <button :disabled="!isAdmin" class="mt-2 px-3 py-2 rounded-lg bg-primary-600 text-white text-sm disabled:opacity-40" @click="saveScript">保存脚本覆盖</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, inject, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useMonitorStore } from '../../stores/monitor'
import { monitorApi } from '../../api/monitor'
import StatusBadge from '../../components/monitor/StatusBadge.vue'
import LogViewer from '../../components/monitor/LogViewer.vue'
import { typeLabel, gitLabel, formatUptime } from '../../utils/monitorFormat'

const route = useRoute()
const store = useMonitorStore()
const showToast = inject('showToast', () => {})
const id = route.params.id
const isAdmin = computed(() => store.role === 'admin')

const detail = ref(null)
const rebase = ref(false)
const displayName = ref('')
const portInput = ref('')
const envText = ref('')
const customType = ref('')
const customStart = ref('')
const customStop = ref('')
const customBuild = ref('')

const allTypes = ['node', 'vue', 'springboot', 'python', 'go', 'rust', 'php', 'dotnet', 'static', 'shell', 'unknown']
const isGit = computed(() => detail.value?.git?.status && detail.value.git.status !== 'no_repo')
const gitInfo = computed(() => detail.value?.git?.status ? gitLabel(detail.value.git.status) : { text: '-', icon: '', cls: '' })
const logs = computed(() => store.logs[id] || [])

async function load() {
  try { detail.value = await monitorApi.getService(id) } catch (e) { showToast('加载失败: ' + e.message, 'error') }
  if (detail.value) {
    displayName.value = detail.value.name
    portInput.value = detail.value.port || ''
    envText.value = (detail.value.env || []).join('\n')
  }
}

async function doStart() { try { await store.start(id); await load(); showToast('已启动', 'success') } catch (e) { showToast('启动失败: ' + e.message, 'error') } }
async function doStop() { if (!confirm('确认停止？')) return; try { await store.stop(id); await load(); showToast('已停止', 'info') } catch (e) { showToast('停止失败: ' + e.message, 'error') } }
async function doRestart() { if (!confirm('确认重启？')) return; try { await store.restart(id); await load(); showToast('已重启', 'success') } catch (e) { showToast('重启失败: ' + e.message, 'error') } }
async function doPull() { try { await store.pull(id, rebase.value); showToast('拉取完成', 'success'); await load() } catch (e) { showToast('拉取失败: ' + e.message, 'error') } }

async function saveName() { try { await store.setDisplayName(id, displayName.value); showToast('已保存', 'success'); await load() } catch (e) { showToast(e.message, 'error') } }
async function savePort() {
  const p = portInput.value ? Number(portInput.value) : null
  try { await store.setPort(id, p); showToast('端口已保存', 'success'); await load() } catch (e) { showToast('保存失败: ' + e.message, 'error') }
}
async function saveEnv() {
  const env = envText.value.split('\n').map((s) => s.trim()).filter(Boolean)
  try { await store.setEnv(id, env); showToast('环境变量已保存', 'success'); await load() } catch (e) { showToast(e.message, 'error') }
}
async function saveScript() {
  const customScript = customStart.value || customStop.value || customBuild.value
    ? {
        start: customStart.value ? { bin: 'sh', args: ['-c', customStart.value], cwd: detail.value.path } : null,
        stop: customStop.value ? { bin: 'sh', args: ['-c', customStop.value], cwd: detail.value.path } : null,
        build: customBuild.value ? { bin: 'sh', args: ['-c', customBuild.value], cwd: detail.value.path } : null,
      }
    : null
  try { await store.setScript(id, { customScript, typeOverride: customType.value || null }); showToast('脚本覆盖已保存', 'success'); await load() } catch (e) { showToast(e.message, 'error') }
}
async function unlink() {
  if (!detail.value?.nginxLink) return
  if (!confirm('解除 Nginx 关联后将解锁端口，是否继续？')) return
  try { await monitorApi.nginxRemoveLink(detail.value.nginxLink.linkId); showToast('已解除关联', 'success'); await load() } catch (e) { showToast(e.message, 'error') }
}

onMounted(() => {
  store.connect()
  load()
  store.subscribeLog(id)
  // 定时轻量刷新（实时数据主要靠 WS）
  refreshTimer = setInterval(load, 5000)
})
let refreshTimer = null
onUnmounted(() => { store.unsubscribeLog(); if (refreshTimer) clearInterval(refreshTimer) })
</script>
