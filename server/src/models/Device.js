/**
 * Device 数据模型 — 内存存储（+ 文件持久化）
 *
 * 使用 Map 实现设备注册、查询、绑定关系管理。
 * 数据在内存中读写（快），同时异步落盘到 server/data/device-store.json，
 * 使「设备 ↔ 传输密钥 ↔ 绑定关系」在进程重启 / 设备下线后依然保留：
 *  - 传输密钥不会因服务端重启而轮换（否则 App 端持有的旧密钥会 4003 鉴权失败）
 *  - 设备重新上线时可自动匹配历史绑定并推送重连，无需用户重新扫码配对
 */

const fs = require('fs');
const path = require('path');

/** @type {Map<string, object>} 设备信息: uuid -> device */
const _devices = new Map();

/** @type {Map<string, Set<string>>} 绑定关系: deviceUuid -> Set<pairedDeviceUuid> */
const _bindings = new Map();

/** @type {Map<string, {deviceUuid: string, boundAt: string}>} 绑定时间: "a|b" -> { boundAt } */
const _bindMeta = new Map();

/** 持久化文件路径（与监控模块共用 server/data 目录） */
const DATA_DIR = path.join(__dirname, '..', '..', 'data');
const STORE_FILE = path.join(DATA_DIR, 'device-store.json');

/** 落盘防抖定时器 */
let _saveTimer = null;

/** @type {Map<string, {deviceUuid: string, expiresAt: number}>} 连接码: code -> {deviceUuid, expiresAt} */
const _pairCodes = new Map();

/** @type {Set<string>} 当前真实处于 WS 连接状态的设备 UUID（连接真相，供 isOnline 优先判定） */
const _liveConnections = new Set();

// ============================================================
// 持久化：设备（含传输密钥）+ 绑定关系
// ============================================================

/** 启动时加载落盘数据（失败不影响服务启动） */
function _load() {
  try {
    if (!fs.existsSync(STORE_FILE)) return;
    const raw = JSON.parse(fs.readFileSync(STORE_FILE, 'utf8')) || {};
    if (Array.isArray(raw.devices)) {
      for (const d of raw.devices) {
        if (d && d.device_uuid) _devices.set(d.device_uuid, d);
      }
    }
    if (raw.bindings && typeof raw.bindings === 'object') {
      for (const [uuid, list] of Object.entries(raw.bindings)) {
        _bindings.set(uuid, new Set(Array.isArray(list) ? list : []));
      }
    }
    if (Array.isArray(raw.bindMeta)) {
      for (const m of raw.bindMeta) {
        if (m && m.key) _bindMeta.set(m.key, { deviceUuid: m.deviceUuid, boundAt: m.boundAt });
      }
    }
    console.log(
      `[Device] 已加载持久化数据: ${_devices.size} 个设备, ` +
        `${_bindMeta.size} 条绑定关系`,
    );
  } catch (e) {
    console.warn(`[Device] 持久化数据加载失败（将使用空数据）: ${e.message}`);
  }
}

