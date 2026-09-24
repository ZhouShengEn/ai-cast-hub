<template>
  <div class="p-4 md:p-6">
    <!-- ==================== 头部 ==================== -->
    <div class="flex flex-wrap items-end justify-between gap-3 mb-4">
      <div>
        <h1 class="text-2xl font-bold text-surface-900">HTTP 接口调试</h1>
        <p class="text-sm text-gray-500 mt-1">
          接口列表与请求记录保存在服务端（全局共享），换设备登录后可读取同一份数据
        </p>
      </div>
      <div class="text-xs text-gray-400">
        接口 {{ apis.length }} 个 · 记录 {{ records.length }} 条
      </div>
    </div>

    <div class="flex flex-col xl:flex-row gap-4">
      <!-- ==================== 左栏：接口列表 ==================== -->
      <aside class="w-full xl:w-[320px] shrink-0">
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm flex flex-col">
          <div class="flex items-center justify-between px-4 py-3 border-b border-surface-100">
            <h2 class="font-semibold text-surface-900">接口列表</h2>
            <button
              type="button"
              class="text-xs px-2 py-1 rounded-lg bg-primary-600 text-white hover:bg-primary-700"
              @click="startNewApi"
            >
              + 新增接口
            </button>
          </div>

          <div v-if="!apis.length" class="px-4 py-8 text-center text-sm text-gray-400">
            暂无接口<br />
            <span class="text-xs">在中间填写参数后点「保存」即可存入这里</span>
          </div>

          <div v-else class="p-2 max-h-[560px] overflow-y-auto">
            <div
              v-for="api in apis"
              :key="api.id"
              class="group px-2 py-2 rounded-lg cursor-pointer transition-colors"
              :class="api.id === form.id ? 'bg-primary-50 ring-1 ring-primary-200' : 'hover:bg-surface-50'"
              @click="selectApi(api)"
            >
              <div class="flex items-start gap-2">
                <span
                  class="shrink-0 mt-0.5 px-1.5 py-0.5 rounded text-[10px] font-bold"
                  :class="methodClass(api.method)"
                >
                  {{ api.method }}
                </span>

                <div class="flex-1 min-w-0">
                  <!-- 行内重命名 -->
                  <input
                    v-if="renamingId === api.id"
                    v-model="renamingName"
                    data-rename-input
                    class="w-full px-1 py-0.5 text-xs rounded border border-primary-400 outline-none"
                    @click.stop
                    @keydown.enter="commitRename(api)"
                    @keydown.esc="renamingId = null"
                    @blur="commitRename(api)"
                  />
                  <div v-else class="text-sm font-medium text-surface-900 truncate">
                    {{ api.name }}
                  </div>
                  <div class="text-[11px] text-gray-500 font-mono truncate">{{ api.url }}</div>
                </div>

                <div class="shrink-0 flex items-center gap-0.5 opacity-0 group-hover:opacity-100">
                  <button
                    type="button"
                    class="w-6 h-6 rounded text-gray-400 hover:text-primary-600 hover:bg-white"
                    title="重命名"
                    @click.stop="beginRename(api)"
                  >
                    ✎
                  </button>
                  <button
                    type="button"
                    class="w-6 h-6 rounded text-gray-400 hover:text-red-500 hover:bg-white"
                    title="删除接口"
                    @click.stop="removeApi(api)"
                  >
                    ✕
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </aside>

      <!-- ==================== 中栏：接口请求 ==================== -->
      <section class="flex-1 min-w-0 space-y-4">
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-4 md:p-5 space-y-4">
          <div class="flex items-center justify-between">
            <h2 class="font-semibold text-surface-900">接口请求</h2>
            <span v-if="form.id" class="text-[11px] text-primary-600">
              正在编辑接口「{{ form.name || '未命名' }}」
            </span>
            <span v-else class="text-[11px] text-gray-400">新接口（保存后进入左栏列表）</span>
          </div>

          <!-- 接口名称 -->
          <div>
            <label class="text-xs text-gray-500">接口名称（留空自动按 URL 生成）</label>
            <input
              v-model="form.name"
              class="w-full mt-1 px-3 py-2 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500"
              placeholder="例如：获取设备列表"
            />
          </div>

          <!-- 方法 + URL -->
          <div>
            <label class="text-xs text-gray-500">请求地址 URL</label>
            <div class="flex gap-2 mt-1">
              <select
                v-model="form.method"
                class="px-2 py-2 rounded-lg border text-sm font-semibold outline-none focus:border-primary-500"
                :class="methodClass(form.method)"
              >
                <option v-for="m in METHODS" :key="m" :value="m">{{ m }}</option>
              </select>
              <input
                v-model="form.url"
                class="flex-1 min-w-0 px-3 py-2 rounded-lg border border-surface-200 text-sm font-mono outline-none focus:border-primary-500"
                placeholder="/api/v1/health 或 http://host:3000/api/v1/health"
                @keydown.enter="sendRequest"
              />
            </div>
            <div class="flex flex-wrap gap-1.5 mt-2">
              <button
                v-for="s in URL_SUGGESTIONS"
                :key="s"
                type="button"
                class="px-2 py-0.5 rounded-full bg-surface-100 text-[11px] text-gray-600 hover:bg-surface-200 font-mono"
                @click="form.url = s"
              >
                {{ s }}
              </button>
            </div>
          </div>

          <!-- 超时 + 设备认证头 -->
          <div class="flex flex-wrap items-center gap-3">
            <label class="text-xs text-gray-500 shrink-0">超时（秒）</label>
            <input
              v-model.number="form.timeoutSec"
              type="number"
              min="1"
              max="300"
              class="w-20 px-3 py-1.5 rounded-lg border border-surface-200 text-sm outline-none focus:border-primary-500"
            />
            <button
              type="button"
              class="text-[11px] text-primary-600 hover:underline"
              @click="addAuthHeaders"
            >
              填入本机设备认证头
            </button>
            <span class="text-[11px] text-gray-400">默认 10 秒</span>
          </div>

          <!-- 请求头 -->
          <div>
            <div class="flex items-center justify-between">
              <label class="text-xs text-gray-500">请求头 Headers</label>
              <button
                type="button"
                class="text-[11px] text-primary-600 hover:underline"
                @click="addHeaderRow"
              >
                + 新增一行
              </button>
            </div>
            <div class="mt-2 space-y-2">
              <div v-for="(h, i) in form.headers" :key="i" class="flex items-center gap-2">
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
              <div v-if="!form.headers.length" class="text-[11px] text-gray-400">暂无请求头</div>
            </div>
            <datalist id="http-header-keys">
              <option v-for="k in COMMON_HEADERS" :key="k" :value="k"></option>
            </datalist>
            <datalist id="http-header-values">
              <option v-for="v in COMMON_HEADER_VALUES" :key="v" :value="v"></option>
            </datalist>
          </div>

          <!-- 请求体（带 JSON 高亮） -->
          <div>
            <div class="flex items-center justify-between">
              <label class="text-xs text-gray-500">
                请求体 Body（raw 文本 · JSON 高亮）
              </label>
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="text-[11px] text-primary-600 hover:underline"
                  @click="formatBody"
                >
                  格式化 JSON
                </button>
                <span v-if="bodyDisabled" class="text-[11px] text-gray-400">
                  {{ form.method }} 请求不发送 Body
                </span>
              </div>
            </div>

            <!-- 高亮层 + 透明 textarea 叠放，获得「边打字边高亮」的效果 -->
            <div
              class="relative mt-1 rounded-lg border border-surface-200 overflow-hidden bg-white focus-within:border-primary-500"
            >
              <pre
                ref="bodyHighlightEl"
                aria-hidden="true"
                class="absolute inset-0 m-0 p-3 overflow-hidden whitespace-pre font-mono text-xs leading-[1.6] pointer-events-none"
                v-html="bodyHighlighted"
              ></pre>
              <textarea
                ref="bodyInputEl"
                v-model="form.body"
                wrap="off"
                spellcheck="false"
                class="relative block w-full h-[200px] p-3 bg-transparent font-mono text-xs leading-[1.6] text-transparent caret-primary-600 outline-none resize-y overflow-auto whitespace-pre selection:bg-primary-200"
                placeholder='{"key": "value"}'
                @scroll="syncBodyScroll"
              ></textarea>
            </div>
          </div>

          <!-- 操作（此页不放「一键重发」，重发只在请求记录里） -->
          <div class="flex items-center gap-2 pt-1">
            <button
              type="button"
              class="flex-1 px-4 py-2.5 rounded-lg bg-primary-600 text-white text-sm font-medium hover:bg-primary-700 disabled:bg-gray-300 disabled:cursor-not-allowed flex items-center justify-center gap-2"
              :disabled="sending"
              @click="sendRequest"
            >
              <span
                v-if="sending"
                class="w-4 h-4 border-2 border-white/40 border-t-white rounded-full animate-spin"
              ></span>
              {{ sending ? '请求中…' : '发送请求' }}
            </button>
            <button
              type="button"
              class="px-4 py-2.5 rounded-lg border border-primary-500 text-primary-600 text-sm font-medium hover:bg-primary-50 disabled:opacity-40"
              :disabled="saving"
              @click="saveApi"
            >
              {{ saving ? '保存中…' : (form.id ? '更新接口' : '保存') }}
            </button>
          </div>
        </div>

        <!-- 本次响应（发送后立即看结果） -->
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm p-4 md:p-5">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="font-semibold text-surface-900">本次响应</h2>
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

          <div v-if="!response" class="py-8 text-center text-sm text-gray-400">
            点击「发送请求」后在此查看响应；历史记录见右栏
          </div>

          <div v-else class="mt-3 space-y-3">
            <div
              v-if="response.error"
              class="px-3 py-2 rounded-lg bg-red-50 border border-red-200 text-xs text-red-600 break-all"
            >
              {{ response.error }}
            </div>

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
                </div>
                <div class="flex items-center gap-3">
                  <button type="button" class="text-[11px] text-primary-600 hover:underline" @click="copyText(response.body)">
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
                class="m-0 px-3 py-3 bg-surface-900 text-gray-100 text-xs font-mono leading-relaxed overflow-auto max-h-[420px] whitespace-pre-wrap break-all"
                v-html="responseHighlighted"
              ></pre>
            </div>
          </div>
        </div>
      </section>

      <!-- ==================== 右栏：请求记录 ==================== -->
      <aside class="w-full xl:w-[400px] shrink-0">
        <div class="bg-white rounded-xl border border-surface-200 shadow-sm">
          <div class="flex items-center justify-between px-4 py-3 border-b border-surface-100">
            <h2 class="font-semibold text-surface-900">请求记录</h2>
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="text-[11px] text-gray-500 hover:underline"
                @click="loadRecords"
              >
                刷新
              </button>
              <button
                type="button"
                class="text-[11px] text-red-500 hover:underline disabled:opacity-40"
                :disabled="!records.length"
                @click="clearAllRecords"
              >
                清空
              </button>
            </div>
          </div>

          <div v-if="!records.length" class="px-4 py-8 text-center text-sm text-gray-400">
            暂无请求记录
          </div>

          <div v-else class="p-2 max-h-[640px] overflow-y-auto">
            <div
              v-for="rec in records"
              :key="rec.id"
              class="rounded-lg mb-1"
              :class="expandedRecordId === rec.id ? 'bg-surface-50 ring-1 ring-surface-200' : 'hover:bg-surface-50'"
            >
              <!-- 概要行 -->
              <div
                class="flex items-center gap-2 px-2 py-2 cursor-pointer"
                @click="expandedRecordId = expandedRecordId === rec.id ? null : rec.id"
              >
                <span
                  class="shrink-0 px-1.5 py-0.5 rounded text-[10px] font-bold w-14 text-center"
                  :class="methodClass(rec.method)"
                >
                  {{ rec.method }}
                </span>
                <div class="flex-1 min-w-0">
                  <div class="text-[11px] text-gray-500 font-mono truncate">{{ rec.url }}</div>
                  <div class="text-[10px] text-gray-400">
                    {{ fmtTime(rec.createdAt) }}
                    <span class="font-bold" :class="rec.error ? 'text-red-500' : statusTextClass(rec.status)">
                      · {{ rec.error ? '失败' : rec.status ?? '-' }}
                    </span>
                    · {{ rec.duration }} ms
                  </div>
                </div>
                <span class="shrink-0 text-gray-400 text-[10px]">
                  {{ expandedRecordId === rec.id ? '▲' : '▼' }}
                </span>
                <button
                  type="button"
                  class="shrink-0 px-2 py-1 rounded-md border border-primary-500 text-primary-600 text-[11px] hover:bg-primary-50 disabled:opacity-40"
                  :disabled="sending"
                  title="使用这条记录的入参重新发起请求"
                  @click.stop="resend(rec)"
                >
                  一键重发
                </button>
                <button
                  type="button"
                  class="shrink-0 w-6 h-6 rounded text-gray-400 hover:text-red-500 hover:bg-red-50"
                  title="删除该记录"
                  @click.stop="removeRecord(rec)"
                >
                  ✕
                </button>
              </div>

              <!-- 详情：完整入参 + 完整响应 -->
              <div v-if="expandedRecordId === rec.id" class="px-3 pb-3 space-y-3">
                <div>
                  <div class="text-[11px] font-semibold text-gray-600 mb-1">完整入参</div>
                  <div class="bg-surface-900 rounded-lg p-2 space-y-1">
                    <div class="text-[11px] font-mono text-amber-300 break-all">
                      {{ rec.method }} {{ rec.url }}
                    </div>
                    <div class="text-[11px] font-mono text-gray-400">超时 {{ rec.timeoutSec }}s</div>
                    <div
                      v-for="(h, i) in rec.headers.filter((x) => x.key)"
                      :key="i"
                      class="text-[11px] font-mono break-all"
                    >
                      <span class="text-sky-300">{{ h.key }}</span>
                      <span class="text-gray-500">: </span>
                      <span class="text-gray-300">{{ h.value }}</span>
                    </div>
                    <pre
                      v-if="rec.body"
                      class="m-0 mt-1 pt-1 border-t border-white/10 text-[11px] font-mono text-gray-200 overflow-auto max-h-[160px] whitespace-pre-wrap break-all"
                      v-html="highlightJson(rec.body)"
                    ></pre>
                    <div v-else class="text-[11px] text-gray-500">（无请求体）</div>
                  </div>
                </div>

                <div>
                  <div class="text-[11px] font-semibold text-gray-600 mb-1">完整响应</div>
                  <div v-if="rec.error" class="px-2 py-1.5 rounded-lg bg-red-50 border border-red-200 text-[11px] text-red-600 break-all">
                    {{ rec.error }}
                  </div>
                  <div v-else class="bg-surface-900 rounded-lg p-2 space-y-1">
                    <div class="text-[11px] font-mono">
                      <span :class="statusTextClassDark(rec.status)">状态码 {{ rec.status }}</span>
                      <span class="text-gray-400"> · 耗时 {{ rec.duration }} ms</span>
                    </div>
                    <div
                      v-for="(h, i) in rec.responseHeaders"
                      :key="i"
                      class="text-[11px] font-mono break-all"
                    >
                      <span class="text-sky-300">{{ h.key }}</span>
                      <span class="text-gray-500">: </span>
                      <span class="text-gray-300">{{ h.value }}</span>
                    </div>
                    <pre
                      class="m-0 mt-1 pt-1 border-t border-white/10 text-[11px] font-mono text-gray-200 overflow-auto max-h-[220px] whitespace-pre-wrap break-all"
                      v-html="highlightJson(rec.responseBody || '(空响应体)')"
                    ></pre>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </aside>
    </div>
  </div>
