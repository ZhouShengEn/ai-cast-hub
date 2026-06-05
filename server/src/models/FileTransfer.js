/**
 * FileTransfer 数据模型
 *
 * 表: file_transfers (id, from_device_id, to_device_id, file_name, file_size,
 *     status, checksum, created_at, completed_at)
 * status: pending | transferring | completed | failed
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
 * 创建文件传输记录
 * @param {string} fromDeviceId - 发起设备 UUID
 * @param {string} toDeviceId - 目标设备 UUID
 * @param {string} fileName - 文件名
 * @param {number} fileSize - 文件大小（字节）
 * @param {string} checksum - 校验和
 * @returns {Promise<object>} 创建的 FileTransfer 对象
 */
async function create(fromDeviceId, toDeviceId, fileName, fileSize, checksum) {
  const p = await pool();
  const now = new Date().toISOString();

  const [result] = await p.execute(
    `INSERT INTO file_transfers (from_device_id, to_device_id, file_name, file_size, status, checksum, created_at)
     VALUES (?, ?, ?, ?, 'pending', ?, ?)`,
    [fromDeviceId, toDeviceId, fileName, fileSize, checksum, now]
  );

  return {
    id: result.insertId,
    from_device_id: fromDeviceId,
    to_device_id: toDeviceId,
    file_name: fileName,
    file_size: fileSize,
    status: 'pending',
    checksum,
    created_at: now,
    completed_at: null,
  };
}

/**
 * 更新传输状态
 * @param {number} id - 传输记录 ID
 * @param {string} status - 新状态 (pending/transferring/completed/failed)
 * @returns {Promise<boolean>} 是否更新成功
 */
async function updateStatus(id, status) {
  const p = await pool();
  const now = new Date().toISOString();

  const completedAt = (status === 'completed' || status === 'failed') ? now : null;

  if (completedAt) {
    const [result] = await p.execute(
      'UPDATE file_transfers SET status = ?, completed_at = ? WHERE id = ?',
      [status, completedAt, id]
    );
    return result.affectedRows > 0;
  }

  const [result] = await p.execute(
    'UPDATE file_transfers SET status = ? WHERE id = ?',
    [status, id]
  );
  return result.affectedRows > 0;
}

/**
 * 查询设备相关的传输记录
 * @param {string} deviceId - 设备 UUID
 * @returns {Promise<Array<object>>} 传输记录列表
 */
async function findByDevice(deviceId) {
  const p = await pool();
  const [rows] = await p.execute(
    `SELECT id, from_device_id, to_device_id, file_name, file_size, status, checksum, created_at, completed_at
     FROM file_transfers
     WHERE from_device_id = ? OR to_device_id = ?
     ORDER BY created_at DESC LIMIT 100`,
    [deviceId, deviceId]
  );
  return rows;
}

/**
 * 按 ID 查询传输记录
 * @param {number} id - 传输记录 ID
 * @returns {Promise<object|null>} FileTransfer 对象或 null
 */
async function findById(id) {
  const p = await pool();
  const [rows] = await p.execute(
    `SELECT id, from_device_id, to_device_id, file_name, file_size, status, checksum, created_at, completed_at
     FROM file_transfers WHERE id = ?`,
    [id]
  );
  return rows.length > 0 ? rows[0] : null;
}

module.exports = { create, updateStatus, findByDevice, findById };
