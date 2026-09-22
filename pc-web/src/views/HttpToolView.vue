<template>
  <div class="p-4 md:p-6 max-w-[1500px] mx-auto">
    <!-- ==================== 头部 ==================== -->
    <div class="flex flex-wrap items-end justify-between gap-3 mb-5">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">HTTP 接口调试</h1>
        <p class="text-sm text-gray-500 mt-1">
          简易接口调试工具 · 请求记录保存在浏览器本地（localStorage），清空浏览器数据会丢失
        </p>
      </div>
      <div class="flex items-center gap-2">
        <span class="text-xs text-gray-400">已保存 {{ records.length }} 条记录</span>
        <button
          type="button"
          class="px-3 py-2 rounded-lg border border-surface-200 text-sm text-gray-600 hover:bg-surface-100 disabled:opacity-40 disabled:cursor-not-allowed"
          :disabled="!records.length"
          @click="clearAll"
        >
          清空记录
        </button>
      </div>
    </div>

    <div class="flex flex-col xl:flex-row gap-5">
      <!-- ==================== 左：请求配置 ==================== -->
      <section class="w-full xl:w-[460px] shrink-0 space-y-4">
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-5 space-y-4">
          <h2 class="font-semibold text-surface-900">请求配置</h2>

          <!-- 请求名称 -->
          <div>
            <label class="text-xs text-gray-500">请求名称（留空自动按 URL 生成）</label>
            <input
              v-model="name"
              class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500"
              placeholder="例如：获取设备列表"
            />
          </div>

          <!-- 方法 + URL -->
          <div>
            <label class="text-xs text-gray-500">请求地址 URL</label>
            <div class="flex gap-2 mt-1">
              <select
                v-model="method"
                class="px-2 py-2 rounded-lg border border-surface-200 text-sm font-semibold outline-none focus:border-primary-500"
                :class="methodClass(method)"
              >
                <option v-for="m in METHODS" :key="m" :value="m">{{ m }}</option>
              </select>
              <input
                v-model="url"
                class="flex-1 min-w-0 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none focus:border-primary-500"
                placeholder="/api/v1/health 或 http://host:3000/api/v1/health"
                @keydown.enter="sendRequest()"
              />
            </div>
            <div class="flex flex-wrap gap-1.5 mt-2">
              <button
                v-for="s in urlSuggestions"
                :key="s"
                type="button"
                class="px-2 py-0.5 rounded-full bg-surface-100 text-[11px] text-gray-600 hover:bg-surface-200 font-mono"
                @click="url = s"
              >
                {{ s }}
              </button>
            </div>
          </div>

          <!-- 超时 -->
          <div class="flex items-center gap-3">
            <label class="text-xs text-gray-500 shrink-0">超时时间（秒）</label>
            <input
              v-model.number="timeoutSec"
              type="number"
              min="1"
              max="300"
              class="w-24 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500"
            />
            <span class="text-[11px] text-gray-400">默认 10 秒，超时将提示错误</span>
          </div>

          <!-- Headers -->
          <div>
            <div class="flex items-center justify-between">
              <label class="text-xs text-gray-500">请求头 Headers</label>
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="text-[11px] text-primary-600 hover:underline"
                  @click="addAuthHeaders"
                >
                  添加设备认证头
                </button>
                <button
                  type="button"
                  class="text-[11px] text-primary-600 hover:underline"
                  @click="addHeaderRow"
                >
                  + 新增一行
                </button>
              </div>
            </div>

            <div class="mt-2 space-y-2">
              <div v-for="(h, i) in headers" :key="i" class="flex items-center gap-2">
                <input
                  v-model="h.key"
                  list="http-header-keys"
                  class="flex-1 min-w-0 px-2 py-1.5 rounded-lg border border-surface-200 text-xs font-mono outline-none focus:border-primary-500"
                  placeholder="Header 名称"
                />
                <input
                  v-model="h.value"
                  list="http-header-values"
                  class="flex-1 min-w-0 px-2 py-1.5 rounded-lg border border-surface-200 text-xs font-mono outline-none focus:border-primary-500"
                  placeholder="值"
                />
                <button
                  type="button"
                  class="shrink-0 w-7 h-7 rounded-lg text-gray-400 hover:text-red-500 hover:bg-red-50"
                  title="删除该行"
                  @click="removeHeaderRow(i)"
                >
                  ✕
                </button>
              </div>
              <div v-if="!headers.length" class="text-[11px] text-gray-400">暂无请求头</div>
            </div>

            <datalist id="http-header-keys">
              <option v-for="k in COMMON_HEADERS" :key="k" :value="k"></option>
            </datalist>
            <datalist id="http-header-values">
              <option v-for="v in COMMON_HEADER_VALUES" :key="v" :value="v"></option>
            </datalist>
          </div>

          <!-- Body -->
          <div>
            <div class="flex items-center justify-between">
              <label class="text-xs text-gray-500">请求体 Body（JSON 文本）</label>
              <span v-if="bodyDisabled" class="text-[11px] text-gray-400">
                {{ method }} 请求不发送 Body
              </span>
            </div>
            <textarea
              v-model="body"
              rows="8"
              spellcheck="false"
              class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-xs font-mono leading-relaxed outline-none focus:border-primary-500 resize-y"
              placeholder='{"key": "value"}'
            ></textarea>
          </div>

          <!-- 操作 -->
          <div class="flex items-center gap-2 pt-1">
            <button
              type="button"
              class="flex-1 px-4 py-2.5 rounded-lg bg-primary-600 text-white text-sm font-medium hover:bg-primary-700 disabled:bg-gray-300 disabled:cursor-not-allowed flex items-center justify-center gap-2"
              :disabled="sending"
              @click="sendRequest()"
            >
              <span
                v-if="sending"
                class="w-4 h-4 border-2 border-white/40 border-t-white rounded-full animate-spin"
              ></span>
              {{ sending ? '请求中…' : '发送请求' }}
            </button>
            <button
              type="button"
              class="px-4 py-2.5 rounded-lg border border-primary-500 text-primary-600 text-sm font-medium hover:bg-primary-50 disabled:opacity-40 disabled:cursor-not-allowed"
              :disabled="sending || !canResend"
              :title="canResend ? '用当前记录/表单参数直接再发一次' : '暂无可重发的请求'"
              @click="resend"
            >
              一键重发
            </button>
          </div>
        </div>
      </section>

      <!-- ==================== 右：响应 + 记录 ==================== -->
      <section class="flex-1 min-w-0 space-y-4">
        <!-- 响应结果 -->
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-5">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="font-semibold text-surface-900">响应结果</h2>
            <div v-if="response" class="flex items-center gap-3 text-xs">
              <span
                class="px-2 py-0.5 rounded-full font-bold"
                :class="response.error ? 'bg-red-100 text-red-600' : statusBadgeClass(response.status)"
              >
                {{ response.error ? '请求失败' : `${response.status} ${response.statusText || ''}` }}
              </span>
              <span class="text-gray-500">耗时 {{ response.duration }} ms</span>
            </div>
          </div>

          <!-- 空状态 -->
          <div v-if="!response" class="mt-4 py-10 text-center text-sm text-gray-400">
            还没有响应，填写请求配置后点击「发送请求」
          </div>

          <div v-else class="mt-4 space-y-3">
            <!-- 错误提示 -->
            <div
              v-if="response.error"
              class="px-3 py-2 rounded-lg bg-red-50 border border-red-200 text-xs text-red-600 break-all"
            >
              {{ response.error }}
            </div>

            <!-- 响应头 -->
            <div v-if="response.responseHeaders.length" class="border border-surface-200 rounded-lg">
              <button
                type="button"
                class="w-full flex items-center justify-between px-3 py-2 text-xs font-medium text-gray-600 hover:bg-surface-50"
                @click="headersExpanded = !headersExpanded"
              >
                <span>响应头（{{ response.responseHeaders.length }}）</span>
                <span>{{ headersExpanded ? '收起 ▲' : '展开 ▼' }}</span>
              </button>
              <div v-show="headersExpanded" class="px-3 pb-3 space-y-1">
                <div
                  v-for="h in response.responseHeaders"
                  :key="h.key"
                  class="text-[11px] font-mono break-all"
                >
                  <span class="text-sky-700">{{ h.key }}</span>
                  <span class="text-gray-400">: </span>
                  <span class="text-gray-700">{{ h.value }}</span>
                </div>
              </div>
            </div>

            <!-- 响应体 -->
            <div class="border border-surface-200 rounded-lg overflow-hidden">
              <div class="flex items-center justify-between px-3 py-2 bg-surface-50">
                <div class="flex items-center gap-2 text-xs font-medium text-gray-600">
                  <span>响应体</span>
                  <span
                    class="px-1.5 py-0.5 rounded text-[10px]"
                    :class="response.isJson ? 'bg-emerald-100 text-emerald-700' : 'bg-gray-200 text-gray-600'"
                  >
                    {{ response.isJson ? 'JSON' : '文本' }}
                  </span>
                  <span v-if="response.isJson" class="text-[10px] text-gray-400">已自动格式化高亮</span>
                </div>
                <div class="flex items-center gap-3">
                  <button
                    type="button"
                    class="text-[11px] text-primary-600 hover:underline"
                    @click="copyResponseBody"
                  >
                    复制
                  </button>
                  <button
                    type="button"
                    class="text-[11px] text-primary-600 hover:underline"
                    @click="bodyExpanded = !bodyExpanded"
                  >
                    {{ bodyExpanded ? '折叠 ▲' : '展开 ▼' }}
                  </button>
                </div>
              </div>
              <pre
                v-show="bodyExpanded"
                class="m-0 px-3 py-3 bg-surface-900 text-gray-100 text-xs font-mono leading-relaxed overflow-auto max-h-[520px] whitespace-pre-wrap break-all"
                v-html="highlightedBody"
              ></pre>
            </div>
          </div>
        </div>

        <!-- 请求记录 -->
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-5">
          <div class="flex items-center justify-between">
            <h2 class="font-semibold text-surface-900">请求记录</h2>
            <div class="flex items-center gap-2">
              <span class="text-xs text-gray-400">点击记录可回填配置与上次响应</span>
              <button
                type="button"
                class="text-xs text-red-500 hover:underline disabled:opacity-40"
                :disabled="!records.length"
                @click="clearAll"
              >
                批量清空
              </button>
            </div>
          </div>

          <div v-if="!records.length" class="py-8 text-center text-sm text-gray-400">
            暂无请求记录
          </div>

          <div v-else class="mt-3 divide-y divide-surface-100 max-h-[420px] overflow-y-auto">
            <div
              v-for="rec in records"
              :key="rec.id"
              class="flex items-center gap-3 py-2.5 cursor-pointer hover:bg-surface-50 rounded-lg px-2 -mx-2 transition-colors"
              :class="rec.id === activeRecordId ? 'bg-primary-50' : ''"
              @click="applyRecord(rec)"
            >
              <span
                class="shrink-0 px-2 py-0.5 rounded text-[10px] font-bold w-14 text-center"
                :class="methodClass(rec.method)"
              >
                {{ rec.method }}
              </span>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2">
                  <span class="text-sm font-medium text-surface-900 truncate">{{ rec.name }}</span>
                  <span
                    class="shrink-0 text-[10px] font-bold"
                    :class="rec.error ? 'text-red-500' : statusTextClass(rec.status)"
                  >
                    {{ rec.error ? '失败' : (rec.status ?? '-') }}
                  </span>
                </div>
                <div class="text-[11px] text-gray-500 font-mono truncate">{{ rec.url }}</div>
                <div class="text-[10px] text-gray-400">
                  {{ fmtTime(rec.createdAt) }} · {{ rec.duration }} ms
                </div>
              </div>
              <button
                type="button"
                class="shrink-0 w-7 h-7 rounded-lg text-gray-400 hover:text-red-500 hover:bg-red-50"
                title="删除该记录"
                @click.stop="deleteRecord(rec.id)"
              >
                ✕
              </button>
            </div>
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, inject, onMounted, ref } from 'vue'
import axios from 'axios'