</template>

<script setup>
import { computed, inject, nextTick, onMounted, reactive, ref } from 'vue'
import axios from 'axios'
import httpToolApi from '../api/httpTool'

const showToast = inject('showToast', () => {})

const METHODS = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH']
const DEFAULT_TIMEOUT_SEC = 10

const COMMON_HEADERS = [
  'Accept',
  'Authorization',
  'Cache-Control',
  'Content-Type',
  'X-Device-UUID',
  'X-Transfer-Key',
  'X-Requested-With',
]
const COMMON_HEADER_VALUES = [
  'application/json',
  'application/x-www-form-urlencoded',
  'text/plain',
  'multipart/form-data',
  'application/json; charset=utf-8',
  'Bearer ',
  'no-cache',
]
const URL_SUGGESTIONS = ['/api/v1/health', '/api/v1/server/info', `${location.origin}/api/v1/health`]

// ============================================================
// 状态
// ============================================================
const apis = ref([])
const records = ref([])

const sending = ref(false)
const saving = ref(false)

/** 请求编辑区表单 */
const form = reactive({
  id: null,
  name: '',
  method: 'GET',
  url: '/api/v1/health',
  timeoutSec: DEFAULT_TIMEOUT_SEC,
  headers: [{ key: '', value: '' }],
  body: '',
})

