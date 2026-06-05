/**
 * Device 数据模型
 *
 * 表: devices (id, device_uuid, device_name, platform, transfer_key, created_at, last_seen_at)
 * MySQL 为主存储，SQLite 为本地缓存
 */

const { getMySQLPool } = require('../config/database');
const logger = require('../utils/logger');

/** @type {import('mysql2/promise').Pool | null} */
let _pool = null;

async function pool() {
  if (!_pool) {
    _pool = await getMySQLPool();
  }
  return _pool;
}

/**
 * 注册或更新设备信息
 * @param {string} uuid - 设备 UUID
 * @param {string} name - 设备名称
 * @param {string} platform - 平台 (android/ios/web)
 * @param {string} transferKey - 传输密钥
 * @returns {Promise<object>} Device 对象
 */
async function register(uuid, name, platform, transferKey) {
  const p = await pool();
  const now = new Date().toISOString();

  await p.execute(
    `INSERT INTO devices (device_uuid, device_name, platform, transfer_key, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE
       device_name = VALUES(device_name),
       platform = VALUES(platform),
       transfer_key = VALUES(transfer_key),
       last_seen_at = VALUES(last_seen_at)`,
    [uuid, name, platform, transferKey, now, now]
  );

  return findByUuid(uuid);
}

/**
 * 根据 UUID 查询设备
 * @param {string} uuid - 设备 UUID
 * @returns {Promise<object|null>} Device 对象或 null
 */
async function findByUuid(uuid) {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT id, device_uuid, device_name, platform, transfer_key, created_at, last_seen_at FROM devices WHERE device_uuid = ?',
    [uuid]
  );
  return rows.length > 0 ? rows[0] : null;
}

/**
 * 更新设备 last_seen_at 时间戳
 * @param {string} uuid - 设备 UUID
 * @returns {Promise<void>}
 */
async function updateLastSeen(uuid) {
  const p = await pool();
  await p.execute(
    'UPDATE devices SET last_seen_at = ? WHERE device_uuid = ?',
    [new Date().toISOString(), uuid]
  );
}

/**
 * 查询所有已注册设备
 * @returns {Promise<Array<object>>} 设备列表
 */
async function listAll() {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT id, device_uuid, device_name, platform, created_at, last_seen_at FROM devices ORDER BY last_seen_at DESC'
  );
  return rows;
}

module.exports = { register, findByUuid, updateLastSeen, listAll };
