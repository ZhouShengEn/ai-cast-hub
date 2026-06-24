/**
 * Device 数据模型 — 内存存储方案
 *
 * 使用 Map 实现设备注册、查询、绑定关系管理
 * 数据在服务器重启后清空，适合开发测试环境
 */

/** @type {Map<string, object>} 设备信息: uuid -> device */
const _devices = new Map();

/** @type {Map<string, Set<string>>} 绑定关系: deviceUuid -> Set<pairedDeviceUuid> */
const _bindings = new Map();

/** @type {Map<string, {deviceUuid: string, expiresAt: number}>} 连接码: code -> {deviceUuid, expiresAt} */
const _pairCodes = new Map();

/** 连接码有效期：5 分钟 */
const PAIR_CODE_TTL = 5 * 60 * 1000;

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
  
  const device = {
    device_uuid: uuid,
    device_name: name,
    platform,
    transfer_key: transferKey,
    created_at: _devices.has(uuid) ? _devices.get(uuid).created_at : now,
    updated_at: now,
    last_seen_at: now,
  };
  
  _devices.set(uuid, device);
  
  // 确保该设备有绑定集合
  if (!_bindings.has(uuid)) {
    _bindings.set(uuid, new Set());
  }

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

  console.log(`[Device] 设备绑定成功: ${myUuid} <-> ${targetUuid}`);

  return {
    success: true,
    boundAt: now,
    message: '绑定成功',
  };
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
        isOnline: isOnline(device.last_seen_at), // 5分钟内视为在线
      });
    }
  }

  // 按最后在线时间排序
  return pairedDevices.sort((a, b) => 
    new Date(b.last_seen_at) - new Date(a.last_seen_at)
  );
}

/**
 * 检查设备是否在线（5分钟内有活动）
 * @param {string} lastSeenAt - 最后在线时间
 * @returns {boolean}
 */
function isOnline(lastSeenAt) {
  if (!lastSeenAt) return false;
  
  const diff = Date.now() - new Date(lastSeenAt).getTime();
  const minutes = Math.floor(diff / 60000);
  
  return minutes < 5; // 5分钟内视为在线
}

/**
 * 清除所有数据（用于测试或重置）
 */
function clearAll() {
  _devices.clear();
  _bindings.clear();
  console.log('[Device] 所有数据已清除');
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
};