/** 本次响应 */
const response = ref(null)
const bodyExpanded = ref(true)
const headersExpanded = ref(false)

/** 右栏展开的记录 id */
const expandedRecordId = ref(null)

/** 左栏行内重命名 */
const renamingId = ref(null)
const renamingName = ref('')

/** 请求体高亮层（滚动同步用） */
const bodyHighlightEl = ref(null)
const bodyInputEl = ref(null)

const bodyDisabled = computed(() => form.method === 'GET' || form.method === 'HEAD')

/** 请求体高亮 HTML */
const bodyHighlighted = computed(() => {
  const text = form.body || ''
  if (!text.trim()) return '<span class="text-gray-300"> </span>'
  return highlightJson(text)
})

/** 响应体高亮 HTML */
const responseHighlighted = computed(() => {
  const res = response.value
  if (!res) return ''
  const raw = res.body ?? ''
  if (!res.isJson) return escapeHtml(raw)
  return highlightJson(raw)
})

// ============================================================
// 加载数据
// ============================================================
async function loadApis() {
  try {
    const data = await httpToolApi.listApis()
    apis.value = data?.list || []
  } catch (e) {
    showToast('加载接口列表失败: ' + e.message, 'error')
  }
}

async function loadRecords() {
  try {
    const data = await httpToolApi.listRecords()
    records.value = data?.list || []
  } catch (e) {
    showToast('加载请求记录失败: ' + e.message, 'error')
  }
}

