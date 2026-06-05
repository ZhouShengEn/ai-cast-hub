/**
 * TokenUsage 数据模型
 *
 * 表: token_usages (id, device_id, model_name, model_provider, input_tokens, output_tokens, cost, created_at)
 * cost 默认为 0（暂不计算具体费用）
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
 * 记录 Token 用量
 * @param {string} deviceId - 设备 UUID
 * @param {string} modelName - 模型名称
 * @param {string} provider - 提供商
 * @param {number} inputTokens - 输入 token 数
 * @param {number} outputTokens - 输出 token 数
 * @returns {Promise<object>} 创建的记录
 */
async function record(deviceId, modelName, provider, inputTokens, outputTokens) {
  const p = await pool();
  const now = new Date().toISOString();
  const cost = 0; // 暂不计算具体费用

  const [result] = await p.execute(
    `INSERT INTO token_usages (device_id, model_name, model_provider, input_tokens, output_tokens, cost, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [deviceId, modelName, provider, inputTokens, outputTokens, cost, now]
  );

  return {
    id: result.insertId,
    device_id: deviceId,
    model_name: modelName,
    model_provider: provider,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cost,
    created_at: now,
  };
}

/**
 * 按设备 + 时间范围查询用量记录
 * @param {string} deviceId - 设备 UUID
 * @param {string} [startDate] - 开始日期 ISO 8601
 * @param {string} [endDate] - 结束日期 ISO 8601
 * @returns {Promise<Array<object>>} 用量记录列表
 */
async function queryByDevice(deviceId, startDate, endDate) {
  const p = await pool();
  let sql = 'SELECT id, device_id, model_name, model_provider, input_tokens, output_tokens, cost, created_at FROM token_usages WHERE device_id = ?';
  const params = [deviceId];

  if (startDate) {
    sql += ' AND created_at >= ?';
    params.push(startDate);
  }
  if (endDate) {
    sql += ' AND created_at <= ?';
    params.push(endDate);
  }

  sql += ' ORDER BY created_at DESC LIMIT 500';
  const [rows] = await p.execute(sql, params);
  return rows;
}

/**
 * 按模型聚合统计用量
 * @param {string} deviceId - 设备 UUID
 * @param {string} [startDate] - 开始日期
 * @param {string} [endDate] - 结束日期
 * @returns {Promise<Array<object>>} 按模型聚合的统计
 */
async function aggregateByModel(deviceId, startDate, endDate) {
  const p = await pool();
  let sql = `SELECT model_name, model_provider,
    SUM(input_tokens) as total_input_tokens,
    SUM(output_tokens) as total_output_tokens,
    SUM(input_tokens + output_tokens) as total_tokens,
    SUM(cost) as total_cost,
    COUNT(*) as request_count
    FROM token_usages WHERE device_id = ?`;
  const params = [deviceId];

  if (startDate) {
    sql += ' AND created_at >= ?';
    params.push(startDate);
  }
  if (endDate) {
    sql += ' AND created_at <= ?';
    params.push(endDate);
  }

  sql += ' GROUP BY model_name, model_provider ORDER BY total_tokens DESC';
  const [rows] = await p.execute(sql, params);
  return rows;
}

/**
 * 全设备聚合统计
 * @param {string} [startDate] - 开始日期
 * @param {string} [endDate] - 结束日期
 * @returns {Promise<Array<object>>} 按设备聚合的统计
 */
async function aggregateByDevice(startDate, endDate) {
  const p = await pool();
  let sql = `SELECT device_id,
    SUM(input_tokens) as total_input_tokens,
    SUM(output_tokens) as total_output_tokens,
    SUM(input_tokens + output_tokens) as total_tokens,
    SUM(cost) as total_cost,
    COUNT(*) as request_count
    FROM token_usages WHERE 1=1`;
  const params = [];

  if (startDate) {
    sql += ' AND created_at >= ?';
    params.push(startDate);
  }
  if (endDate) {
    sql += ' AND created_at <= ?';
    params.push(endDate);
  }

  sql += ' GROUP BY device_id ORDER BY total_tokens DESC';
  const [rows] = await p.execute(sql, params);
  return rows;
}

module.exports = { record, queryByDevice, aggregateByModel, aggregateByDevice };
