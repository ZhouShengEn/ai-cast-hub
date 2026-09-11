/**
 * 服务器监控模块 — 模块入口
 *
 * 解耦原则：本模块完全独立，不依赖、不修改原有投屏 / WebRTC / 设备等业务。
 * - router: 挂载到 /api/v1/server-monitor
 * - initMonitor(server): 初始化配置、刷新沙箱、重建 Nginx 关联、挂载独立 WS
 *
 * 在 src/routes/index.js 中挂载 router；在 src/index.js 中调用 initMonitor(server)。
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
 * @param {import('http').Server} server
 */
function initMonitor(server) {
  bootstrap();
  return wsHub.initMonitorWs(server);
}

module.exports = { router, initMonitor, bootstrap };