// ============================================================
// 接口列表操作
// ============================================================
function startNewApi() {
  form.id = null
  form.name = ''
  form.method = 'GET'
  form.url = '/api/v1/health'
  form.timeoutSec = DEFAULT_TIMEOUT_SEC
  form.headers = [{ key: '', value: '' }]
  form.body = ''
  response.value = null
}

/** 点击接口条目：回填全部参数 */
function selectApi(api) {
  form.id = api.id
  form.name = api.name || ''
  form.method = api.method || 'GET'
  form.url = api.url || ''
  form.timeoutSec = api.timeoutSec || DEFAULT_TIMEOUT_SEC
  form.headers = (api.headers && api.headers.length)
    ? api.headers.map((h) => ({ key: h.key || '', value: h.value || '' }))
    : [{ key: '', value: '' }]
  form.body = api.body || ''
  response.value = null
}

function beginRename(api) {
  renamingId.value = api.id
  renamingName.value = api.name || ''
  nextTick(() => {
    const el = document.querySelector('input[data-rename-input]')
    if (el) el.focus()
  })
}

async function commitRename(api) {
  if (renamingId.value !== api.id) return
  const name = (renamingName.value || '').trim()
  renamingId.value = null
  if (!name || name === api.name) return
  try {
    // 部分更新：只传 name，其余字段沿用原值
    const data = await httpToolApi.updateApi(api.id, { name })
    const idx = apis.value.findIndex((a) => a.id === api.id)
    if (idx !== -1 && data?.api) apis.value.splice(idx, 1, data.api)
    if (form.id === api.id) form.name = name
    showToast('接口已重命名', 'success')
  } catch (e) {
    showToast('重命名失败: ' + e.message, 'error')
  }
}

