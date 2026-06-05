/**
 * Token 统计服务
 *
 * 封装 TokenUsage 模型，提供便捷的统计查询接口
 */

const TokenUsageModel = require('../../models/TokenUsage');
const logger = require('../../utils/logger');

/**
 * 记录一次 Token 用量
 * @param {string} deviceId - 设备 UUID
 * @param {string} modelName - 模型名称
 * @param {string} provider - 提供商
 * @param {number} inputTokens - 输入 token 数
 * @param {number} outputTokens - 输出 token 数
 * @returns {Promise<object>} 记录结果
 */
async function recordUsage(deviceId, modelName, provider, inputTokens, outputTokens) {
  return TokenUsageModel.record(deviceId, modelName, provider, inputTokens, outputTokens);
}

/**
 * 获取设备 Token 用量统计（按模型聚合）
 * @param {string} deviceId - 设备 UUID
 * @param {string} [startDate] - 开始日期 ISO 8601
 * @param {string} [endDate] - 结束日期 ISO 8601
 * @returns {Promise<Array<object>>} 按模型聚合的统计
 */
async function getStats(deviceId, startDate, endDate) {
  return TokenUsageModel.aggregateByModel(deviceId, startDate, endDate);
}

/**
 * 获取全设备 Token 用量统计
 * @param {string} [startDate] - 开始日期
 * @param {string} [endDate] - 结束日期
 * @returns {Promise<Array<object>>} 按设备聚合的统计
 */
async function getTotalStats(startDate, endDate) {
  return TokenUsageModel.aggregateByDevice(startDate, endDate);
}

/**
 * 查询设备用量明细
 * @param {string} deviceId - 设备 UUID
 * @param {string} [startDate] - 开始日期
 * @param {string} [endDate] - 结束日期
 * @returns {Promise<Array<object>>} 用量记录列表
 */
async function getUsageRecords(deviceId, startDate, endDate) {
  return TokenUsageModel.queryByDevice(deviceId, startDate, endDate);
}

module.exports = { recordUsage, getStats, getTotalStats, getUsageRecords };
