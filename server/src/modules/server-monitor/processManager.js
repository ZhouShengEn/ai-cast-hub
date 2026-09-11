/**
 * 服务器监控模块 — 进程管理器（运行时核心）
 *
 * 职责：
 *  - 启停 / 重启项目（自动生成脚本 或 用户自定义脚本）
 *  - 跟踪 PID、端口、运行时长、CPU / 内存占用
 *  - 检测 pm2 / systemd / docker 等外部托管服务并合并状态
 *  - Nginx 关联服务的端口锁定校验
 *  - 日志写入（每个服务独立日志文件，供前端流式查看）
 *
 * 命令均经由 commandRunner（白名单 + 沙箱 + 无 shell）。
 */

const fs = require('fs');
const path = require('path');
const config = require('./config');
const projectStore = require('./projectStore');
const { generate, applyOverride } = require('./scriptGenerator');
const scanner = require('./scanner');
const commandRunner = require('./commandRunner');
const { encodeProjectId, decodeProjectId } = require('./ids');
const {
  isPidAlive, readProcStat, computeCpuPercent, isPortListening,
} = require('./util');
const logger = require('../../utils/logger');

const LOG_DIR = path.join(config.DATA_DIR, 'logs');
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

const RUNTIME_FILE = path.join(config.DATA_DIR, 'runtime.json');
let _runtime = loadRuntime();

function loadRuntime() {
  try {
    if (fs.existsSync(RUNTIME_FILE)) return JSON.parse(fs.readFileSync(RUNTIME_FILE, 'utf8')) || {};
  } catch {}
  return {};
}
function saveRuntime() {
  try { fs.writeFileSync(RUNTIME_FILE, JSON.stringify(_runtime, null, 2)); } catch (e) {
    logger.error(`[Monitor] runtime 保存失败: ${e.message}`);
  }
}
function logPathFor(projectPath) {
  const id = encodeProjectId(projectPath);
  return path.join(LOG_DIR, `${id}.log`);
}

/** CPU 采样缓存：pid -> { sample, ts } */
const _cpuSamples = new Map();

/** 追加日志到服务日志文件 */
function appendLog(projectPath, chunk, level = 'INFO') {
  try {
    const p = logPathFor(projectPath);
    const ts = new Date().toISOString();
    const line = `[${ts}] [${level}] ${chunk}`;
    fs.appendFile(p, line.endsWith('\n') ? line : line + '\n', () => {});
  } catch (e) { /* 忽略日志写入错误，避免影响主流程 */ }
}

/**
 * 构造某项目的完整脚本描述（合并自动生成 + 用户覆盖）。
 */
function buildScript(projectPath) {
  // 从扫描结果取静态信息
  const projects = scanner.scan();
  const proj = projects.find((p) => p.path === projectPath);
  if (!proj) throw new Error(`项目未找到: ${projectPath}`);
  const override = projectStore.getOverrides(projectPath);
  const script = generate(proj, override.customScript ? { ...override.customScript, type: override.typeOverride } : null);
  if (override.typeOverride) script.type = override.typeOverride;
  return { proj, script, override };
}

/**
 * 端口锁定校验：若项目已关联 Nginx，启动前强制校验端口一致性。
 * @returns {{ ok:boolean, lockedPort?:number, message?:string }}
 */
function checkPortLock(projectPath) {
  const override = projectStore.getOverrides(projectPath);
  const linkId = override.nginxLinkId;
  if (!linkId) return { ok: true, lockedPort: null };
  const nginxManager = require('./nginxManager');
  const link = nginxManager.getLink(linkId);
  if (!link) {
    // 关联失效，清理
    projectStore.setOverride(projectPath, { nginxLinkId: null });
    return { ok: true, lockedPort: null };
  }
  const desiredPort = override.port != null ? Number(override.port) : (buildScript(projectPath).script.port);
  if (link.proxyPort !== desiredPort) {
    return {
      ok: false,
      lockedPort: link.proxyPort,
      message: `该服务已关联 Nginx 反向代理，绑定端口被锁定为 ${link.proxyPort}。当前端口 ${desiredPort} 与 Nginx 配置不一致，禁止启动。请先同步修改 Nginx proxy_pass 端口或解除关联。`,
    };
  }
  return { ok: true, lockedPort: link.proxyPort };
}

/**
 * 启动项目。
 * @param {string} projectPath
 * @param {object} [opts] { operator }
 * @returns {Promise<object>} 运行时状态
 */