async function removeApi(api) {
  if (!window.confirm(`确认删除接口「${api.name}」？`)) return
  try {
    await httpToolApi.deleteApi(api.id)
    apis.value = apis.value.filter((a) => a.id !== api.id)
    if (form.id === api.id) form.id = null
    showToast('接口已删除', 'success')
  } catch (e) {
    showToast('删除失败: ' + e.message, 'error')
  }
}

async function saveApi() {
  const url = form.url.trim()
  if (!url) {
    showToast('请先填写请求地址 URL', 'warning')
    return
  }
  saving.value = true
  const payload = {
    name: form.name,
    method: form.method,
    url,
    timeoutSec: Number(form.timeoutSec) || DEFAULT_TIMEOUT_SEC,
    headers: form.headers.map((h) => ({ key: h.key, value: h.value })),
    body: form.body,
  }
  try {
    const data = form.id
      ? await httpToolApi.updateApi(form.id, payload)
      : await httpToolApi.createApi(payload)
    if (data?.api) {
      form.id = data.api.id
      form.name = data.api.name
      const idx = apis.value.findIndex((a) => a.id === data.api.id)
      if (idx !== -1) apis.value.splice(idx, 1, data.api)
      else apis.value.unshift(data.api)
    }
    showToast(form.id ? '接口已保存' : '接口已新增', 'success')
  } catch (e) {
    showToast('保存失败: ' + e.message, 'error')
  } finally {
    saving.value = false
  }
}

