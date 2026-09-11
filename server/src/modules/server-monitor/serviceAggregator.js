/**
 * 服务器监控模块 — 服务聚合器（编排层）
 *
 * 统一产出「完整服务列表」（含运行时状态 / Git / Nginx 关联），
 * 并封装所有运维动作（启停 / 重启 / 编译 / 拉取 / 配置修改），
 * 动作内统一写审计日志、校验权限与端口锁定。
 *
 * 本模块不依赖 WebSocket，便于 REST 与 WS 共用；流式输出通过 onLine 回调外抛。
 */

const config = require('./config');
const projectStore = require('./projectStore');
const scanner = require('./scanner');
const processManager = require('./processManager');
const nginxManager = require('./nginxManager');
const gitService = require('./gitService');
const audit = require('./audit');
const { encodeProjectId, decodeProjectId } = require('./ids');
const logger = require('../../utils/logger');

/** Git 状态缓存（减少网络探测频率） */
const _gitCache = new Map();
const GIT_CACHE_TTL = 30 * 1000;

async function getGitStatusCached(projectPath) {
  const cached = _gitCache.get(projectPath);
  const now = Date.now();
  if (cached && now - cached.ts < GIT_CACHE_TTL) return cached.data;
  // 异步刷新，立即返回旧值或占位
  try {
    const data = await gitService.getStatus(projectPath);
    _gitCache.set(projectPath, { data, ts: now });
    return data;
  } catch (e) {
    return { status: 'error', message: e.message };
  }
}

/**
 * 获取完整服务列表（含状态 / Git / Nginx 关联）。
 * @param {boolean} withGit 是否附带 Git 状态（默认 true，带缓存）
 */
async function getServices(withGit = true) {
  const projects = scanner.scan();
  const services = [];
  for (const proj of projects) {
    const status = processManager.getStatus(proj.path);
    const override = projectStore.getOverrides(proj.path);
    let git = null;
    if (withGit) {
      git = await getGitStatusCached(proj.path);
    }
    // Nginx 关联信息
    let nginxLink = null;
    if (override.nginxLinkId) {
      const link = nginxManager.getLink(override.nginxLinkId);
      if (link) nginxLink = { linkId: link.id, proxyPort: link.proxyPort, serverName: link.serverName, configFile: link.configFile };
    }
    services.push({
      ...status,
      name: proj.name,
      type: proj.type,
      source: override.typeOverride ? 'custom' : status.source,
      signals: proj.signals,
      git,
      nginxLink,
      port: override.port != null ? Number(override.port) : status.port,
      portLocked: !!override.nginxLinkId,
      env: override.env || [],
    });
  }
  return services;
}

/** 获取外部托管服务（pm2 / systemd / docker） */
async function getExternalServices() {
  return processManager.detectExternalServices();
}

/** 获取 Nginx 关联列表 */
function getNginxLinks() {
  return nginxManager.getLinks();
}

/** 强制重扫 */
function forceRescan() {
  scanner.invalidate();
  return scanner.scan(true);
}

// ============================================================
// 运维动作（统一审计 + 权限 + 端口锁定）
// ============================================================

function auditAction(entry) {
  return audit.log(entry);
}

async function startService(projectPath, operator, role) {
  const name = pathBasename(projectPath);
  try {
    const status = await processManager.start(projectPath, { operator });
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'start', success: true, detail: `pid=${status.pid}` });
    return { ok: true, status };
  } catch (e) {
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'start', success: false, detail: e.message });
    throw e;
  }
}

async function stopService(projectPath, operator, role) {
  const name = pathBasename(projectPath);
  try {
    const res = await processManager.stop(projectPath, { operator });
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'stop', success: true });
    return { ok: true, result: res };
  } catch (e) {
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'stop', success: false, detail: e.message });
    throw e;
  }
}

async function restartService(projectPath, operator, role) {
  const name = pathBasename(projectPath);
  try {
    const status = await processManager.restart(projectPath, { operator });
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'restart', success: true });
    return { ok: true, status };
  } catch (e) {
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'restart', success: false, detail: e.message });
    throw e;
  }
}

async function buildService(projectPath, operator, role, onLine) {
  const name = pathBasename(projectPath);
  try {
    const res = await processManager.build(projectPath, onLine);
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'build', success: true });
    return { ok: true, result: res };
  } catch (e) {
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'build', success: false, detail: e.message });
    throw e;
  }
}