/** 落盘（防抖 300ms，避免高频写入） */
function _persist() {
  if (_saveTimer) return;
  _saveTimer = setTimeout(() => {
    _saveTimer = null;
    try {
      if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
      const bindings = {};
      for (const [uuid, set] of _bindings.entries()) {
        bindings[uuid] = Array.from(set);
      }
      const payload = {
        version: 1,
        updatedAt: new Date().toISOString(),
        devices: Array.from(_devices.values()),
        bindings,
        bindMeta: Array.from(_bindMeta.entries()).map(([key, v]) => ({
          key,
          deviceUuid: v.deviceUuid,
          boundAt: v.boundAt,
        })),
      };
      const tmp = `${STORE_FILE}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(payload, null, 2));
      fs.renameSync(tmp, STORE_FILE);
    } catch (e) {
      console.warn(`[Device] 持久化保存失败: ${e.message}`);
    }
  }, 300);
  if (typeof _saveTimer.unref === 'function') _saveTimer.unref();
}

_load();

/** 连接码有效期：5 分钟 */
const PAIR_CODE_TTL = 5 * 60 * 1000;

/**
 * 标记设备当前有活跃 WS 连接（由 ws 层在认证通过/重连时调用）
 * @param {string} uuid
 */
function markConnected(uuid) {
  _liveConnections.add(uuid);
}

/**
 * 标记设备 WS 连接已全部断开（由 ws 层在连接关闭且无可替代连接时调用）
 * @param {string} uuid
 */
function markDisconnected(uuid) {
  _liveConnections.delete(uuid);
}

/**
 * 设备是否当前真实在线（有活跃 WS 连接）
 * @param {string} uuid
 * @returns {boolean}
 */
function isLive(uuid) {
  return _liveConnections.has(uuid);
}

/**
 * 生成 6 位数字连接码并关联到设备 UUID
 * @param {string} deviceUuid - 设备 UUID
 * @returns {string} 6 位数字连接码
 */
function generatePairCode(deviceUuid) {
  // 清理该设备旧的连接码
  for (const [code, info] of _pairCodes.entries()) {
    if (info.deviceUuid === deviceUuid) {
      _pairCodes.delete(code);
    }
  }
  // 生成不重复的 6 位码
  let code;
  do {
    code = String(Math.floor(100000 + Math.random() * 900000));
  } while (_pairCodes.has(code));

  _pairCodes.set(code, {
    deviceUuid,
    expiresAt: Date.now() + PAIR_CODE_TTL,
  });
  return code;
}

/**
 * 通过连接码查询目标设备 UUID（同时校验有效期）
 * @param {string} code - 连接码
 * @returns {string|null} 设备 UUID，无效或过期返回 null
 */
function resolvePairCode(code) {
  const entry = _pairCodes.get(code);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) {
    _pairCodes.delete(code);
    return null;
  }
  return entry.deviceUuid;
}

/**
 * 消费连接码（绑定成功后删除）
 * @param {string} code - 连接码
 */
function consumePairCode(code) {
  _pairCodes.delete(code);
}

/**
 * 注册或更新设备信息
 * @param {string} uuid - 设备唯一标识
 * @param {string} name - 设备名称
 * @param {string} platform - 平台类型
 * @param {string} transferKey - 传输密钥
 * @returns {object} 设备对象
 */
async function register(uuid, name, platform, transferKey) {
  const now = new Date().toISOString();
  const existing = _devices.get(uuid);
  
  const device = {
    device_uuid: uuid,
    device_name: name,
    platform,
    // 已注册设备重复 register 时保留原 transfer_key，避免轮换导致已签发密钥失效（P2-1）
    transfer_key: existing ? existing.transfer_key : transferKey,
    created_at: existing ? existing.created_at : now,
    updated_at: now,
    last_seen_at: existing ? existing.last_seen_at : now,
  };
  
  _devices.set(uuid, device);

  // 确保该设备有绑定集合
  if (!_bindings.has(uuid)) {
    _bindings.set(uuid, new Set());
  }
  // 传输密钥与设备 UUID 一并持久化，保证服务端重启后已签发的密钥依然有效
  _persist();

  console.log(`[Device] 设备注册成功: ${uuid} (${name})`);

  return device;
}

/**
 * 根据 UUID 查询设备
 * @param {string} uuid - 设备 UUID
 * @returns {object|null} 设备对象或 null
 */
async function findByUuid(uuid) {
  const device = _devices.get(uuid);
  if (!device) return null;
  
  // 返回副本避免直接修改
  return { ...device };
}

/**
 * 更新最后在线时间
 * @param {string} uuid - 设备 UUID
 */
async function updateLastSeen(uuid) {
  const device = _devices.get(uuid);
  if (device) {
    device.last_seen_at = new Date().toISOString();
    device.updated_at = device.last_seen_at;
  }
}

/**
 * 列出所有设备（按最后在线时间倒序）
 * @returns {Array<object>} 设备列表
 */
async function listAll() {
  return Array.from(_devices.values())
    .sort((a, b) => new Date(b.last_seen_at) - new Date(a.last_seen_at))
    .map(device => ({ ...device }));
}

/**
 * 绑定两个设备（双向绑定）
 * @param {string} myUuid - 当前设备 UUID（通常是手机）
 * @param {string} targetUuid - 目标设备 UUID（通常是 PC）
 * @returns {object} 绑定结果
 */
async function bindDevices(myUuid, targetUuid) {
  const now = new Date().toISOString();

  // 确保两个设备都有绑定集合
  if (!_bindings.has(myUuid)) {
    _bindings.set(myUuid, new Set());
  }
  if (!_bindings.has(targetUuid)) {
    _bindings.set(targetUuid, new Set());
  }
  
  // 双向绑定
  _bindings.get(myUuid).add(targetUuid);
  _bindings.get(targetUuid).add(myUuid);

  // 记录绑定时间并持久化：设备下线再上线时据此自动重建绑定（P1-4）
  const boundAt = now;
  _bindMeta.set(_bindingKey(myUuid, targetUuid), { deviceUuid: targetUuid, boundAt });
  _bindMeta.set(_bindingKey(targetUuid, myUuid), { deviceUuid: myUuid, boundAt });
  _persist();

  console.log(`[Device] 设备绑定成功: ${myUuid} <-> ${targetUuid}`);

  return {
    success: true,
    boundAt,
    message: '绑定成功',
  };
}

/**
 * 绑定关系的唯一键（双方共享同一条绑定，故按字典序拼 key）
 * @param {string} a
 * @param {string} b
 */
function _bindingKey(a, b) {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

/**
 * 查询两个设备的绑定时间（未绑定返回 null）
 * @param {string} myUuid
 * @param {string} targetUuid
 */
function getBoundAt(myUuid, targetUuid) {
  return _bindMeta.get(_bindingKey(myUuid, targetUuid))?.boundAt || null;
}

/**
 * 解除设备绑定
 * @param {string} myUuid - 当前设备 UUID
 * @param {string} targetUuid - 目标设备 UUID
 * @returns {boolean} 是否成功
 */
async function unbindDevices(myUuid, targetUuid) {
  const bindingsA = _bindings.get(myUuid);
  const bindingsB = _bindings.get(targetUuid);

  if (bindingsA) {
    bindingsA.delete(targetUuid);
  }
  if (bindingsB) {
    bindingsB.delete(myUuid);
  }

  // 永久解绑：同步删除持久化的绑定记录（不再自动重连）。
  // 注意：传输密钥本身不删除 —— 设备重新注册仍需用同一把密钥完成 WS 鉴权；
  // 但绑定关系已解除，不会自动恢复配对。
  _bindMeta.delete(_bindingKey(myUuid, targetUuid));
  _persist();

  console.log(`[Device] 解除绑定: ${myUuid} <-> ${targetUuid}`);

  return true; // 内存操作总是成功
}

/**
 * 获取设备的已配对设备列表
 * @param {string} uuid - 设备 UUID
 * @returns {Array<object>} 已配对设备列表
 */
async function getPairedDevices(uuid) {
  const pairedUuids = _bindings.get(uuid);
  
  if (!pairedUuids || pairedUuids.size === 0) {
    return [];
  }
  
  // 返回已配对设备的详细信息
  const pairedDevices = [];
  for (const pairedUuid of pairedUuids) {
    const device = _devices.get(pairedUuid);
    if (device) {
      pairedDevices.push({
        ...device,
        isOnline: isOnline(device.last_seen_at, device.device_uuid), // 优先以真实连接状态为准
      });
    }
  }

  // 按最后在线时间排序
  return pairedDevices.sort((a, b) => 
    new Date(b.last_seen_at) - new Date(a.last_seen_at)
  );
}

/**
 * 检查设备是否在线（2分钟内有活动）
 *
 * 阈值从 5 分钟收紧到 2 分钟：心跳间隔 30 秒、心跳超时 60 秒，
 * 因此真正在线的设备 last_seen_at 不会落后超过 ~60 秒，2 分钟足够安全。
 * 原值 5 分钟过于宽松，直接导致「App 已经关了，Web 首页却还显示在线」。
 *
 * 注意：这里只影响 /device/list 返回的 isOnline 字段；
 * 自动解绑另有 10 分钟阈值（AUTO_UNBIND_THRESHOLD_MS），不受影响。
 *
 * @param {string} lastSeenAt - 最后在线时间
 * @returns {boolean}
 */
function isOnline(lastSeenAt, uuid) {
  // 优先以真实 WS 连接状态为准，避免「推送已离线、列表仍在线」的口径不一致（P2-3）
  if (typeof uuid === 'string' && _liveConnections.has(uuid)) return true;

  if (!lastSeenAt) return false;

  const diff = Date.now() - new Date(lastSeenAt).getTime();

  return diff < 2 * 60 * 1000; // 2分钟内视为在线
}

/**
 * 清除所有数据（用于测试或重置）
 */
function clearAll() {
  _devices.clear();
  _bindings.clear();
  _bindMeta.clear();
  _persist();
  console.log('[Device] 所有数据已清除');
}

/**
 * 全局在线设备列表（供自动重连匹配使用）
 * @returns {string[]} 当前有活跃 WS 连接的设备 UUID
 */
function listOnlineDeviceUuids() {
  return Array.from(_liveConnections);
}

/**
 * 获取内存统计信息（调试用）
 */
function getStats() {
  let totalBindings = 0;
  for (const set of _bindings.values()) {
    totalBindings += set.size;
  }
  
  return {
    totalDevices: _devices.size,
    totalBindings: totalBindings / 2, // 双向绑定所以除以2
    storageType: 'memory',
    devices: Array.from(_devices.keys()),
  };
}

module.exports = { 
  register, 
  findByUuid, 
  updateLastSeen, 
  listAll, 
  bindDevices,
  unbindDevices,
  getPairedDevices,
  clearAll,
  getStats,
  generatePairCode,
  resolvePairCode,
  consumePairCode,
  markConnected,
  markDisconnected,
  isLive,
  getBoundAt,
  listOnlineDeviceUuids,
};