const showToast = inject('showToast', () => {})

/** localStorage 持久化 key */
const STORAGE_KEY = 'httpToolRecords'
/** 最多保留的记录条数 */
const MAX_RECORDS = 100

const METHODS = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH']

/** 常见请求头名称（供 datalist 提示） */
const COMMON_HEADERS = [
  'Accept',
  'Authorization',
  'Cache-Control',
  'Content-Type',
  'X-Device-UUID',
  'X-Transfer-Key',
  'X-Requested-With',
]

/** 常见请求头取值（供 datalist 提示） */
const COMMON_HEADER_VALUES = [
  'application/json',
  'application/x-www-form-urlencoded',
  'text/plain',
  'multipart/form-data',
  'application/json; charset=utf-8',
  'Bearer ',
  'no-cache',
]

/** 数据字典 */
const DEFAULT_TIMEOUT_SEC = 10

// ============================================================
// 表单状态
// ============================================================
const name = ref('')
const method = ref('GET')
const url = ref('')
const timeoutSec = ref(DEFAULT_TIMEOUT_SEC)
const headers = ref([{ key: '', value: '' }])
const body = ref('')

const sending = ref(false)
const response = ref(null)
const records = ref([])
const activeRecordId = ref(null)

const bodyExpanded = ref(true)
const headersExpanded = ref(false)

