/**
 * ApiKey 数据模型
 *
 * 表: api_keys (id, provider, encrypted_key, key_label, created_at)
 * API Key 在入库前已经过 AES-256-GCM 加密
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
 * 保存或更新 API Key（同一 provider 只保留最新一条）
 * @param {string} provider - 提供商标识
 * @param {string} encryptedKey - AES-256-GCM 加密后的密钥
 * @param {string} [label=''] - 密钥标签
 * @returns {Promise<object>} 保存后的 ApiKey 对象
 */
async function save(provider, encryptedKey, label = '') {
  const p = await pool();
  const now = new Date().toISOString();

  // 检查是否已存在该 provider 的 key
  const [existing] = await p.execute(
    'SELECT id FROM api_keys WHERE provider = ?',
    [provider]
  );

  if (existing.length > 0) {
    await p.execute(
      'UPDATE api_keys SET encrypted_key = ?, key_label = ?, created_at = ? WHERE provider = ?',
      [encryptedKey, label, now, provider]
    );
    return findByProvider(provider);
  }

  const [result] = await p.execute(
    'INSERT INTO api_keys (provider, encrypted_key, key_label, created_at) VALUES (?, ?, ?, ?)',
    [provider, encryptedKey, label, now]
  );

  return { id: result.insertId, provider, key_label: label, created_at: now };
}

/**
 * 按 provider 查询加密的 Key
 * @param {string} provider - 提供商标识
 * @returns {Promise<object|null>} ApiKey 对象（包含 encrypted_key）或 null
 */
async function findByProvider(provider) {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT id, provider, encrypted_key, key_label, created_at FROM api_keys WHERE provider = ?',
    [provider]
  );
  return rows.length > 0 ? rows[0] : null;
}

/**
 * 列出所有 API Key（不返回加密值）
 * @returns {Promise<Array<object>>} ApiKey 列表 (id/provider/label/created_at)
 */
async function listAll() {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT id, provider, key_label, created_at FROM api_keys ORDER BY created_at DESC'
  );
  return rows;
}

/**
 * 按 ID 删除 API Key
 * @param {number} id - Key ID
 * @returns {Promise<boolean>} 是否删除成功
 */
async function deleteById(id) {
  const p = await pool();
  const [result] = await p.execute('DELETE FROM api_keys WHERE id = ?', [id]);
  return result.affectedRows > 0;
}

module.exports = { save, findByProvider, listAll, deleteById };
