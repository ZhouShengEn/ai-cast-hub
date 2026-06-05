/**
 * 模型管理路由
 *
 * GET    /list    — 获取所有可用模型列表
 * POST   /apikey  — 添加/更新 API Key
 * GET    /apikeys — 列出已配置的 Key（不返回加密值）
 * DELETE /apikey/:id — 删除 API Key
 */

const { Router } = require('express');
const { apiKeySchema } = require('../utils/validators');
const ApiKeyModel = require('../models/ApiKey');
const cryptoService = require('../services/cryptoService');
const adapter = require('../services/ai/adapter');
const logger = require('../utils/logger');

const router = Router();

/**
 * GET /api/v1/model/list
 * 返回所有可用模型列表
 */
router.get('/list', async (req, res, next) => {
  try {
    const models = adapter.getAllModels();

    res.json({
      code: 0,
      data: { models },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/v1/model/apikey
 * 添加或更新 API Key
 * Body: { provider, apiKey, label? }
 */
router.post('/apikey', async (req, res, next) => {
  try {
    const { provider, apiKey, label } = apiKeySchema.parse(req.body);

    // 加密 API Key
    const encryptedKey = cryptoService.encryptApiKey(apiKey);

    // 存储到数据库
    const record = await ApiKeyModel.save(provider, encryptedKey, label || '');

    // 刷新 Provider 实例
    adapter.refreshProvider(provider, apiKey);

    logger.info(`[Model] API Key 已配置: provider=${provider} label=${label || ''}`);

    res.json({
      code: 0,
      data: {
        id: record.id,
        provider: record.provider,
        label: record.key_label,
        createdAt: record.created_at,
      },
      message: 'API Key 已保存',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/model/apikeys
 * 列出所有已配置的 API Key（不返回加密值）
 */
router.get('/apikeys', async (req, res, next) => {
  try {
    const keys = await ApiKeyModel.listAll();

    res.json({
      code: 0,
      data: { keys },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * DELETE /api/v1/model/apikey/:id
 * 删除 API Key
 */
router.delete('/apikey/:id', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: 'Key ID 格式无效',
      });
    }

    const deleted = await ApiKeyModel.deleteById(id);

    if (!deleted) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: 'API Key 不存在',
      });
    }

    res.json({
      code: 0,
      data: null,
      message: 'API Key 已删除',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