// ============================================================
// 计算属性
// ============================================================
/** GET / HEAD 不携带请求体 */
const bodyDisabled = computed(() => method.value === 'GET' || method.value === 'HEAD')

/** URL 快捷填充建议（同源 /api/v1，配合 vite 代理可直接调本机服务） */
const urlSuggestions = computed(() => [
  '/api/v1/health',
  '/api/v1/server/info',
  `${location.origin}/api/v1/health`,
])

/** 是否可一键重发：选中了记录，或表单里已有地址 */
const canResend = computed(() => Boolean(activeRecordId.value) || Boolean(url.value.trim()))

/** 响应体高亮后的 HTML（JSON 格式化高亮；非 JSON 原样展示） */
const highlightedBody = computed(() => {
  if (!response.value) return ''
  const raw = response.value.body ?? ''
  if (!response.value.isJson) return escapeHtml(raw)
  return highlightJson(raw)
})

// ============================================================
// 记录持久化（localStorage）
// ============================================================
function loadRecords() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    records.value = raw ? JSON.parse(raw) : []
  } catch (_) {
    records.value = []
  }
}

function persistRecords() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(records.value.slice(0, MAX_RECORDS)))
  } catch (e) {
    console.warn('[HttpTool] 保存请求记录失败:', e)
  }
}

