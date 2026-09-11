/**
 * AI Cast Hub — 后端入口
 *
 * Express + WebSocket 服务器:
 * - REST API:  /api/v1/*
 * - WebSocket: /ws?deviceUuid=xxx&transferKey=xxx
 */

require('dotenv').config();

const http = require('http');
const express = require('express');
const cors = require('cors');
const config = require('./config');
const { validateConfig } = require('./config');
const { initDatabases, closeDatabases } = require('./config/database');
const logger = require('./utils/logger');
const deviceAuth = require('./middleware/deviceAuth');
const errorHandler = require('./middleware/errorHandler');
const { globalLimiter, chatLimiter } = require('./middleware/rateLimiter');
const apiRoutes = require('./routes');
const { initWebSocket } = require('./ws');
const { startScheduler, stopScheduler } = require('./services/storage/tempCleanup');
const { initializeProviders } = require('./services/ai/adapter');

// ============================================================
// 创建 Express 应用
// ============================================================
const app = express();

// ---- 全局中间件 ----

// CORS 跨域支持
app.use(cors());

// JSON 请求体解析（限制 50MB 用于文件传输 base64）
app.use(express.json({ limit: '50mb' }));

// URL 编码解析
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// 全局限流
app.use(globalLimiter);

// ---- 设备认证中间件 ----
// 白名单路由无需认证
const authWhitelist = [
  '/api/v1/health',
  '/api/v1/server/info',
  '/api/v1/device/register',
  '/api/v1/device/bind-by-code',
  '/api/v1/device/pair-code',
  // 注意：/api/v1/device/bind 已从白名单移除，必须经由 deviceAuth 校验调用方身份，
  // 避免任意客户端伪造 X-Device-UUID 头与任意目标设备建立绑定（P0-2）。
];

app.use((req, res, next) => {
  // 完全匹配或前缀匹配
  const isWhitelisted = authWhitelist.some(
    (path) => req.path === path || (req.path.startsWith(path + '/') && path !== '/api/v1/health')
  ) || req.path === '/api/v1/health';

  if (isWhitelisted) {
    return next();
  }
  deviceAuth(req, res, next);
});

// ============================================================
// 挂载 API 路由
// ============================================================

// 对 AI 对话路由应用更严格的频率限制（必须在路由注册之前）
app.use('/api/v1/chat/send', chatLimiter);

app.use('/api/v1', apiRoutes);

// 404 处理
app.use((req, res) => {
  res.status(404).json({
    code: 404,
    data: null,
    message: `路由未找到: ${req.method} ${req.path}`,
  });
});

// 全局错误处理
app.use(errorHandler);

// ============================================================
// 创建 HTTP Server（Express + WebSocket 共用）
// ============================================================
const server = http.createServer(app);

// ============================================================
// 初始化 WebSocket 服务（设备通道 /ws，使用 noServer 模式）
// ============================================================
const wss = initWebSocket();

// ============================================================
// 初始化服务器运维监控模块（独立 WS：/ws/monitor，完全解耦原有业务）
// 包 try/catch：即便监控模块启动异常，也不影响主服务（模块降级，其余 API 正常）
// 返回监控 WS 实例（noServer 模式），与设备 /ws 共用同一 http server。
// ============================================================
let monitorWss = null;
try {
  const monitorModule = require('./modules/server-monitor');
  monitorWss = monitorModule.initMonitor();
  logger.info('[Monitor] 运维监控模块已挂载');
} catch (e) {
  logger.error(`[Monitor] 运维监控模块初始化失败（已降级，不影响主服务）: ${e.stack || e.message}`);
}

// ============================================================
// 统一 WebSocket upgrade 路由（关键修复）
// 多个 WebSocketServer 共享同一 http server 时，若使用 server 选项会各自注册
// 不过滤 path 的 upgrade 监听器，导致同一次连接被双处理 → 浏览器报
// "Invalid frame header" / 客户端报 "RSV1 must be clear"。
// 因此所有 server 均采用 noServer:true，此处按 path 唯一分发，杜绝重复处理。
// ============================================================
server.on('upgrade', (req, socket, head) => {
  const pathname = req.url ? req.url.split('?')[0] : '';
  try {
    if (pathname === '/ws/monitor' && monitorWss) {
      monitorWss.handleUpgrade(req, socket, head, (ws) => monitorWss.emit('connection', ws, req));
    } else if (pathname === '/ws') {
      wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
    } else {
      // 非本服务 WS 路径：直接关闭，避免 socket 悬挂
      socket.destroy();
    }
  } catch (err) {
    logger.error(`[WS] upgrade 路由处理失败: ${err.message}`);
    socket.destroy();
  }
});

// ============================================================
// 服务启动
// ============================================================
async function start() {
  try {
    // 校验配置
    validateConfig();
    logger.info('配置校验通过');

    // 初始化数据库
    await initDatabases();
    logger.info('数据库连接初始化完成');

    // 初始化 AI Provider
    try {
      await initializeProviders();
    } catch (err) {
      logger.warn(`AI Provider 初始化失败（不影响服务启动）: ${err.message}`);
    }

    // 启动临时文件清理定时器
    startScheduler();

    // 启动 HTTP Server
    server.listen(config.port, () => {
      logger.info('='.repeat(50));
      logger.info('  AI Cast Hub 服务已启动');
      logger.info(`  HTTP:      http://localhost:${config.port}`);
      logger.info(`  WebSocket: ws://localhost:${config.port}/ws`);
      logger.info(`  环境:      ${config.nodeEnv}`);
      logger.info('='.repeat(50));
    });
  } catch (err) {
    logger.error(`服务启动失败: ${err.message}`);
    process.exit(1);
  }
}

// ============================================================
// 优雅关闭
// ============================================================
async function shutdown(signal) {
  logger.info(`收到 ${signal} 信号，正在优雅关闭...`);

  // 停止临时文件清理
  stopScheduler();

  // 关闭 WebSocket Server
  await new Promise((resolve) => {
    wss.close(() => {
      logger.info('WebSocket 服务已关闭');
      resolve();
    });
  });

  // 关闭 HTTP Server
  await new Promise((resolve) => {
    server.close(() => {
      logger.info('HTTP 服务已关闭');
      resolve();
    });
  });

  // 关闭数据库连接
  await closeDatabases();

  logger.info('服务已完全关闭');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// 未捕获异常处理
process.on('uncaughtException', (err) => {
  logger.error(`未捕获异常: ${err.message}`, { stack: err.stack });
  shutdown('uncaughtException');
});

process.on('unhandledRejection', (reason) => {
  logger.error(`未处理的 Promise 拒绝: ${reason}`);
});

// ============================================================
// 启动！
// ============================================================
start();

module.exports = { app, server, logger, wss };