// ============================================================
// Headers 行操作
// ============================================================
function addHeaderRow() {
  form.headers.push({ key: '', value: '' })
}

function removeHeaderRow(index) {
  form.headers.splice(index, 1)
  if (!form.headers.length) addHeaderRow()
}

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
  const found = form.headers.find((h) => h.key.trim().toLowerCase() === key.toLowerCase())
  if (found) {
    found.value = value
    return
  }
  const empty = form.headers.find((h) => !h.key.trim())
  if (empty) {
    empty.key = key
    empty.value = value
  } else {
    form.headers.push({ key, value })
  }
}

// ============================================================
// 请求体编辑
// ============================================================
/** 同步高亮层滚动，保证高亮文字与输入文字重合 */
function syncBodyScroll() {
  const ta = bodyInputEl.value
  const hl = bodyHighlightEl.value
  if (!ta || !hl) return
  hl.scrollTop = ta.scrollTop
  hl.scrollLeft = ta.scrollLeft
}

function formatBody() {
  const text = (form.body || '').trim()
  if (!text) {
    showToast('请求体为空', 'warning')
    return
  }
  try {
    form.body = JSON.stringify(JSON.parse(text), null, 2)
    showToast('已格式化', 'success')
  } catch (_) {
    showToast('不是合法 JSON，无法格式化', 'warning')
  }
}