async function start(projectPath, opts = {}) {
  const { proj, script, override } = buildScript(projectPath);
  if (!script.start) {
    throw new Error('该项目无可执行的启动脚本（可能为 Nginx 站点或未知类型，请在 Web 端配置）。');
  }

  // 端口锁定校验
  const lock = checkPortLock(projectPath);
  if (!lock.ok) {
    throw new Error(lock.message);
  }

  // 若已运行，先视为运行中
  const existing = _runtime[projectPath];
  if (existing && existing.pid && isPidAlive(existing.pid)) {
    throw new Error(`服务已在运行 (pid=${existing.pid})`);
  }

  const port = override.port != null ? Number(override.port) : script.port;

  // 端口占用双重校验（非锁定情况）
  if (port) {
    const occupied = await isPortListening(port);
    if (occupied && !(lock.lockedPort && lock.lockedPort === port)) {
      throw new Error(`端口 ${port} 已被占用，请更换端口或检查是否有其他服务在使用。`);
    }
  }

  // 注入自定义环境变量
  const env = {};
  if (override.env && Array.isArray(override.env)) {
    for (const e of override.env) {
      const idx = e.indexOf('=');
      if (idx > 0) env[e.slice(0, idx)] = e.slice(idx + 1);
    }
  }
  if (port && !env.PORT && !env.PORT) {
    // 部分框架读 PORT 环境变量；非强制，仅在有需要时注入提示
  }

  appendLog(projectPath, `>>> 启动服务 (${script.start.note})`, 'INFO');
  const child = await commandRunner.spawnService(
    { bin: script.start.bin, args: script.start.args, cwd: script.start.cwd, env },
    fs.createWriteStream(logPathFor(projectPath), { flags: 'a' })
  );

  _runtime[projectPath] = {
    pid: child.pid,
    port: port || null,
    startedAt: new Date().toISOString(),
    status: 'running',
    source: script.source === 'custom' ? 'custom' : 'auto',
    logFile: logPathFor(projectPath),
    operator: opts.operator || null,
  };
  saveRuntime();

  // 端口探测（启动后短暂等待）
  let listening = null;
  if (port) {
    await new Promise((r) => setTimeout(r, 1500));
    listening = await isPortListening(port);
    if (!listening) {
      appendLog(projectPath, `⚠️ 端口 ${port} 未在预期时间内监听，请检查日志。`, 'WARN');
    }
  }

  return getStatus(projectPath);
}

/**
 * 停止项目。
 */
async function stop(projectPath, opts = {}) {
  const { script } = buildScript(projectPath);
  const rt = _runtime[projectPath];
  appendLog(projectPath, '>>> 停止服务', 'INFO');

  // 脚本式停止（docker compose down / shell stop.sh）
  if (script.stop && script.stop.strategy === 'script' && script.stop.script) {
    const s = script.stop.script;
    const r = await commandRunner.run({ bin: s.bin, args: s.args, cwd: s.cwd }, {}, config.get().commandTimeoutSec * 1000);
    if (rt && rt.pid) await commandRunner.killProcess(rt.pid, config.get().stopGraceSec * 1000);
    delete _runtime[projectPath];
    saveRuntime();
    return { stopped: true, scriptOutput: r.stdout + r.stderr };
  }

  if (!rt || !rt.pid) {
    // 可能由外部托管（pm2/systemd/docker），尝试对应停止
    const ext = await stopExternal(projectPath);
    if (ext) return ext;
    delete _runtime[projectPath];
    saveRuntime();
    return { stopped: true, note: '无运行记录，已清理状态。' };
  }

  const res = await commandRunner.killProcess(rt.pid, config.get().stopGraceSec * 1000);
  delete _runtime[projectPath];
  saveRuntime();
  return { stopped: true, forced: res.forced };
}

/**
 * 重启 = 停止 + 启动。
 */
async function restart(projectPath, opts = {}) {
  try { await stop(projectPath, opts); } catch (_) {}
  // 等待端口释放
  await new Promise((r) => setTimeout(r, 1000));
  return start(projectPath, opts);
}

/**
 * 编译项目（一键编译），流式输出通过 appendLog + 回调推送给 WS。
 * @param {string} projectPath
 * @param {(line:string, level:string)=>void} [onLine]
 */
async function build(projectPath, onLine) {
  const { script } = buildScript(projectPath);
  if (!script.build) {
    throw new Error('该项目类型不支持一键编译（仅 Java/Go/Rust/.NET 支持）。');
  }
  const b = script.build;
  const emit = (chunk, level) => {
    appendLog(projectPath, chunk, level);
    if (onLine) onLine(chunk, level);
  };
  const result = await commandRunner.run(
    { bin: b.bin, args: b.args, cwd: b.cwd },
    { onStdout: (c) => emit(c, 'INFO'), onStderr: (c) => emit(c, 'ERROR') },
    config.get().commandTimeoutSec * 1000
  );
  if (result.code !== 0) {
    throw new Error(`编译失败 (exit=${result.code}): ${result.stderr.slice(0, 500)}`);
  }
  emit('>>> 编译完成', 'INFO');
  return { code: result.code, stdout: result.stdout, stderr: result.stderr };
}

