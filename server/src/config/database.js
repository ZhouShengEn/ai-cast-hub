/**
 * 数据库配置（已移除 MySQL 依赖）
 *
 * 所有业务数据保存在「内存 + 文件」：
 *  - 内存为主，提供低延迟读写；
 *  - 通过 dataStore 按需落盘到 server/data/store.json，重启后自动恢复；
 *  - 设备配对等核心数据由各自 model 独立持久化（如 models/Device.js -> device-store.json）。
 *
 * 不再依赖任何外部数据库进程（MySQL / PostgreSQL 等），部署更简单、零外部依赖。
 */

const fs = require('fs');
const path = require('path');

/** 数据根目录：server/data */
const DATA_DIR = path.join(__dirname, '..', '..', 'data');
const STORE_FILE = path.join(DATA_DIR, 'store.json');

/** 内存数据（含 dataStore 的全部键值） */
let _store = loadStore();

function loadStore() {
  try {
    if (fs.existsSync(STORE_FILE)) {
      return JSON.parse(fs.readFileSync(STORE_FILE, 'utf8')) || {};
    }
  } catch (_) {
    /* 损坏则从头开始，不影响启动 */
  }
  return {};
}

let _saveTimer = null;

/** 立即落盘（同步，用于关闭时） */
function flushStore() {
  try {
    if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(STORE_FILE, JSON.stringify(_store, null, 2));
  } catch (e) {
    console.error(`[DB] 数据持久化失败: ${e.message}`);
  }
}

/** 防抖落盘，避免高频写入 */
function scheduleFlush() {
  if (_saveTimer) return;
  _saveTimer = setTimeout(() => {
    _saveTimer = null;
    flushStore();
  }, 500);
}

/**
 * 文件 / 内存 通用键值存储。
 * 业务模块可 `require('../config/database').dataStore` 持久化任意 JSON 数据。
 */
const dataStore = {
  get(key) {
    return _store[key];
  },
  set(key, value) {
    _store[key] = value;
    scheduleFlush();
    return value;
  },
  has(key) {
    return Object.prototype.hasOwnProperty.call(_store, key);
  },
  delete(key) {
    delete _store[key];
    scheduleFlush();
  },
  all() {
    return { ..._store };
  },
  flush: flushStore,
};

/**
 * 初始化存储（幂等）。这里只确保数据目录存在并载入磁盘数据。
 * @returns {Promise<boolean>}
 */
async function initDatabases() {
  if (!fs.existsSync(DATA_DIR)) {
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
    } catch (_) {
      /* 忽略，落盘时会再尝试 */
    }
  }
  _store = loadStore();
  console.log('[DB] ✅ 使用文件/内存存储（server/data），不依赖外部数据库');
  return true;
}

/**
 * 关闭存储：立即落盘。
 * @returns {Promise<void>}
 */
async function closeDatabases() {
  if (_saveTimer) {
    clearTimeout(_saveTimer);
    _saveTimer = null;
  }
  flushStore();
  console.log('[DB] 数据已落盘');
}

module.exports = {
  initDatabases,
  closeDatabases,
  dataStore,
};
