/**
 * 服务器监控模块 — 模块入口
 *
 * 解耦原则：本模块完全独立，不依赖、不修改原有投屏 / WebRTC / 设备等业务。
 * - router: 挂载到 /api/v1/server-monitor
 * - initMonitor(): 初始化配置、刷新沙箱、重建 Nginx 关联、返回 noServer 模式 WS 实例
 *
 * 在 src/routes/index.js 中挂载 router；在 src/index.js 中调用 initMonitor()，
 * 由 src/index.js 统一 upgrade 路由按 path 分发到本模块 WS（/ws/monitor）。
 */

const config = require('./config');
const projectStore = require('./projectStore');
const { router, refreshSandbox } = require('./routes');
const nginxManager = require('./nginxManager');
const wsHub = require('./wsHub');
const logger = require('../../utils/logger');

/** 模块引导：加载配置、设置沙箱、重建 Nginx 关联 */
function bootstrap() {
  config.load();
  projectStore.load();
  refreshSandbox();
  try {
    nginxManager.rebuildLinks();
  } catch (e) {
    logger.warn(`[Monitor] Nginx 关联重建跳过: ${e.message}`);
  }
  logger.info('[Monitor] 模块已引导初始化');
}

/**
 * 初始化监控模块（挂载 WS 到 HTTP Server）。
 * 返回监控 WS 实例（noServer 模式），由 src/index.js 统一 upgrade 路由挂载。
 */
function initMonitor() {
  bootstrap();
  return wsHub.initMonitorWs();
}

module.exports = { router, initMonitor, bootstrap };
