/**
 * Conversation 数据模型
 *
 * 表: conversations (id, device_id, title, model_provider, model_name, created_at, updated_at)
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
 * 创建新对话
 * @param {string} deviceId - 设备 UUID
 * @param {string} modelProvider - 模型提供商标识
 * @param {string} modelName - 模型名称
 * @param {string} [title='新对话'] - 对话标题
 * @returns {Promise<object>} 创建的 Conversation 对象
 */
async function create(deviceId, modelProvider, modelName, title = '新对话') {
  const p = await pool();
  const now = new Date().toISOString();

  const [result] = await p.execute(
    `INSERT INTO conversations (device_id, title, model_provider, model_name, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [deviceId, title, modelProvider, modelName, now, now]
  );

  return findById(result.insertId);
}

/**
 * 根据 ID 查询对话
 * @param {number} id - 对话 ID
 * @returns {Promise<object|null>} Conversation 对象或 null
 */
async function findById(id) {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT id, device_id, title, model_provider, model_name, created_at, updated_at FROM conversations WHERE id = ?',
    [id]
  );
  return rows.length > 0 ? rows[0] : null;
}

/**
 * 按设备分页查询对话列表
 * @param {string} deviceId - 设备 UUID
 * @param {number} [limit=20] - 每页数量
 * @param {number} [offset=0] - 偏移量
 * @returns {Promise<Array<object>>} 对话列表
 */
async function findByDevice(deviceId, limit = 20, offset = 0) {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT id, device_id, title, model_provider, model_name, created_at, updated_at FROM conversations WHERE device_id = ? ORDER BY updated_at DESC LIMIT ? OFFSET ?',
    [deviceId, String(limit), String(offset)]
  );
  return rows;
}

/**
 * 按设备统计对话总数
 * @param {string} deviceId - 设备 UUID
 * @returns {Promise<number>} 对话总数
 */
async function countByDevice(deviceId) {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT COUNT(*) as total FROM conversations WHERE device_id = ?',
    [deviceId]
  );
  return rows[0].total;
}

/**
 * 删除对话（硬删除）
 * @param {number} id - 对话 ID
 * @returns {Promise<boolean>} 是否删除成功
 */
async function deleteById(id) {
  const p = await pool();
  const [result] = await p.execute('DELETE FROM conversations WHERE id = ?', [id]);
  return result.affectedRows > 0;
}

/**
 * 更新对话标题
 * @param {number} id - 对话 ID
 * @param {string} title - 新标题
 * @returns {Promise<boolean>} 是否更新成功
 */
async function updateTitle(id, title) {
  const p = await pool();
  const [result] = await p.execute(
    'UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?',
    [title, new Date().toISOString(), id]
  );
  return result.affectedRows > 0;
}

module.exports = { create, findById, findByDevice, countByDevice, deleteById, updateTitle };