async function pullService(projectPath, operator, role, opts, onLine) {
  const name = pathBasename(projectPath);
  try {
    const res = await gitService.pull(projectPath, { ...opts, onLine });
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'git_pull', success: true });
    return { ok: true, result: res };
  } catch (e) {
    auditAction({ operator: `${operator}(${role})`, serviceName: name, servicePath: projectPath, action: 'git_pull', success: false, detail: e.message });
    throw e;
  }
}

// ---- 配置类动作 ----

function setPort(projectPath, port, operator, role) {
  const override = projectStore.getOverrides(projectPath);
  if (override.nginxLinkId) {
    const link = nginxManager.getLink(override.nginxLinkId);
    if (link && Number(port) !== link.proxyPort) {
      throw new Error(`该服务端口已被 Nginx 锁定为 ${link.proxyPort}，禁止修改为 ${port}。请先解除 Nginx 关联或同步修改 proxy_pass。`);
    }
  }
  if (!port) {
    projectStore.setOverride(projectPath, { port: null });
  } else {
    projectStore.setOverride(projectPath, { port: Number(port) });
  }
  auditAction({ operator: `${operator}(${role})`, serviceName: pathBasename(projectPath), servicePath: projectPath, action: 'set_port', success: true, detail: `port=${port}` });
  return projectStore.getOverrides(projectPath);
}

function setEnv(projectPath, envArray, operator, role) {
  projectStore.setOverride(projectPath, { env: envArray });
  auditAction({ operator: `${operator}(${role})`, serviceName: pathBasename(projectPath), servicePath: projectPath, action: 'set_env', success: true });
  return projectStore.getOverrides(projectPath);
}

function setScriptOverride(projectPath, customScript, typeOverride, operator, role) {
  projectStore.setOverride(projectPath, { customScript, typeOverride });
  auditAction({ operator: `${operator}(${role})`, serviceName: pathBasename(projectPath), servicePath: projectPath, action: 'set_script', success: true });
  return projectStore.getOverrides(projectPath);
}

function setDisplayName(projectPath, name, operator, role) {
  projectStore.setOverride(projectPath, { displayName: name });
  scanner.invalidate();
  return projectStore.getOverrides(projectPath);
}

// ---- Nginx 动作 ----

async function saveNginxConfig(id, content, operator, role) {
  const res = await nginxManager.saveConfigContent(id, content);
  auditAction({ operator: `${operator}(${role})`, serviceName: '-', servicePath: id, action: 'nginx_edit', success: res.ok, detail: res.ok ? '保存成功' : (res.error || '校验失败') });
  if (res.ok) nginxManager.rebuildLinks();
  return res;
}

async function nginxReload(operator, role) {
  const res = await nginxManager.reload();
  auditAction({ operator: `${operator}(${role})`, serviceName: '-', servicePath: '-', action: 'nginx_reload', success: res.ok, detail: res.message });
  return res;
}

async function nginxControl(action, operator, role) {
  const res = await nginxManager.nginxControl(action);
  auditAction({ operator: `${operator}(${role})`, serviceName: '-', servicePath: '-', action: `nginx_${action}`, success: res.ok, detail: res.message });
  return res;
}

function setNginxLink(projectPath, configId, port, operator, role) {
  const link = nginxManager.setLink(projectPath, configId, port);
  auditAction({ operator: `${operator}(${role})`, serviceName: pathBasename(projectPath), servicePath: projectPath, action: 'nginx_link', success: true, detail: `link=${link.id}` });
  return link;
}

function removeNginxLink(linkId, operator, role) {
  const res = nginxManager.removeLink(linkId);
  auditAction({ operator: `${operator}(${role})`, serviceName: '-', servicePath: '-', action: 'nginx_unlink', success: res, detail: `link=${linkId}` });
  return res;
}

function pathBasename(p) {
  const path = require('path');
  return path.basename(p);
}

module.exports = {
  getServices,
  getExternalServices,
  getNginxLinks,
  forceRescan,
  startService,
  stopService,
  restartService,
  buildService,
  pullService,
  setPort,
  setEnv,
  setScriptOverride,
  setDisplayName,
  saveNginxConfig,
  nginxReload,
  nginxControl,
  setNginxLink,
  removeNginxLink,
};
