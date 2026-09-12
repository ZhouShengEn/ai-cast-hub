/**
 * 服务器监控模块 — WebSocket 实时推送中心
 *
 * 独立挂载于 /ws/monitor，与原有 /ws（设备投屏）完全解耦。
 * 协议：{ type, payload }
 *
 * 推送内容：
 *  - auth：连接成功，下发角色（admin/readonly）
 *  - snapshot：首屏全量数据（服务 / 外部服务 / Nginx 关联 / 系统 / 配置）
 *  - services_update：服务状态增量更新
 *  - system_update：系统资源更新
 *  - nginx_links_update：Nginx 关联更新
 *  - log_line：某服务日志增量（订阅后推送）
 *  - alert：异常告警（宕机 / 配置变更 / 端口冲突）
 *
 * 断线自动重连由前端处理；服务端重连后重发 snapshot。
 */

const { WebSocketServer } = require('ws');
const config = require('./config');
const permission = require('./permission');
const aggregator = require('./serviceAggregator');
const processManager = require('./processManager');
const logService = require('./logService');
const nginxManager = require('./nginxManager');
const { decodeProjectId } = require('./ids');
const { getRole } = permission;
const logger = require('../../utils/logger');

let wss = null;
const clients = new Set();

/** 每个连接的日志订阅：ws -> { stopFn } */
const subscriptions = new WeakMap();

/** 上一次服务状态（用于变更告警） */
let _prevStatus = new Map();

/**
 * 注册进程状态变更监听：启动 / 退出 / 就绪等瞬间状态变化立即推送，
 * 不必等下一个 3 秒轮询周期（P1-6「启动后 30 秒内状态实时推送」）。
 */
function registerProcessStatusListener() {
  processManager.onStatusChange(({ projectPath, status }) => {
    broadcast('service_status', {
      id: status.id,
      projectPath,
      status: status.status,
      statusText: status.statusText,
      running: status.running,
      listening: status.listening,
      health: status.health,
      pid: status.pid,
      port: status.port,
      proxyCheck: status.proxyCheck || null,
      serverTime: new Date().toISOString(),
    });
  });
}

/**
 * 初始化监控 WS。
 * @param {import('http').Server} server
 */
function initMonitorWs() {
  if (wss) return wss;
  // 使用 noServer: 与设备 /ws 共用同一 http server，由 src/index.js 统一 upgrade
  // 路由按 path 分发，避免两个 WebSocketServer 同时处理同一连接导致帧解析错误。
  wss = new WebSocketServer({ noServer: true });
  logger.info('[Monitor] WebSocket 已挂载到 /ws/monitor');

  wss.on('connection', async (ws, req) => {
    // 认证：复用设备身份（URL 参数 deviceUuid + transferKey）
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const deviceUuid = url.searchParams.get('deviceUuid');
    const transferKey = url.searchParams.get('transferKey');

    let device = null;
    try {
      const DeviceModel = require('../../models/Device');
      if (deviceUuid) device = await DeviceModel.findByUuid(deviceUuid);
    } catch (e) {
      logger.warn(`[Monitor] 设备模型查询失败: ${e.message}`);
    }

    if (!device || (transferKey && device.transfer_key !== transferKey)) {
      ws.send(JSON.stringify({ type: 'error', payload: { message: '认证失败' } }));
      ws.close(4001, 'auth failed');
      return;
    }
    const role = getRole(deviceUuid);

    clients.add(ws);
    ws._deviceUuid = deviceUuid;

    // 发送认证 + 角色
    send(ws, 'auth', { role, deviceUuid });

    // 发送首屏快照
    await sendSnapshot(ws);

    // 消息处理
    ws.on('message', async (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'subscribe_log') {
          handleSubscribeLog(ws, msg.payload);
        } else if (msg.type === 'unsubscribe_log') {
          handleUnsubscribeLog(ws);
        } else if (msg.type === 'ping') {
          send(ws, 'pong', {});
        }
      } catch (e) {
        send(ws, 'error', { message: '消息格式无效' });
      }
    });

    ws.on('close', () => {
      clients.delete(ws);
      const stop = subscriptions.get(ws);
      if (stop) { stop(); subscriptions.delete(ws); }
    });
    ws.on('error', () => { clients.delete(ws); });
  });

  // 启动周期推送
  registerProcessStatusListener();
  startPolling();

  return wss;
}

function send(ws, type, payload) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify({ type, payload }));
  }
}

