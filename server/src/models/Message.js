/**
 * Message 数据模型
 *
 * 表: messages (id, conversation_id, role, content, input_tokens, output_tokens, model_name, created_at)
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
 * 插入一条消息
 * @param {number} convId - 对话 ID
 * @param {string} role - 角色 (user/assistant/system)
 * @param {string} content - 消息内容
 * @param {object} [modelInfo={}] - 模型信息 { modelName, inputTokens, outputTokens }
 * @returns {Promise<object>} 创建的 Message 对象
 */
async function create(convId, role, content, modelInfo = {}) {
  const p = await pool();
  const now = new Date().toISOString();
  const { modelName = '', inputTokens = 0, outputTokens = 0 } = modelInfo;

  const [result] = await p.execute(
    `INSERT INTO messages (conversation_id, role, content, input_tokens, output_tokens, model_name, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [convId, role, content, inputTokens, outputTokens, modelName, now]
  );

  return {
    id: result.insertId,
    conversation_id: convId,
    role,
    content,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    model_name: modelName,
    created_at: now,
  };
}

/**
 * 查询对话的消息历史（按时间升序，取最近 N 条）
 * @param {number} convId - 对话 ID
 * @param {number} [limit=20] - 返回条数
 * @returns {Promise<Array<object>>} 消息列表
 */
async function findByConversation(convId, limit = 20) {
  const p = await pool();
  // 先获取总数，再取最后 limit 条（保持时间升序排列）
  const [countRows] = await p.execute(
    'SELECT COUNT(*) as total FROM messages WHERE conversation_id = ?',
    [convId]
  );
  const total = countRows[0].total;
  const offset = Math.max(0, total - limit);

  const [rows] = await p.execute(
    `SELECT id, conversation_id, role, content, input_tokens, output_tokens, model_name, created_at
     FROM messages
     WHERE conversation_id = ?
     ORDER BY created_at ASC
     LIMIT ? OFFSET ?`,
    [convId, String(limit), String(offset)]
  );
  return rows;
}

/**
 * 查询对话消息总数
 * @param {number} convId - 对话 ID
 * @returns {Promise<number>} 消息总数
 */
async function countByConversation(convId) {
  const p = await pool();
  const [rows] = await p.execute(
    'SELECT COUNT(*) as total FROM messages WHERE conversation_id = ?',
    [convId]
  );
  return rows[0].total;
}

/**
 * 删除对话下所有消息
 * @param {number} convId - 对话 ID
 * @returns {Promise<number>} 删除的消息数
 */
async function deleteByConversation(convId) {
  const p = await pool();
  const [result] = await p.execute('DELETE FROM messages WHERE conversation_id = ?', [convId]);
  return result.affectedRows;
}

module.exports = { create, findByConversation, countByConversation, deleteByConversation };
