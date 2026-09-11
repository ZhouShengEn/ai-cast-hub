/**
 * 服务器监控模块 — REST API 路由
 *
 * 挂载于 /api/v1/server-monitor
 * 复用全局 deviceAuth（已在 src/index.js 中统一包裹），此处仅补充角色与权限。
 *
 * 约定响应：{ code:0, data, message }；错误 code 非 0。
 */

const { Router } = require('express');
const config = require('./config');
const commandRunner = require('./commandRunner');
const aggregator = require('./serviceAggregator');
const permission = require('./permission');
const processManager = require('./processManager');
const gitService = require('./gitService');
const nginxManager = require('./nginxManager');
const audit = require('./audit');
const logService = require('./logService');
const wsHub = require('./wsHub');
const { decodeProjectId } = require('./ids');
const { isValidPort } = require('./constants');
const logger = require('../../utils/logger');

const router = Router();

const ok = (res, data, message = 'ok') => res.json({ code: 0, data, message });
const fail = (res, status, message) => res.status(status).json({ code: status, data: null, message });

/** 角色注入中间件 */
router.use(permission.attachRole);

/** 解码项目 id -> 路径，失败 400 */
function resolvePath(req, res) {
  const id = req.params.id;
  const p = decodeProjectId(id);
  if (!p) { res.status(400); res.json({ code: 400, data: null, message: '无效的项目 ID' }); return null; }
  return p;
}

// ============================================================
// 配置
// ============================================================
router.get('/config', (req, res) => ok(res, config.get()));

router.put('/config', permission.requireAdmin, (req, res) => {
  try {
    const patch = req.body || {};
    const updated = config.update(patch);
    // 刷新沙箱根目录
    refreshSandbox();
    aggregator.forceRescan();
    ok(res, updated);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.post('/config/ignore', permission.requireAdmin, (req, res) => {
  const p = req.body && req.body.path;
  if (!p) return fail(res, 400, '缺少 path');
  const list = config.addIgnore(p);
  aggregator.forceRescan();
  ok(res, list);
});

router.delete('/config/ignore', permission.requireAdmin, (req, res) => {
  const p = req.query.path;
  if (!p) return fail(res, 400, '缺少 path');
  const list = config.removeIgnore(p);
  aggregator.forceRescan();
  ok(res, list);
});

// ============================================================
// 服务
// ============================================================
router.post('/scan', (req, res) => {
  try {
    const list = aggregator.forceRescan();
    ok(res, { count: list.length });
  } catch (e) {
    fail(res, 500, e.message);
  }
});

router.get('/services', async (req, res) => {
  try {
    const services = await aggregator.getServices(true);
    ok(res, services);
  } catch (e) {
    fail(res, 500, e.message);
  }
});

router.get('/services/external', async (req, res) => {
  try {
    const ext = await aggregator.getExternalServices();
    ok(res, ext);
  } catch (e) {
    fail(res, 500, e.message);
  }
});

router.get('/services/:id', async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const status = processManager.getStatus(p);
    const git = await gitService.getStatus(p);
    const override = require('./projectStore').getOverrides(p);
    let nginxLink = null;
    if (override.nginxLinkId) {
      const link = nginxManager.getLink(override.nginxLinkId);
      if (link) nginxLink = { linkId: link.id, proxyPort: link.proxyPort, serverName: link.serverName, configFile: link.configFile };
    }
    ok(res, { ...status, git, nginxLink, env: override.env || [], portLocked: !!override.nginxLinkId, port: override.port != null ? Number(override.port) : status.port });
  } catch (e) {
    fail(res, 500, e.message);
  }
});

router.post('/services/:id/start', permission.requireAdmin, async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const status = await aggregator.startService(p, req.deviceUuid, req.monitorRole);
    ok(res, status);
  } catch (e) {
    wsHub.broadcastAlert({ level: 'error', kind: 'action_failed', message: `启动失败「${require('path').basename(p)}」: ${e.message}`, servicePath: p });
    fail(res, 400, e.message);
  }
});

router.post('/services/:id/stop', permission.requireAdmin, async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const r = await aggregator.stopService(p, req.deviceUuid, req.monitorRole);
    ok(res, r);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.post('/services/:id/restart', permission.requireAdmin, async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const status = await aggregator.restartService(p, req.deviceUuid, req.monitorRole);
    ok(res, status);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.post('/services/:id/build', permission.requireAdmin, async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const result = await aggregator.buildService(p, req.deviceUuid, req.monitorRole,
      (line, level) => wsHub.broadcastLogLine(req.params.id, line, level));
    ok(res, result);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.get('/services/:id/logs', async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  const lines = parseInt(req.query.lines, 10) || 500;
  const logFile = processManager.logPathFor(p);
  const r = await logService.readRecent(logFile, lines);
  if (!r.ok) return fail(res, 404, r.message || '无日志');
  ok(res, { content: r.content, path: r.path });
});

// Git
router.get('/services/:id/git', async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const status = await gitService.getStatus(p);
    ok(res, status);
  } catch (e) {
    fail(res, 500, e.message);
  }
});

