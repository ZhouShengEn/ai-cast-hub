<template>
  <div class="p-6 max-w-[1400px] mx-auto">
    <div class="flex items-center justify-between mb-5 flex-wrap gap-3">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">Nginx 管理</h1>
        <p class="text-sm text-gray-500 mt-1">配置在线编辑 · 语法校验 · 平滑重载 · 路由端口联动锁定</p>
      </div>
      <div class="flex items-center gap-2">
        <button class="px-3 py-2 rounded-lg bg-primary-600 text-white text-sm hover:bg-primary-700 disabled:opacity-40" :disabled="!isAdmin" @click="doTest">校验语法</button>
        <button class="px-3 py-2 rounded-lg bg-green-600 text-white text-sm hover:bg-green-700 disabled:opacity-40" :disabled="!isAdmin" @click="doReload">平滑重载</button>
        <button class="px-3 py-2 rounded-lg bg-gray-200 text-gray-700 text-sm hover:bg-gray-300 disabled:opacity-40" :disabled="!isAdmin" @click="() => doControl('restart')">重启</button>
      </div>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
      <!-- 配置列表 -->
      <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-3">
        <h2 class="text-sm font-semibold text-surface-900 mb-2 px-1">配置文件</h2>
        <div class="space-y-1 max-h-[600px] overflow-y-auto">
          <button
            v-for="c in configs"
            :key="c.id"
            @click="select(c)"
            class="w-full text-left px-2 py-2 rounded-lg text-xs hover:bg-surface-50"
            :class="selected?.id === c.id ? 'bg-primary-50 text-primary-700' : 'text-gray-600'"
          >
            <div class="font-medium truncate">{{ c.name }}</div>
            <div class="text-[10px] text-gray-400 truncate">{{ c.path }}</div>
          </button>
          <div v-if="!configs.length" class="text-xs text-gray-400 p-2">未扫描到 Nginx 配置</div>
        </div>
      </div>

      <!-- 编辑区 -->
      <div class="lg:col-span-3 space-y-4">
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-4">
          <div class="flex items-center justify-between mb-2">
            <h2 class="font-semibold text-surface-900">{{ selected?.name || '请选择配置文件' }}</h2>
            <span v-if="selected" class="text-[10px] text-gray-400 font-mono truncate max-w-[300px]">{{ selected.path }}</span>
          </div>
          <textarea
            v-model="content"
            :disabled="!isAdmin || !selected"
            rows="16"
            class="w-full px-3 py-2 rounded-lg border border-surface-200 text-xs font-mono outline-none focus:border-primary-500 disabled:bg-gray-100"
            placeholder="选择左侧配置文件以查看 / 编辑"
          ></textarea>
          <div class="flex items-center gap-2 mt-2">
            <button :disabled="!isAdmin || !selected" class="px-4 py-2 rounded-lg bg-green-600 text-white text-sm hover:bg-green-700 disabled:opacity-40" @click="doSave">保存（保存前强制语法校验）</button>
            <span class="text-xs" :class="saveState.cls">{{ saveState.text }}</span>
          </div>
          <pre v-if="testOutput" class="mt-2 text-xs bg-surface-900 text-gray-200 rounded p-3 whitespace-pre-wrap max-h-40 overflow-y-auto">{{ testOutput }}</pre>
        </div>

        <!-- 日志 -->
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-4">
          <div class="flex items-center gap-2 mb-2">
            <h2 class="font-semibold text-surface-900">Nginx 日志</h2>
            <button class="px-2 py-1 rounded text-xs border border-surface-200" :class="logType==='error'?'bg-primary-50 text-primary-700':''" @click="setLog('error')">错误日志</button>
            <button class="px-2 py-1 rounded text-xs border border-surface-200" :class="logType==='access'?'bg-primary-50 text-primary-700':''" @click="setLog('access')">访问日志</button>
            <button class="px-2 py-1 rounded text-xs bg-primary-600 text-white ml-2" @click="loadLogs">刷新</button>
          </div>
          <pre class="text-xs bg-surface-900 text-gray-200 rounded p-3 whitespace-pre-wrap h-48 overflow-y-auto">{{ logContent || '（无日志 / 文件不可读）' }}</pre>
        </div>

        <!-- 端口锁定 -->
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-4">
          <h2 class="font-semibold text-surface-900 mb-2">🔒 路由端口联动锁定</h2>
          <p class="text-xs text-gray-500 mb-3">系统自动解析各 Nginx 配置中的 proxy_pass，将后端端口与业务项目绑定并锁定，防止端口随意修改导致代理失效。</p>
          <div class="space-y-2 mb-3">
            <div v-for="l in links" :key="l.id" class="flex items-center gap-3 text-sm border border-surface-100 rounded-lg p-2">
              <span class="font-mono text-amber-700">:{{ l.proxyPort }}</span>
              <span class="text-gray-500 truncate flex-1" :title="l.configFile">{{ l.serverName || l.configFile }}</span>
              <span v-if="l.projectName" class="text-green-600 text-xs">{{ l.projectName }}</span>
              <span v-else class="text-gray-400 text-xs">未关联项目</span>
              <button :disabled="!isAdmin" class="px-2 py-1 rounded bg-red-500 text-white text-xs disabled:opacity-40" @click="removeLink(l.id)">解除</button>
            </div>
            <div v-if="!links.length" class="text-xs text-gray-400">暂无锁定关联</div>
          </div>
          <div class="flex items-end gap-2 flex-wrap">
            <div class="flex-1 min-w-[140px]">
              <label class="text-[10px] text-gray-500">项目路径</label>
              <input v-model="assoc.projectPath" class="w-full px-2 py-1 rounded border border-surface-200 text-xs" placeholder="/opt/workspace/xxx" />
            </div>
            <div class="w-48">
              <label class="text-[10px] text-gray-500">Nginx 配置</label>
              <select v-model="assoc.configId" class="w-full px-2 py-1 rounded border border-surface-200 text-xs">
                <option value="">选择配置</option>
                <option v-for="c in configs" :key="c.id" :value="c.id">{{ c.name }}</option>
              </select>
            </div>
            <div class="w-24">
              <label class="text-[10px] text-gray-500">端口</label>
              <input v-model="assoc.port" type="number" class="w-full px-2 py-1 rounded border border-surface-200 text-xs" placeholder="8080" />
            </div>
            <button :disabled="!isAdmin" class="px-3 py-1.5 rounded-lg bg-primary-600 text-white text-sm disabled:opacity-40" @click="addLink">手动关联</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, inject } from 'vue'