function deleteRecord(id) {
  records.value = records.value.filter((r) => r.id !== id)
  if (activeRecordId.value === id) activeRecordId.value = null
  persistRecords()
}

function clearAll() {
  if (!records.value.length) return
  if (!window.confirm(`确认清空全部 ${records.value.length} 条请求记录？此操作不可恢复。`)) return
  records.value = []
  activeRecordId.value = null
  persistRecords()
  showToast('请求记录已清空', 'success')
}

// ============================================================
// Headers 行操作
// ============================================================
function addHeaderRow() {
  headers.value.push({ key: '', value: '' })
}

function removeHeaderRow(index) {
  headers.value.splice(index, 1)
  if (!headers.value.length) addHeaderRow()
}

/** 快速填入本机设备认证头（与 api/client.js 的注入规则一致） */
function addAuthHeaders() {
  const deviceUuid = localStorage.getItem('deviceUuid')
  const transferKey = localStorage.getItem('transferKey')
  if (!deviceUuid && !transferKey) {
    showToast('本机尚未注册设备（无 deviceUuid / transferKey）', 'warning')
    return
  }
  upsertHeader('X-Device-UUID', deviceUuid || '')
  upsertHeader('X-Transfer-Key', transferKey || '')
  showToast('已填入设备认证请求头', 'success')
}

function upsertHeader(key, value) {
  const found = headers.value.find((h) => h.key.trim().toLowerCase() === key.toLowerCase())
  if (found) {
    found.value = value
  } else {
    const empty = headers.value.find((h) => !h.key.trim())
    if (empty) {
      empty.key = key
      empty.value = value
    } else {
      headers.value.push({ key, value })
    }
  }
}

// ============================================================
// 发送请求
// ============================================================
/**
 * 发送请求
 * @param {object} opts
 * @param {string|null} opts.updateId 命中记录时原地更新该记录（用于「一键重发」）
 */
