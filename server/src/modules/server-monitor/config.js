/**
 * 服务器监控模块 — 配置存储（持久化 JSON）
 *
 * 所有配置持久化到 server/data/server-monitor/config.json，
 * 重启服务不丢失。Web 端可读写（受权限控制）。
 */

const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(__dirname, '..', '..', '..', 'data', 'server-monitor');
const CONFIG_FILE = path.join(DATA_DIR, 'config.json');

const DEFAULTS = {
  /** 固定扫描根目录（Web 端可改，持久化） */
  scanRoot: '/opt/workspace',

  /** 递归扫描深度，默认 1 级，防止无限递归卡死 */
  maxDepth: 1,

  /** 手动忽略的项目目录（绝对路径） */
  ignoreList: [],

  /** 是否加载系统全局 Nginx（/etc/nginx），默认关闭防误操作 */
  useSystemNginx: false,

  /** 额外的 Nginx 配置目录（项目内或自定义） */
  nginxConfigDirs: [],

  /** 是否启用细粒度权限控制 */
  enablePermission: false,

  /** 设备 UUID -> 角色 映射：'admin' | 'readonly' */
  roles: {},

  /** 前端轮询兜底间隔（毫秒） */
  pollIntervalMs: 5000,

  /** 日志最大推送行数（防前端卡顿） */
  logMaxLines: 2000,

  /** 一次性命令超时（秒） */
  commandTimeoutSec: 60,

  /** 进程优雅停止等待时间（秒） */
  stopGraceSec: 8,

  /** 是否将告警推送到绑定的安卓 App（复用现有通道） */
  enableAlertPush: false,

  /** 统计卡片/概览刷新间隔（毫秒） */
  refreshIntervalMs: 3000,
};

let _config = { ...DEFAULTS };

/** 加载配置（启动或文件变更时） */
function load() {
  try {
    if (!fs.existsSync(DATA_DIR)) {
      fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    if (fs.existsSync(CONFIG_FILE)) {
      const raw = fs.readFileSync(CONFIG_FILE, 'utf8');
      const parsed = JSON.parse(raw);
      _config = { ...DEFAULTS, ...parsed };
    } else {
      save();
    }
  } catch (err) {
    // 配置损坏时回退到默认值，保证服务可启动
    _config = { ...DEFAULTS };
    try { save(); } catch (_) {}
  }
  return _config;
}

/** 持久化配置 */
function save() {
  try {
    if (!fs.existsSync(DATA_DIR)) {
      fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(_config, null, 2), 'utf8');
  } catch (err) {
    const logger = require('../../utils/logger');
    logger.error(`[Monitor] 配置保存失败: ${err.message}`);
  }
}

function get() {
  return _config;
}

/**
 * 更新配置（浅合并 + 校验）。
 * @param {Partial<typeof DEFAULTS>} patch
 */
function update(patch = {}) {
  // 基础校验
  if (patch.scanRoot && typeof patch.scanRoot !== 'string') {
    throw new Error('scanRoot 必须为字符串');
  }
  if (patch.maxDepth != null) {
    const d = Number(patch.maxDepth);
    if (!Number.isInteger(d) || d < 0 || d > 5) {
      throw new Error('maxDepth 必须为 0-5 的整数');
    }
    patch.maxDepth = d;
  }
  if (patch.ignoreList && !Array.isArray(patch.ignoreList)) {
    throw new Error('ignoreList 必须为数组');
  }
  if (patch.roles && typeof patch.roles !== 'object') {
    throw new Error('roles 必须为对象');
  }
  if (patch.pollIntervalMs != null) {
    patch.pollIntervalMs = Math.max(1000, Number(patch.pollIntervalMs));
  }
  _config = { ..._config, ...patch };
  save();
  return _config;
}

/** 追加忽略项 */
function addIgnore(absPath) {
  if (!_config.ignoreList.includes(absPath)) {
    _config.ignoreList.push(absPath);
    save();
  }
  return _config.ignoreList;
}

/** 移除忽略项 */
function removeIgnore(absPath) {
  _config.ignoreList = _config.ignoreList.filter((p) => p !== absPath);
  save();
  return _config.ignoreList;
}

/** 设置角色 */
function setRole(deviceUuid, role) {
  if (!['admin', 'readonly'].includes(role)) {
    throw new Error('角色必须为 admin 或 readonly');
  }
  _config.roles[deviceUuid] = role;
  save();
  return _config.roles;
}

module.exports = {
  DATA_DIR,
  CONFIG_FILE,
  DEFAULTS,
  load,
  save,
  get,
  update,
  addIgnore,
  removeIgnore,
  setRole,
};