import { useMonitorStore } from '../../stores/monitor'
import { monitorApi } from '../../api/monitor'

const store = useMonitorStore()
const showToast = inject('showToast', () => {})
const isAdmin = computed(() => store.role === 'admin')

const configs = ref([])
const selected = ref(null)
const content = ref('')
const testOutput = ref('')
const saveState = ref({ text: '', cls: '' })

const logType = ref('error')
const logContent = ref('')
const links = ref([])

const assoc = ref({ projectPath: '', configId: '', port: '' })

async function loadConfigs() {
  try { configs.value = await monitorApi.nginxListConfigs() } catch (e) { showToast('加载配置列表失败', 'error') }
}
async function loadLinks() {
  try { links.value = await monitorApi.nginxLinks() } catch (e) {}
}
async function select(c) {
  selected.value = c
  try {
    const r = await monitorApi.nginxGetConfig(c.id)
    content.value = r.content
  } catch (e) { showToast('读取配置失败: ' + e.message, 'error') }
}
async function doTest() {
  try { const r = await monitorApi.nginxTest(); testOutput.value = r.output; showToast(r.ok ? '语法校验通过' : '校验未通过', r.ok ? 'success' : 'error') } catch (e) { showToast(e.message, 'error') }
}
async function doSave() {
  if (!selected.value) return
  try {
    const r = await monitorApi.nginxSaveConfig(selected.value.id, content.value)
    if (r.ok) { saveState.value = { text: '✅ 保存成功', cls: 'text-green-600' }; showToast('保存成功', 'success'); await loadLinks() }
    else { saveState.value = { text: '❌ ' + (r.error || '校验失败'), cls: 'text-red-600' }; testOutput.value = r.testOutput; showToast('保存被拒绝：语法校验未通过', 'error') }
  } catch (e) { showToast(e.message, 'error') }
}
async function doReload() { try { const r = await monitorApi.nginxReload(); showToast(r.message || (r.ok ? '已重载' : '重载失败'), r.ok ? 'success' : 'error') } catch (e) { showToast(e.message, 'error') } }
async function doControl(action) { if (!confirm(`确认${action} Nginx？`)) return; try { const r = await monitorApi.nginxControl(action); showToast(r.message || action, r.ok ? 'info' : 'error') } catch (e) { showToast(e.message, 'error') } }
async function setLog(t) { logType.value = t; await loadLogs() }
async function loadLogs() { try { const r = await monitorApi.nginxLogs(logType.value, 200); logContent.value = r.content || '' } catch (e) { logContent.value = '' } }
async function addLink() {
  if (!assoc.value.projectPath || !assoc.value.configId || !assoc.value.port) return showToast('请填写完整关联信息', 'warning')
  try { await monitorApi.nginxSetLink({ ...assoc.value }); showToast('关联成功', 'success'); await loadLinks() } catch (e) { showToast(e.message, 'error') }
}
async function removeLink(linkId) { if (!confirm('确认解除该端口锁定关联？')) return; try { await monitorApi.nginxRemoveLink(linkId); showToast('已解除', 'info'); await loadLinks() } catch (e) { showToast(e.message, 'error') } }

onMounted(() => { store.connect(); loadConfigs(); loadLinks(); loadLogs() })
</script>