async function sendRequest({ updateId = null } = {}) {
  if (sending.value) return

  const target = url.value.trim()
  if (!target) {
    showToast('请先填写请求地址 URL', 'warning')
    return
  }

  sending.value = true
  const displayName = name.value.trim() || buildDefaultName(method.value, target)
  const timeoutMs = (Number(timeoutSec.value) || DEFAULT_TIMEOUT_SEC) * 1000
  const headerMap = buildHeaderMap()
  const startedAt = Date.now()

  let result
  try {
    const res = await axios.request({
      url: target,
      method: method.value,
      headers: headerMap,
      data: buildRequestBody(),
      timeout: timeoutMs,
      validateStatus: () => true,
    })
    const rawBody = normalizeBody(res.data)
    result = {
      status: res.status,
      statusText: res.statusText || '',
      duration: Date.now() - startedAt,
      responseHeaders: normalizeHeaders(res.headers),
      body: rawBody,
      isJson: isJsonText(rawBody),
      error: null,
    }
  } catch (e) {
    result = {
      status: null,
      statusText: '',
      duration: Date.now() - startedAt,
      responseHeaders: [],
      body: '',
      isJson: false,
      error: buildErrorMessage(e, Number(timeoutSec.value) || DEFAULT_TIMEOUT_SEC),
    }
  }

  response.value = result
  sending.value = false
  bodyExpanded.value = true

  saveRecord({ displayName, target, timeoutMs, result, updateId })

  if (result.error) {
    showToast(result.error, 'error')
  } else if (result.status >= 400) {
    showToast(`请求完成，服务端返回 ${result.status}`, 'warning')
  } else {
    showToast(`请求成功（${result.status}，${result.duration}ms）`, 'success')
  }
}

/** 一键重发：优先复用当前选中记录的全部参数，其次复用当前表单 */
async function resend() {
  if (sending.value) return
  const rec = records.value.find((r) => r.id === activeRecordId.value)
  if (rec) {
    applyRecord(rec)
    await sendRequest({ updateId: rec.id })
    return
  }
  if (!url.value.trim()) {
    showToast('请先填写请求地址 URL', 'warning')
    return
  }
  await sendRequest()
}

/** 组装请求头对象（跳过空 key） */
function buildHeaderMap() {
  const map = {}
  for (const h of headers.value) {
    const key = (h.key || '').trim()
    if (key) map[key] = h.value ?? ''
  }
  return map
}

/** 组装请求体：仅在非 GET/HEAD 且内容非空时发送；JSON 优先解析为对象 */
function buildRequestBody() {
  if (bodyDisabled.value) return undefined
  const text = body.value.trim()
  if (!text) return undefined
  try {
    return JSON.parse(text)
  } catch (_) {
    return text
  }
}

/** 根据 URL 生成默认记录名 */
function buildDefaultName(m, target) {
  try {
    const u = new URL(target, location.origin)
    return `${m} ${u.pathname}`
  } catch (_) {
    return `${m} ${target}`
  }
}

/** 友好化错误提示 */
function buildErrorMessage(error, timeoutSecValue) {
  const code = error?.code
  if (code === 'ECONNABORTED' || /timeout/i.test(error?.message || '')) {
    return `请求超时：超过 ${timeoutSecValue} 秒未收到响应`
  }
  if (code === 'ERR_NETWORK' || code === 'ECONNREFUSED') {
    return `网络错误：无法连接到目标地址（可能是服务未启动、地址错误或被浏览器 CORS 拦截）`
  }
  return error?.message || '请求失败'
}

/** 统一响应头为 [{key, value}]，便于持久化与渲染 */
function normalizeHeaders(raw) {
  if (!raw) return []
  const source = typeof raw.toJSON === 'function' ? raw.toJSON() : raw
  return Object.keys(source).map((k) => ({ key: k, value: String(source[k]) }))
}

/** 把响应数据统一转为可展示文本（JSON 自动缩进 2 空格） */
function normalizeBody(data) {
  if (data === null || data === undefined) return ''
  if (typeof data === 'string') {
    const trimmed = data.trim()
    if (!trimmed) return ''
    try {
      return JSON.stringify(JSON.parse(trimmed), null, 2)
    } catch (_) {
      return data
    }
  }
  try {
    return JSON.stringify(data, null, 2)
  } catch (_) {
    return String(data)
  }
}