/**
 * 读取某项目的运行时状态（含存活 / 端口 / 资源占用）。
 * @param {string} projectPath
 */
function getStatus(projectPath) {
  const rt = _runtime[projectPath];
  const { script } = (() => { try { return buildScript(projectPath); } catch { return { script: null }; } })();

  if (!rt || !rt.pid) {
    // 检查是否由外部托管
    const ext = getExternalStatus(projectPath);
    if (ext) return ext;
    return {
      id: encodeProjectId(projectPath),
      path: projectPath,
      running: false,
      status: 'stopped',
      pid: null,
      port: (script && script.port) || null,
      listening: null,
      startedAt: null,
      uptimeSec: 0,
      cpuPercent: null,
      memRssMb: null,
      nginxLinked: !!projectStore.getOverrides(projectPath).nginxLinkId,
      logFile: script ? logPathFor(projectPath) : null,
      scriptInfo: script ? { source: script.source, notes: script.notes } : null,
    };
  }

  const alive = isPidAlive(rt.pid);
  if (!alive) {
    delete _runtime[projectPath];
    saveRuntime();
    const ext = getExternalStatus(projectPath);
    if (ext) return ext;
    return {
      id: encodeProjectId(projectPath), running: false, status: 'stopped',
      pid: null, port: rt.port, listening: false, startedAt: null, uptimeSec: 0,
      cpuPercent: null, memRssMb: null, nginxLinked: !!projectStore.getOverrides(projectPath).nginxLinkId,
      logFile: logPathFor(projectPath), scriptInfo: script ? { source: script.source, notes: script.notes } : null,
    };
  }

  const sample = readProcStat(rt.pid);
  let cpu = null;
  if (sample) {
    const prev = _cpuSamples.get(rt.pid);
    const now = Date.now();
    if (prev) cpu = computeCpuPercent(prev.sample, sample, now - prev.ts);
    _cpuSamples.set(rt.pid, { sample, ts: now });
  }

  const startedAt = rt.startedAt ? new Date(rt.startedAt) : null;
  const uptimeSec = startedAt ? Math.floor((Date.now() - startedAt.getTime()) / 1000) : null;
  const port = rt.port != null ? rt.port : (script && script.port);

  return {
    id: encodeProjectId(projectPath),
    path: projectPath,
    running: true,
    status: 'running',
    pid: rt.pid,
    port,
    listening: port ? null : null, // 端口监听由 registry 统一探测填充
    startedAt: rt.startedAt,
    uptimeSec,
    cpuPercent: cpu,
    memRssMb: sample ? sample.memRssMb : null,
    nginxLinked: !!projectStore.getOverrides(projectPath).nginxLinkId,
    logFile: rt.logFile,
    scriptInfo: script ? { source: script.source, notes: script.notes } : null,
    operator: rt.operator || null,
  };
}

// ============================================================
// 外部托管服务（pm2 / systemd / docker）检测
// 仅做只读检测 + 通过各自 CLI 启停，不接管其 PID 生命周期
// ============================================================

/**
 * 检测当前系统所有 pm2 / systemd / docker 服务，返回描述数组。
 * 供 registry 合并进服务列表。这些服务的 source 为 pm2/systemd/docker。
 */
async function detectExternalServices() {
  const out = [];
  try {
    const pm2 = await commandRunner.run({ bin: 'pm2', args: ['jlist'] }, {}, 10000);
    if (pm2.code === 0) {
      const list = JSON.parse(pm2.stdout);
      for (const p of list) {
        out.push({
          id: encodeProjectId('pm2://' + p.name),
          name: p.name,
          type: 'node',
          source: 'pm2',
          pm2Name: p.name,
          pid: p.pid || null,
          running: p.pm2_env?.status === 'online',
          status: p.pm2_env?.status === 'online' ? 'running' : 'stopped',
          port: null,
          startedAt: p.pm2_env?.pm_uptime ? new Date(Number(p.pm2_env.pm_uptime)).toISOString() : null,
          cpuPercent: p.monit?.cpu ?? null,
          memRssMb: p.monit?.memory ? Math.round(p.monit.memory / 1024 / 1024 * 10) / 10 : null,
          path: p.pm2_env?.pm_cwd || null,
        });
      }
    }
  } catch (_) {}
  return out;
}

/** 读取某路径对应外部服务的运行时状态（用于 getStatus 兜底） */
function getExternalStatus(projectPath) {
  // 简化：外部服务状态由 registry 统一拉取，这里返回 null 表示非本模块托管
  return null;
}

/** 停止外部托管服务（pm2/systemd/docker） */
async function stopExternal(projectPath) {
  return null;
}

/** 启动外部托管服务 */
async function startExternal(projectPath) {
  return null;
}

module.exports = {
  start,
  stop,
  restart,
  build,
  getStatus,
  appendLog,
  logPathFor,
  checkPortLock,
  buildScript,
  detectExternalServices,
};