function broadcast(type, payload) {
  const data = JSON.stringify({ type, payload });
  for (const ws of clients) {
    if (ws.readyState === 1) ws.send(data);
  }
}

/** 向所有连接推送告警 */
function broadcastAlert(alert) {
  broadcast('alert', alert);
}

/** 推送日志行（由 REST 流式动作回调调用） */
function broadcastLogLine(projectId, line, level) {
  broadcast('log_line', { projectId, line, level: level || 'INFO' });
}

/** 发送首屏快照 */
async function sendSnapshot(ws) {
  try {
    const services = await aggregator.getServices();
    const external = await aggregator.getExternalServices();
    const nginxLinks = aggregator.getNginxLinks();
    const system = await require('./systemInfo').getSystemInfo();
    send(ws, 'snapshot', {
      services,
      external,
      nginxLinks,
      system,
      config: config.get(),
      serverTime: new Date().toISOString(),
    });
  } catch (e) {
    logger.error(`[Monitor] 快照发送失败: ${e.message}`);
  }
}

function handleSubscribeLog(ws, payload) {
  // 清理旧订阅
  const old = subscriptions.get(ws);
  if (old) old();

  const projectId = payload?.id;
  if (!projectId) return;
  const projectPath = decodeProjectId(projectId);
  if (!projectPath) return;
  const logFile = processManager.externalLogPath(projectPath)
    || processManager.pm2LogPathFor(projectPath)
    || processManager.logPathFor(projectPath);
  try {
    const stop = logService.watch(logFile, (chunk) => {
      // 按行推送，附带分级（前端再渲染颜色）
      const lines = chunk.split('\n').filter(Boolean);
      for (const line of lines) {
        const level = /\[ERROR\]/.test(line) ? 'ERROR' : /\[WARN\]/.test(line) ? 'WARN' : 'INFO';
        send(ws, 'log_line', { projectId, line, level });
      }
    }, 1000);
    subscriptions.set(ws, stop);
    // 立即补发最近 200 行
    logService.readRecent(logFile, 200).then((r) => {
      if (r.ok) send(ws, 'log_history', { projectId, content: r.content });
    });
  } catch (e) {
    send(ws, 'log_line', { projectId, line: '日志监听失败: ' + e.message, level: 'ERROR' });
  }
}

function handleUnsubscribeLog(ws) {
  const stop = subscriptions.get(ws);
  if (stop) { stop(); subscriptions.delete(ws); }
}

/** 周期推送：状态 / 系统 / Nginx 关联 + 变更告警 */
function startPolling() {
  const tick = async () => {
    const cfg = config.get();
    try {
      const services = await aggregator.getServices(false);
      // 变更检测
      detectAlerts(services);
      broadcast('services_update', { services, serverTime: new Date().toISOString() });

      const system = await require('./systemInfo').getSystemInfo();
      broadcast('system_update', { system });

      const nginxLinks = aggregator.getNginxLinks();
      broadcast('nginx_links_update', { nginxLinks });

      // Nginx 配置 MD5 变更告警
      const changed = nginxManager.detectConfigChanges();
      if (changed.length) {
        for (const c of changed) {
          broadcastAlert({ level: 'warning', kind: 'nginx_changed', message: `关联 Nginx 配置已变更，请核对端口: ${c.configFile}`, configFile: c.configFile });
        }
        broadcast('nginx_links_update', { nginxLinks: aggregator.getNginxLinks() });
      }
    } catch (e) {
      logger.error(`[Monitor] 周期推送失败: ${e.message}`);
    } finally {
      setTimeout(tick, cfg.refreshIntervalMs || 3000);
    }
  };
  setTimeout(tick, 1000);
}

function detectAlerts(services) {
  for (const s of services) {
    const prev = _prevStatus.get(s.path);
    if (prev && prev.running && !s.running) {
      broadcastAlert({
        level: 'error',
        kind: 'service_down',
        message: `服务「${s.name}」已停止运行`,
        serviceName: s.name,
        servicePath: s.path,
      });
    }
    _prevStatus.set(s.path, { running: s.running });
  }
  // 清理已不存在的服务
  const curPaths = new Set(services.map((s) => s.path));
  for (const p of _prevStatus.keys()) {
    if (!curPaths.has(p)) _prevStatus.delete(p);
  }
}

module.exports = { initMonitorWs, broadcast, broadcastAlert, broadcastLogLine };