function isJsonText(text) {
  if (!text) return false
  const trimmed = text.trim()
  if (!/^[[{]/.test(trimmed)) return false
  try {
    JSON.parse(trimmed)
    return true
  } catch (_) {
    return false
  }
}

// ============================================================
// 记录读写
// ============================================================
function saveRecord({ displayName, target, timeoutMs, result, updateId }) {
  const payload = {
    id: updateId || `req_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    name: displayName,
    method: method.value,
    url: target,
    timeoutSec: timeoutMs / 1000,
    headers: headers.value.map((h) => ({ key: h.key, value: h.value })),
    body: body.value,
    status: result.status,
    statusText: result.statusText,
    duration: result.duration,
    responseHeaders: result.responseHeaders,
    responseBody: result.body,
    isJson: result.isJson,
    error: result.error,
    createdAt: new Date().toISOString(),
  }

  if (updateId) {
    const idx = records.value.findIndex((r) => r.id === updateId)
    if (idx !== -1) {
      records.value.splice(idx, 1, payload)
    } else {
      records.value.unshift(payload)
    }
  } else {
    records.value.unshift(payload)
  }

  activeRecordId.value = payload.id
  if (records.value.length > MAX_RECORDS) {
    records.value = records.value.slice(0, MAX_RECORDS)
  }
  persistRecords()
}

/** 点击历史记录：回填全部配置，并展示上次响应 */
function applyRecord(rec) {
  name.value = rec.name || ''
  method.value = rec.method || 'GET'
  url.value = rec.url || ''
  timeoutSec.value = rec.timeoutSec || DEFAULT_TIMEOUT_SEC
  body.value = rec.body || ''
  headers.value = (rec.headers && rec.headers.length)
    ? rec.headers.map((h) => ({ key: h.key || '', value: h.value || '' }))
    : [{ key: '', value: '' }]

  activeRecordId.value = rec.id
  response.value = {
    status: rec.status,
    statusText: rec.statusText || '',
    duration: rec.duration || 0,
    responseHeaders: rec.responseHeaders || [],
    body: rec.responseBody || '',
    isJson: Boolean(rec.isJson),
    error: rec.error || null,
  }
  headersExpanded.value = false
  bodyExpanded.value = true
}

async function copyResponseBody() {
  const text = response.value?.body || ''
  if (!text) return
  try {
    await navigator.clipboard.writeText(text)
    showToast('响应体已复制', 'success')
  } catch (_) {
    showToast('复制失败，请手动选择复制', 'error')
  }
}

// ============================================================
// 展示辅助
// ============================================================
function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

/** JSON 语法高亮：key / string / number / boolean / null 分色 */
const JSON_TOKEN_RE = /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)/g

function highlightJson(text) {
  return escapeHtml(text).replace(JSON_TOKEN_RE, (match) => {
    let cls = 'text-lime-300'
    if (/^"/.test(match)) {
      cls = /:$/.test(match) ? 'text-sky-300' : 'text-amber-300'
    } else if (/^(true|false)$/.test(match)) {
      cls = 'text-purple-300'
    } else if (match === 'null') {
      cls = 'text-gray-500'
    }
    return `<span class="${cls}">${match}</span>`
  })
}

/** 请求方法配色 */
function methodClass(m) {
  switch ((m || '').toUpperCase()) {
    case 'GET':
      return 'text-emerald-600 bg-emerald-50 border-emerald-200'
    case 'POST':
      return 'text-blue-600 bg-blue-50 border-blue-200'
    case 'PUT':
      return 'text-amber-600 bg-amber-50 border-amber-200'
    case 'DELETE':
      return 'text-red-600 bg-red-50 border-red-200'
    case 'PATCH':
      return 'text-purple-600 bg-purple-50 border-purple-200'
    default:
      return 'text-gray-600 bg-gray-50 border-gray-200'
  }
}

/** 状态码徽标配色 */
function statusBadgeClass(status) {
  if (status >= 200 && status < 400) return 'bg-emerald-100 text-emerald-700'
  return 'bg-red-100 text-red-600'
}

function statusTextClass(status) {
  if (status >= 200 && status < 400) return 'text-emerald-600'
  return 'text-red-500'
}

function fmtTime(iso) {
  if (!iso) return '-'
  const d = new Date(iso)
  const pad = (n) => String(n).padStart(2, '0')
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

onMounted(() => {
  loadRecords()
  // 默认填入当前站点健康检查地址，方便直接试跑
  url.value = '/api/v1/health'
})
</script>
