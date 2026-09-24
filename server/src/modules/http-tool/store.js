/**
 * HTTP 接口调试工具 — 数据存储
 *
 * 存储策略（与 App 端刻意区分）：
 *  - Web 端：接口列表 + 请求记录 **统一存放在服务端**，全局共享一份数据
 *    （按产品要求不做登录/账号隔离，任何客户端读到的都是同一份）。
 *  - App 端：只存手机本地数据库，不上传（见 flutter-app 的 local_storage.dart）。
 *
 * 持久化复用 config/database 的 dataStore：内存为主 + 500ms 防抖落盘到
 * server/data/store.json，重启后自动恢复，无需任何外部数据库。
 */

const crypto = require('crypto');
const { dataStore } = require('../../config/database');

/** dataStore 中的键名 */
const KEY_APIS = 'httpTool.apis';
const KEY_RECORDS = 'httpTool.records';

/** 请求记录条数上限（超出丢弃最旧的），避免 store.json 无限膨胀 */
const RECORD_LIMIT = 300;

/** 支持的请求方法 */
const METHODS = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];

/** 单次请求体 / 响应体最大保存长度（超出截断），防止把 store.json 写爆 */
const MAX_BODY_CHARS = 200 * 1024;

// ============================================================
// 通用工具
// ============================================================

function readList(key) {
  const value = dataStore.get(key);
  return Array.isArray(value) ? value : [];
}

function writeList(key, list) {
  dataStore.set(key, list);
  return list;
}

/** 归一化请求头为 [{key,value}]，并丢弃非法项 */
function normalizeHeaders(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .slice(0, 100)
    .map((h) => ({
      key: typeof h?.key === 'string' ? h.key.slice(0, 200) : '',
      value: typeof h?.value === 'string' ? h.value.slice(0, 2000) : '',
    }));
}

function normalizeMethod(method) {
  const upper = String(method || 'GET').toUpperCase();
  return METHODS.includes(upper) ? upper : 'GET';
}

function normalizeTimeoutSec(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return 10;
  return Math.min(Math.max(Math.round(n), 1), 300);
}

/** 超长文本截断（保留尾部提示，便于看出是被截断的） */
function truncateBody(text) {
  const s = typeof text === 'string' ? text : '';
  if (s.length <= MAX_BODY_CHARS) return s;
  return `${s.slice(0, MAX_BODY_CHARS)}\n\n…（响应体超过 ${Math.round(MAX_BODY_CHARS / 1024)}KB，已截断）`;
}

/** 根据 URL 生成默认接口名 */
function defaultName(method, url) {
  try {
    const u = new URL(url);
    return `${method} ${u.pathname}`;
  } catch (_) {
    return `${method} ${url || ''}`.trim();
  }
}

// ============================================================
// 接口列表
// ============================================================

/** 全部接口（按更新时间倒序） */
function listApis() {
  return readList(KEY_APIS);
}

/**
 * 新增或更新接口
 *
 * 更新语义是「部分更新」：未出现在 payload 里的字段沿用原值。
 * 这样「只改名字」的重命名操作不必回传 url/headers/body，
 * 否则前端每次都得提交完整对象，容易漏字段。
 *
 * @param {object} payload 请求体
 * @param {string} [id] 传入则更新，否则新增
 * @returns {{api:object}|{error:string}}
 */
function saveApi(payload = {}, id) {
  const apis = listApis();
  const now = new Date().toISOString();

  // ---- 更新 ----
  if (id) {
    const index = apis.findIndex((a) => a.id === id);
    if (index === -1) return { error: '接口不存在' };
    const prev = apis[index];

    const url =
      typeof payload.url === 'string' && payload.url.trim() ? payload.url.trim() : prev.url;
    if (!url) return { error: 'URL 不能为空' };

    const method = payload.method ? normalizeMethod(payload.method) : prev.method;
    const name =
      (typeof payload.name === 'string' && payload.name.trim()) ||
      prev.name ||
      defaultName(method, url);

    const record = {
      ...prev,
      name,
      method,
      url,
      headers: payload.headers === undefined ? prev.headers : normalizeHeaders(payload.headers),
      body: typeof payload.body === 'string' ? payload.body : prev.body || '',
      timeoutSec:
        payload.timeoutSec === undefined
          ? prev.timeoutSec
          : normalizeTimeoutSec(payload.timeoutSec),
      updatedAt: now,
    };

    // 最近更新的排最前
    apis.splice(index, 1);
    apis.unshift(record);
    writeList(KEY_APIS, apis);
    return { api: record };
  }

  // ---- 新增 ----
  const url = typeof payload.url === 'string' ? payload.url.trim() : '';
  if (!url) return { error: 'URL 不能为空' };

  const method = normalizeMethod(payload.method);
  const record = {
    id: crypto.randomUUID(),
    name:
      (typeof payload.name === 'string' && payload.name.trim()) || defaultName(method, url),
    method,
    url,
    headers: normalizeHeaders(payload.headers),
    body: typeof payload.body === 'string' ? payload.body : '',
    timeoutSec: normalizeTimeoutSec(payload.timeoutSec),
    createdAt: now,
    updatedAt: now,
  };

  apis.unshift(record);
  writeList(KEY_APIS, apis);
  return { api: record };
}

/** 删除接口 */
function deleteApi(id) {
  const apis = listApis();
  const next = apis.filter((a) => a.id !== id);
  if (next.length === apis.length) return { error: '接口不存在' };
  writeList(KEY_APIS, next);
  return { ok: true };
}

// ============================================================
// 请求记录（始终按时间倒序存储，读取即得倒序）
// ============================================================

function listRecords() {
  return readList(KEY_RECORDS);
}

/** 追加一条请求记录 */
function addRecord(payload = {}) {
  const url = typeof payload.url === 'string' ? payload.url.trim() : '';
  if (!url) return { error: 'URL 不能为空' };

  const method = normalizeMethod(payload.method);
  const record = {
    id: crypto.randomUUID(),
    name:
      (typeof payload.name === 'string' && payload.name.trim()) || defaultName(method, url),
    method,
    url,
    headers: normalizeHeaders(payload.headers),
    body: typeof payload.body === 'string' ? truncateBody(payload.body) : '',
    timeoutSec: normalizeTimeoutSec(payload.timeoutSec),
    // 响应信息
    status: Number.isInteger(payload.status) ? payload.status : null,
    statusText: typeof payload.statusText === 'string' ? payload.statusText : '',
    duration: Number.isFinite(Number(payload.duration)) ? Number(payload.duration) : 0,
    responseHeaders: normalizeHeaders(payload.responseHeaders),
    responseBody: truncateBody(payload.responseBody),
    error: typeof payload.error === 'string' && payload.error ? payload.error.slice(0, 2000) : null,
    createdAt: new Date().toISOString(),
  };

  const records = listRecords();
  records.unshift(record);
  writeList(KEY_RECORDS, records.slice(0, RECORD_LIMIT));
  return { record };
}

function deleteRecord(id) {
  const records = listRecords();
  const next = records.filter((r) => r.id !== id);
  if (next.length === records.length) return { error: '记录不存在' };
  writeList(KEY_RECORDS, next);
  return { ok: true };
}

function clearRecords() {
  writeList(KEY_RECORDS, []);
  return { ok: true };
}

module.exports = {
  KEY_APIS,
  KEY_RECORDS,
  METHODS,
  RECORD_LIMIT,
  listApis,
  saveApi,
  deleteApi,
  listRecords,
  addRecord,
  deleteRecord,
  clearRecords,
};
