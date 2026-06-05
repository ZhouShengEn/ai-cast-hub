/**
 * API 路由聚合
 *
 * 挂载:
 * - /device → device.js (设备管理)
 * - /chat   → chat.js   (AI 对话)
 * - /model  → model.js  (模型管理)
 * - /file   → file.js   (文件传输)
 * - /stats  → stats.js  (用量统计)
 * - /health            (健康检查)
 */

const { Router } = require('express');

const deviceRoutes = require('./device');
const chatRoutes = require('./chat');
const modelRoutes = require('./model');
const fileRoutes = require('./file');
const statsRoutes = require('./stats');

const router = Router();

// ---- 健康检查 ----
router.get('/health', (req, res) => {
  res.json({
    code: 0,
    data: {
      status: 'ok',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
    },
    message: 'ok',
  });
});

// ---- 子路由挂载 ----
router.use('/device', deviceRoutes);
router.use('/chat', chatRoutes);
router.use('/model', modelRoutes);
router.use('/file', fileRoutes);
router.use('/stats', statsRoutes);

module.exports = router;