router.post('/services/:id/git/pull', permission.requireAdmin, async (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  const rebase = !!req.body?.rebase;
  try {
    const result = await aggregator.pullService(p, req.deviceUuid, req.monitorRole, { rebase },
      (line, level) => wsHub.broadcastLogLine(req.params.id, line, level));
    ok(res, result);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

// 配置类（端口 / 环境变量 / 脚本覆盖 / 显示名）
router.put('/services/:id/port', permission.requireAdmin, (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  const port = req.body?.port;
  if (port != null && !isValidPort(port)) return fail(res, 400, '端口非法');
  try {
    const override = aggregator.setPort(p, port, req.deviceUuid, req.monitorRole);
    ok(res, override);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.put('/services/:id/env', permission.requireAdmin, (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  const env = req.body?.env;
  if (!Array.isArray(env)) return fail(res, 400, 'env 必须为数组');
  try {
    const override = aggregator.setEnv(p, env, req.deviceUuid, req.monitorRole);
    ok(res, override);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.put('/services/:id/script', permission.requireAdmin, (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  const { customScript, typeOverride } = req.body || {};
  try {
    const override = aggregator.setScriptOverride(p, customScript, typeOverride, req.deviceUuid, req.monitorRole);
    ok(res, override);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

router.put('/services/:id/display-name', permission.requireAdmin, (req, res) => {
  const p = resolvePath(req, res); if (!p) return;
  try {
    const override = aggregator.setDisplayName(p, req.body?.name, req.deviceUuid, req.monitorRole);
    ok(res, override);
  } catch (e) {
    fail(res, 400, e.message);
  }
});

// ============================================================
// Nginx
// ============================================================
router.get('/nginx/configs', (req, res) => ok(res, nginxManager.listConfigs()));
router.get('/nginx/configs/:id', (req, res) => {
  try {
    ok(res, nginxManager.getConfigContent(req.params.id));
  } catch (e) {
    fail(res, 400, e.message);
  }
});
router.put('/nginx/configs/:id', permission.requireAdmin, async (req, res) => {
  try {
    const r = await aggregator.saveNginxConfig(req.params.id, req.body?.content || '', req.deviceUuid, req.monitorRole);
    if (!r.ok) return fail(res, 400, r.error || '保存失败');
    ok(res, r);
  } catch (e) {
    fail(res, 400, e.message);
  }
});
router.post('/nginx/test', async (req, res) => {
  try { ok(res, await nginxManager.testConfig()); } catch (e) { fail(res, 500, e.message); }
});
router.post('/nginx/reload', permission.requireAdmin, async (req, res) => {
  try { ok(res, await aggregator.nginxReload(req.deviceUuid, req.monitorRole)); } catch (e) { fail(res, 400, e.message); }
});
router.post('/nginx/control', permission.requireAdmin, async (req, res) => {
  try { ok(res, await aggregator.nginxControl(req.body?.action, req.deviceUuid, req.monitorRole)); } catch (e) { fail(res, 400, e.message); }
});
router.get('/nginx/logs/:type', async (req, res) => {
  try {
    const lines = parseInt(req.query.lines, 10) || 200;
    const r = await nginxManager.getLogs(req.params.type, lines);
    if (!r.ok) return fail(res, 404, r.message);
    ok(res, r);
  } catch (e) { fail(res, 500, e.message); }
});
router.get('/nginx/links', (req, res) => ok(res, aggregator.getNginxLinks()));
router.post('/nginx/links', permission.requireAdmin, (req, res) => {
  try {
    const { projectPath, configId, port } = req.body || {};
    if (!projectPath || !configId || !port) return fail(res, 400, '缺少参数');
    const link = aggregator.setNginxLink(projectPath, configId, port, req.deviceUuid, req.monitorRole);
    ok(res, link);
  } catch (e) { fail(res, 400, e.message); }
});
router.delete('/nginx/links/:linkId', permission.requireAdmin, (req, res) => {
  try {
    const r = aggregator.removeNginxLink(req.params.linkId, req.deviceUuid, req.monitorRole);
    ok(res, { removed: r });
  } catch (e) { fail(res, 400, e.message); }
});

// ============================================================
// 审计
// ============================================================
router.get('/audit', (req, res) => {
  const page = parseInt(req.query.page, 10) || 1;
  const pageSize = parseInt(req.query.pageSize, 10) || 50;
  ok(res, audit.query({ page, pageSize, action: req.query.action, serviceName: req.query.serviceName }));
});
router.get('/audit/export', permission.requireAdmin, (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Disposition', 'attachment; filename="monitor-audit.json"');
  res.send(audit.exportAll());
});

// ============================================================
// 系统 / 角色
// ============================================================
router.get('/system', async (req, res) => {
  try { ok(res, await require('./systemInfo').getSystemInfo()); } catch (e) { fail(res, 500, e.message); }
});

router.get('/roles', permission.requireAdmin, (req, res) => ok(res, config.get().roles));
router.put('/roles/:deviceUuid', permission.requireAdmin, (req, res) => {
  try {
    const role = req.body?.role;
    const r = config.setRole(req.params.deviceUuid, role);
    ok(res, r);
  } catch (e) { fail(res, 400, e.message); }
});

// 健康检查
router.get('/health', (req, res) => ok(res, { status: 'ok' }));

/** 刷新沙箱根目录（配置变更后调用） */
function refreshSandbox() {
  const c = config.get();
  const roots = [c.scanRoot];
  if (c.useSystemNginx) roots.push('/etc/nginx');
  for (const d of (c.nginxConfigDirs || [])) roots.push(d);
  commandRunner.setSandboxRoots(roots);
}

module.exports = { router, refreshSandbox };
