/**
 * 统计路由
 *
 * GET /tokens          — Token 用量统计（当前设备）
 * GET /tokens/by-model — 按模型维度统计
 */

const { Router } = require('express');
const tokenCounter = require('../services/ai/tokenCounter');
const logger = require('../utils/logger');

const router = Router();

/**
 * GET /api/v1/stats/tokens
 * 获取当前设备的 Token 用量统计
 * Query: startDate, endDate (ISO 8601)
 */
router.get('/tokens', async (req, res, next) => {
  try {
    const { startDate, endDate } = req.query;

    const stats = await tokenCounter.getStats(req.deviceUuid, startDate, endDate);

    // 计算汇总
    const summary = stats.reduce(
      (acc, s) => ({
        totalTokens: acc.totalTokens + s.total_tokens,
        totalInputTokens: acc.totalInputTokens + s.total_input_tokens,
        totalOutputTokens: acc.totalOutputTokens + s.total_output_tokens,
        totalRequests: acc.totalRequests + s.request_count,
      }),
      { totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0, totalRequests: 0 }
    );

    res.json({
      code: 0,
      data: {
        summary,
        byModel: stats,
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/stats/tokens/by-model
 * 按模型维度统计（当前设备）
 * Query: startDate, endDate
 */
router.get('/tokens/by-model', async (req, res, next) => {
  try {
    const { startDate, endDate } = req.query;

    const stats = await tokenCounter.getStats(req.deviceUuid, startDate, endDate);

    res.json({
      code: 0,
      data: { models: stats },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
