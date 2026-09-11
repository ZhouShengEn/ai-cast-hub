<template>
  <div class="p-6 max-w-[1000px] mx-auto">
    <div class="flex items-center justify-between mb-5">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">监控设置</h1>
        <p class="text-sm text-gray-500 mt-1">扫描规则 · 权限 · 安全参数（修改后持久化，重启不丢失）</p>
      </div>
      <button class="px-4 py-2 rounded-lg bg-primary-600 text-white text-sm hover:bg-primary-700" :disabled="!isAdmin || saving" @click="save">保存配置</button>
    </div>

    <div v-if="!store.config || Object.keys(store.config).length === 0" class="text-gray-400">加载中…</div>

    <div v-else class="space-y-6">
      <!-- 扫描规则 -->
      <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-5 space-y-4">
        <h2 class="font-semibold text-surface-900">扫描规则</h2>
        <div>
          <label class="text-xs text-gray-500">扫描根目录</label>
          <input v-model="cfg.scanRoot" :disabled="!isAdmin" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500 disabled:bg-gray-100" />
          <p class="text-[10px] text-gray-400 mt-1">所有操作严格锁定在此目录内，禁止越权访问系统目录。</p>
        </div>
        <div>
          <label class="text-xs text-gray-500">递归扫描深度（默认 1 级，防止无限递归卡死服务器）</label>
          <input v-model.number="cfg.maxDepth" type="number" min="0" max="5" :disabled="!isAdmin" class="w-32 mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none disabled:bg-gray-100" />
        </div>
        <div>
          <label class="text-xs text-gray-500">忽略项目目录（每行一个绝对路径）</label>
          <textarea v-model="ignoreText" :disabled="!isAdmin" rows="3" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none disabled:bg-gray-100"></textarea>
        </div>
      </div>

      <!-- Nginx -->
      <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-5 space-y-3">
        <h2 class="font-semibold text-surface-900">Nginx</h2>
        <label class="flex items-center gap-2 text-sm">
          <input type="checkbox" v-model="cfg.useSystemNginx" :disabled="!isAdmin" /> 加载系统全局 Nginx（/etc/nginx）
          <span class="text-[10px] text-gray-400">默认关闭，防止误操作影响整机服务</span>
        </label>
        <div>
          <label class="text-xs text-gray-500">额外 Nginx 配置目录（每行一个）</label>
          <textarea v-model="nginxDirText" :disabled="!isAdmin" rows="2" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none disabled:bg-gray-100"></textarea>
        </div>
      </div>

      <!-- 安全 / 性能 -->
      <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-5 space-y-3">
        <h2 class="font-semibold text-surface-900">安全与性能</h2>
        <label class="flex items-center gap-2 text-sm">
          <input type="checkbox" v-model="cfg.enablePermission" :disabled="!isAdmin" /> 启用细粒度权限控制（关闭时全部为管理员）
        </label>
        <label class="flex items-center gap-2 text-sm">
          <input type="checkbox" v-model="cfg.enableAlertPush" :disabled="!isAdmin" /> 将告警推送到绑定的安卓 App
        </label>
        <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
          <div><label class="text-xs text-gray-500">轮询兜底间隔(ms)</label><input v-model.number="cfg.pollIntervalMs" type="number" :disabled="!isAdmin" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm" /></div>
          <div><label class="text-xs text-gray-500">实时刷新间隔(ms)</label><input v-model.number="cfg.refreshIntervalMs" type="number" :disabled="!isAdmin" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm" /></div>
          <div><label class="text-xs text-gray-500">命令超时(s)</label><input v-model.number="cfg.commandTimeoutSec" type="number" :disabled="!isAdmin" class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm" /></div>
        </div>
      </div>

      <!-- 权限角色 -->
      <div v-if="cfg.enablePermission" class="bg-white rounded-xl border border-surface-200 shadow-sm p-5 space-y-3">
        <h2 class="font-semibold text-surface-900">权限角色</h2>
        <div class="space-y-2">
          <div v-for="(role, uuid) in cfg.roles" :key="uuid" class="flex items-center gap-2 text-sm">
            <span class="font-mono text-xs w-48 truncate" :title="uuid">{{ uuid }}</span>
            <select v-model="cfg.roles[uuid]" :disabled="!isAdmin" class="px-2 py-1 rounded border border-surface-200 text-xs">
              <option value="admin">管理员</option>
              <option value="readonly">只读</option>
            </select>
          </div>
          <div v-if="!Object.keys(cfg.roles).length" class="text-xs text-gray-400">暂无角色配置</div>
        </div>
        <div class="flex items-end gap-2 pt-2 border-t border-surface-100">
          <input v-model="newRole.uuid" placeholder="设备 UUID" class="flex-1 px-2 py-1 rounded border border-surface-200 text-xs" />
          <select v-model="newRole.role" class="px-2 py-1 rounded border border-surface-200 text-xs">
            <option value="admin">管理员</option>
            <option value="readonly">只读</option>
          </select>
          <button :disabled="!isAdmin" class="px-3 py-1.5 rounded-lg bg-primary-600 text-white text-xs disabled:opacity-40" @click="addRole">添加</button>
        </div>
      </div>

      <div class="text-xs text-gray-400">所有配置保存至服务端 JSON 文件，重启服务后自动加载。</div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, inject, watch } from 'vue'
import { useMonitorStore } from '../../stores/monitor'

const store = useMonitorStore()
const showToast = inject('showToast', () => {})
const isAdmin = computed(() => store.role === 'admin')
const saving = ref(false)

const cfg = ref({})
const ignoreText = ref('')
const nginxDirText = ref('')
const newRole = ref({ uuid: '', role: 'readonly' })

// 深拷贝配置到本地可编辑副本
function syncFromStore() {
  cfg.value = JSON.parse(JSON.stringify(store.config || {}))
  ignoreText.value = (cfg.value.ignoreList || []).join('\n')
  nginxDirText.value = (cfg.value.nginxConfigDirs || []).join('\n')
}

watch(() => store.config, (v) => { if (v && Object.keys(v).length) syncFromStore() }, { immediate: true })

function addRole() {
  if (!newRole.value.uuid) return
  cfg.value.roles = cfg.value.roles || {}
  cfg.value.roles[newRole.value.uuid] = newRole.value.role
  newRole.value.uuid = ''
}

async function save() {
  saving.value = true
  try {
    const patch = {
      ...cfg.value,
      ignoreList: ignoreText.value.split('\n').map((s) => s.trim()).filter(Boolean),
      nginxConfigDirs: nginxDirText.value.split('\n').map((s) => s.trim()).filter(Boolean),
    }
    await store.updateConfig(patch)
    showToast('配置已保存', 'success')
  } catch (e) {
    showToast('保存失败: ' + e.message, 'error')
  } finally {
    saving.value = false
  }
}

onMounted(async () => {
  store.connect()
  if (!Object.keys(store.config).length) {
    try { await store.getConfig() } catch (e) { showToast('加载配置失败', 'error') }
  }
  syncFromStore()
})
</script>