// ============================================================
// 发送请求
// ============================================================
async function sendRequest() {
  if (sending.value) return
  const url = form.url.trim()
  if (!url) {
    showToast('请先填写请求地址 URL', 'warning')
    return
  }

  sending.value = true
  const timeoutMs = (Number(form.timeoutSec) || DEFAULT_TIMEOUT_SEC) * 1000
  const startedAt = Date.now()

  let result
  try {
    const res = await axios.request({
      url,
      method: form.method,
      headers: buildHeaderMap(),
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
      error: buildErrorMessage(e, Number(form.timeoutSec) || DEFAULT_TIMEOUT_SEC),
    }
  }

  response.value = result
  sending.value = false
  bodyExpanded.value = true

  // 落库为一条请求记录（全局共享）
  try {
    const data = await httpToolApi.createRecord({
      name: form.name,
      method: form.method,
      url,
      timeoutSec: Number(form.timeoutSec) || DEFAULT_TIMEOUT_SEC,
      headers: form.headers.map((h) => ({ key: h.key, value: h.value })),
      body: form.body,
      status: result.status,
      statusText: result.statusText,
      duration: result.duration,
      responseHeaders: result.responseHeaders,
      responseBody: result.body,
      error: result.error,
    })
    if (data?.record) {
      records.value.unshift(data.record)
      expandedRecordId.value = data.record.id
    }
  } catch (e) {
    showToast('请求已发出，但记录保存失败: ' + e.message, 'error')
  }

  if (result.error) showToast(result.error, 'error')
  else if (result.status >= 400) showToast(`请求完成，服务端返回 ${result.status}`, 'warning')
  else showToast(`请求成功（${result.status}，${result.duration}ms）`, 'success')
}

/** 一键重发：把该记录的入参回填到请求页并立即发起新请求 */
async function resend(rec) {
  if (sending.value) return
  form.id = null
  form.name = rec.name || ''
  form.method = rec.method || 'GET'
  form.url = rec.url || ''
  form.timeoutSec = rec.timeoutSec || DEFAULT_TIMEOUT_SEC
  form.headers = (rec.headers && rec.headers.length)
    ? rec.headers.map((h) => ({ key: h.key || '', value: h.value || '' }))
    : [{ key: '', value: '' }]
  form.body = rec.body || ''
  window.scrollTo({ top: 0, behavior: 'smooth' })
  await sendRequest()
}

async function removeRecord(rec) {
  try {
    await httpToolApi.deleteRecord(rec.id)
    records.value = records.value.filter((r) => r.id !== rec.id)
    if (expandedRecordId.value === rec.id) expandedRecordId.value = null
  } catch (e) {
    showToast('删除失败: ' + e.message, 'error')
  }
}

async function clearAllRecords() {
  if (!records.value.length) return
  if (!window.confirm(`确认清空全部 ${records.value.length} 条请求记录？`)) return
  try {
    await httpToolApi.clearRecords()
    records.value = []
    expandedRecordId.value = null
    showToast('请求记录已清空', 'success')
  } catch (e) {
    showToast('清空失败: ' + e.message, 'error')
  }
}

// ---- 请求组装 ----
function buildHeaderMap() {
  const map = {}
  for (const h of form.headers) {
    const key = (h.key || '').trim()
    if (key) map[key] = h.value ?? ''
  }
  return map
}

function buildRequestBody() {
  if (bodyDisabled.value) return undefined
  const text = (form.body || '').trim()
  if (!text) return undefined
  try {
    return JSON.parse(text)
  } catch (_) {
    return text
  }
}

function buildErrorMessage(error, timeoutSecValue) {
  const code = error?.code
  if (code === 'ECONNABORTED' || /timeout/i.test(error?.message || '')) {
    return `请求超时：超过 ${timeoutSecValue} 秒未收到响应`
  }
  if (code === 'ERR_NETWORK' || code === 'ECONNREFUSED') {
    return '网络错误：无法连接到目标地址（服务未启动、地址错误或被浏览器 CORS 拦截）'
  }
  return error?.message || '请求失败'
}

function normalizeHeaders(raw) {
  if (!raw) return []
  const source = typeof raw.toJSON === 'function' ? raw.toJSON() : raw
  return Object.keys(source).map((k) => ({ key: k, value: String(source[k]) }))
}

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
// 展示辅助
// ============================================================
function escapeHtml(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** JSON 语法高亮：key / string / number / boolean / null 分色 */
const JSON_TOKEN_RE =
  /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)/g

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

function statusBadgeClass(status) {
  if (status >= 200 && status < 400) return 'bg-emerald-100 text-emerald-700'
  return 'bg-red-100 text-red-600'
}

function statusTextClass(status) {
  if (status >= 200 && status < 400) return 'text-emerald-600'
  return 'text-red-500'
}

/** 深色面板（记录详情）里的状态码配色 */
function statusTextClassDark(status) {
  if (status >= 200 && status < 400) return 'text-emerald-400'
  return 'text-red-400'
}

function fmtTime(iso) {
  if (!iso) return '-'
  const d = new Date(iso)
  const pad = (n) => String(n).padStart(2, '0')
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

async function copyText(text) {
  if (!text) return
  try {
    await navigator.clipboard.writeText(text)
    showToast('已复制', 'success')
  } catch (_) {
    showToast('复制失败，请手动选择复制', 'error')
  }
}

onMounted(() => {
  loadApis()
  loadRecords()
})
</script>
