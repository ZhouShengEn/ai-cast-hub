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
  probeHttp, processMatchesScript, getListeningPortsForPid,
} = require('./util');
const logger = require('../../utils/logger');

/**
 * 服务运行状态（细分，取代原来非 running 即 stopped 的粗粒度判定）
 *  - stopped      未运行：进程不存在、端口未监听
 *  - starting     启动中：命令已执行，端口尚未监听（启动脚本退出码不作为最终依据）
 *  - running      运行中：进程存活 + 端口监听 + 健康探测通过
 *  - start_failed 启动失败：启动后 30 秒内进程退出或始终未监听端口
 *  - crashed      异常退出：曾正常运行，之后进程退出 / 端口关闭
 */
const SERVICE_STATUS = {
  STOPPED: 'stopped',
  STARTING: 'starting',
  RUNNING: 'running',
  START_FAILED: 'start_failed',
  CRASHED: 'crashed',
};

const STATUS_TEXT = {
  stopped: '未运行',
  starting: '启动中',
  running: '运行中',
  start_failed: '启动失败',
  crashed: '异常退出',
};

/** 启动就绪等待上限：点「启动」后最多轮询 30 秒（P1-6） */
const START_TIMEOUT_MS = 30 * 1000;
/** 启动就绪轮询间隔 */
const START_POLL_MS = 1000;

/** 状态变更监听（由 wsHub 注册，用于实时推送；避免模块循环依赖） */
const _statusListeners = new Set();

/**
 * 注册服务状态变更监听
 * @param {(evt:{projectPath:string, status:object}) => void} fn
 */
function onStatusChange(fn) {
  if (typeof fn === 'function') _statusListeners.add(fn);
}

function _emitStatusChange(projectPath, status) {
  for (const fn of _statusListeners) {
    try {
      fn({ projectPath, status });
    } catch (e) {
      logger.warn(`[Monitor] 状态变更回调异常: ${e.message}`);
    }
  }
}

/** 启动观测表：projectPath -> { timer, startedAt } */
const _startupWatchers = new Map();

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
  if (isExternalPath(projectPath)) {
    return externalAction(projectPath, 'start');
  }
  const managed = await resolveExternalManaged(projectPath);
  if (managed) return externalAction(managed, 'start');
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
  const spawned = await commandRunner.spawnService(
    { bin: script.start.bin, args: script.start.args, cwd: script.start.cwd, env },
    fs.createWriteStream(logPathFor(projectPath), { flags: 'a' })
  );
  const child = spawned.child || spawned;

  _runtime[projectPath] = {
    pid: child.pid,
    port: port || null,
    startedAt: new Date().toISOString(),
    // phase 由「启动中」开始，最终状态由端口监听 + 进程存活 + 健康探测共同决定，
    // 启动命令是否成功返回只作为参考，不再直接等同于「运行中」。
    phase: SERVICE_STATUS.STARTING,
    everRunning: false,
    status: SERVICE_STATUS.STARTING,
    source: script.source === 'custom' ? 'custom' : 'auto',
    logFile: logPathFor(projectPath),
    operator: opts.operator || null,
  };
  saveRuntime();

  // 进程退出监听：异常退出（非本模块 stop 触发）时立即标记为 crashed 并推送
  if (child && typeof child.on === 'function') {
    child.on('exit', (code, signal) => {
      const cur = _runtime[projectPath];
      if (!cur || cur.pid !== child.pid) return; // 已由 stop 清理或已被新进程取代
      const wasRunning = cur.phase === SERVICE_STATUS.RUNNING || cur.everRunning;
      cur.exitAt = new Date().toISOString();
      cur.exitCode = code;
      cur.exitSignal = signal;
      cur.phase = wasRunning ? SERVICE_STATUS.CRASHED : SERVICE_STATUS.START_FAILED;
      _runtime[projectPath] = cur;
      saveRuntime();
      appendLog(
        projectPath,
        `⚠️ 进程退出 (code=${code}, signal=${signal})，状态=${cur.phase}`,
        'ERROR',
      );
      _stopStartupWatcher(projectPath);
      getStatus(projectPath).then((st) => _emitStatusChange(projectPath, st)).catch(() => {});
    });
  }

  // 启动就绪轮询：最多 30 秒，状态变化实时推送到 Web 端
  _startStartupWatcher(projectPath);

  return getStatus(projectPath);
}

/**
 * 启动后轮询检测（1 秒一次，最多 30 秒）。
 * 每轮都把最新状态推给 Web 端，使其能实时看到「启动中 → 运行中 / 启动失败」。
 * @param {string} projectPath
 */
function _startStartupWatcher(projectPath) {
  _stopStartupWatcher(projectPath);
  const deadline = Date.now() + START_TIMEOUT_MS;
  let lastStatus = null;

  const tick = async () => {
    const rt = _runtime[projectPath];
    if (!rt) return _stopStartupWatcher(projectPath);
    try {
      const st = await getStatus(projectPath);
      if (st.status !== lastStatus) {
        lastStatus = st.status;
        _emitStatusChange(projectPath, st);
      }
      // 已确定终态（运行中 / 启动失败 / 异常退出）或超时 → 停止轮询
      if (
        st.status === SERVICE_STATUS.RUNNING ||
        st.status === SERVICE_STATUS.START_FAILED ||
        st.status === SERVICE_STATUS.CRASHED ||
        Date.now() >= deadline
      ) {
        if (st.status === SERVICE_STATUS.STARTING && Date.now() >= deadline) {
          const cur = _runtime[projectPath];
          if (cur) {
            cur.phase = SERVICE_STATUS.START_FAILED;
            _runtime[projectPath] = cur;
            saveRuntime();
          }
          const finalSt = await getStatus(projectPath);
          _emitStatusChange(projectPath, finalSt);
        }
        _stopStartupWatcher(projectPath);
        return;
      }
    } catch (e) {
      logger.warn(`[Monitor] 启动状态轮询失败: ${e.message}`);
    }
    const timer = setTimeout(tick, START_POLL_MS);
    const entry = _startupWatchers.get(projectPath);
    if (entry) entry.timer = timer;
  };

  _startupWatchers.set(projectPath, { timer: setTimeout(tick, 500), deadline });
}

function _stopStartupWatcher(projectPath) {
  const entry = _startupWatchers.get(projectPath);
  if (entry && entry.timer) clearTimeout(entry.timer);
  _startupWatchers.delete(projectPath);
}

/**
 * 停止项目。
 */
async function stop(projectPath, opts = {}) {
  if (isExternalPath(projectPath)) {
    return externalAction(projectPath, 'stop');
  }
  const managed = await resolveExternalManaged(projectPath);
  if (managed) return externalAction(managed, 'stop');
  const { script } = buildScript(projectPath);
  const rt = _runtime[projectPath];
  appendLog(projectPath, '>>> 停止服务', 'INFO');

  // 停止即终止启动观测，避免 watcher 继续把状态推回「启动中/失败」
  _stopStartupWatcher(projectPath);

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
    if (isExternalPath(projectPath)) return externalAction(projectPath, 'stop');
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
  if (isExternalPath(projectPath)) {
    return externalAction(projectPath, 'restart');
  }
  const managed = await resolveExternalManaged(projectPath);
  if (managed) return externalAction(managed, 'restart');
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
 * 读取某项目的运行时状态（多维度智能判定）。
 *
 * 判定优先级（不再以「启动命令返回值 / PID 是否存在」为最终依据）：
 *   1. 端口监听：服务配置端口是否 LISTEN（最可靠）
 *   2. 进程存活：PID 存在 + 启动命令匹配（防 PID 复用误判）
 *   3. 健康探测：HTTP 服务 GET / 探测；TCP 服务端口连通探测
 *
 * @param {string} projectPath
 * @returns {Promise<object>}
 */
async function getStatus(projectPath) {
  let script = null;
  try {
    script = buildScript(projectPath).script;
  } catch (_) {
    script = null;
  }

  const rt = _runtime[projectPath];
  const nginxLinked = !!projectStore.getOverrides(projectPath).nginxLinkId;
  const base = {
    id: encodeProjectId(projectPath),
    path: projectPath,
    port: (rt && rt.port != null) ? rt.port : (script && script.port) || null,
    nginxLinked,
    logFile: script ? logPathFor(projectPath) : null,
    scriptInfo: script ? { source: script.source, notes: script.notes } : null,
  };

  // ---- 无运行记录：未运行（或由外部托管） ----
  if (!rt || !rt.pid) {
    const ext = await getExternalStatusByPath(projectPath);
    if (ext) return { ...base, ...ext };
    // pm2 托管检测：工作区目录项目实际由 pm2 启动时，反映真实状态而非误报「已停止」
    const pm2 = await matchPm2ForPath(projectPath);
    if (pm2) {
      return {
        ...base,
        source: 'pm2',
        pm2Name: pm2.pm2Name,
        ..._statusShape(pm2.status, {
          pid: pm2.pid,
          listening: pm2.listening,
          health: null,
          startedAt: pm2.uptimeSec ? new Date(Date.now() - pm2.uptimeSec * 1000).toISOString() : null,
          uptimeSec: pm2.uptimeSec,
          cpuPercent: pm2.cpuPercent,
          memRssMb: pm2.memRssMb,
          port: pm2.port || base.port,
        }),
      };
    }
    return {
      ...base,
      ..._statusShape(SERVICE_STATUS.STOPPED, {
        pid: null,
        listening: false,
        health: null,
        startedAt: null,
        uptimeSec: 0,
        cpuPercent: null,
        memRssMb: null,
      }),
    };
  }

  const pid = rt.pid;
  const alive = isPidAlive(pid);
  const startedAt = rt.startedAt || null;
  const uptimeSec = startedAt
    ? Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000)
    : 0;

  // ---- 进程已退出 ----
  if (!alive || !processMatchesScript(pid, script && script.start)) {
    const wasRunning = rt.phase === SERVICE_STATUS.RUNNING;
    const crashed = wasRunning || (rt.everRunning === true);
      delete _runtime[projectPath];
      saveRuntime();
      const ext = await getExternalStatusByPath(projectPath);
      if (ext) return { ...base, ...ext };
      return {
      ...base,
      ..._statusShape(
        crashed ? SERVICE_STATUS.CRASHED : SERVICE_STATUS.STOPPED,
        {
          pid: crashed ? pid : null,
          listening: false,
          health: false,
          startedAt: crashed ? startedAt : null,
          uptimeSec: 0,
          cpuPercent: null,
          memRssMb: null,
          exitAt: rt.exitAt || new Date().toISOString(),
        },
      ),
    };
  }

  // ---- 进程存活：端口监听 + 健康探测 ----
  const port = (rt.port != null) ? rt.port : (script && script.port);
  const listening = port ? await isPortListening(port) : null;
  const health = port ? await _probeHealth(port, script) : null;

  // Nginx 关联服务：额外校验 proxy_pass 后端端口连通性
  let proxyCheck = null;
  if (nginxLinked) {
    try {
      const nginxManager = require('./nginxManager');
      const override = projectStore.getOverrides(projectPath);
      const link = nginxManager.getLink(override.nginxLinkId);
      if (link && link.proxyPort) {
        const reachable = await isPortListening(link.proxyPort);
        proxyCheck = { port: link.proxyPort, reachable };
      }
    } catch (_) {
      proxyCheck = null;
    }
  }

  // 资源占用
  const sample = readProcStat(pid);
  let cpu = null;
  if (sample) {
    const prev = _cpuSamples.get(pid);
    const now = Date.now();
    if (prev) cpu = computeCpuPercent(prev.sample, sample, now - prev.ts);
    _cpuSamples.set(pid, { sample, ts: now });
  }

  // 状态判定
  let status;
  if (rt.phase === SERVICE_STATUS.STARTING) {
    const ready = _isReady(port, listening, health);
    if (ready) {
      status = SERVICE_STATUS.RUNNING;
    } else if (Date.now() - new Date(startedAt || Date.now()).getTime() > START_TIMEOUT_MS) {
      // 超过 30 秒仍未就绪 → 启动失败
      status = SERVICE_STATUS.START_FAILED;
    } else {
      status = SERVICE_STATUS.STARTING;
    }
  } else if (rt.phase === SERVICE_STATUS.START_FAILED) {
    status = SERVICE_STATUS.START_FAILED;
  } else if (listening === false) {
    // 曾在运行但端口不再监听：服务还在但服务未对外提供能力 → 视为启动中/异常
    status = SERVICE_STATUS.STARTING;
  } else {
    status = SERVICE_STATUS.RUNNING;
  }

  // 回写运行时相位（保证后续轮询与 WS 推送口径一致）
  if (rt.phase !== status && status !== SERVICE_STATUS.STOPPED) {
    _runtime[projectPath] = {
      ...rt,
      phase: status,
      everRunning: rt.everRunning || status === SERVICE_STATUS.RUNNING,
    };
    if (status === SERVICE_STATUS.START_FAILED) {
      appendLog(projectPath, `⚠️ 启动后 ${START_TIMEOUT_MS / 1000} 秒内未检测到端口监听，判定为启动失败`, 'ERROR');
    }
    saveRuntime();
  }

  return {
    ...base,
    ..._statusShape(status, {
      pid,
      listening,
      health,
      proxyCheck,
      startedAt,
      uptimeSec,
      cpuPercent: cpu,
      memRssMb: sample ? sample.memRssMb : null,
      operator: rt.operator || null,
    }),
  };
}

/**
 * 把细分状态映射为对外字段（running 布尔 + statusText 便于前端直接展示）
 * @param {string} status
 * @param {object} extra
 */
function _statusShape(status, extra = {}) {
  return {
    status,
    statusText: STATUS_TEXT[status] || status,
    running: status === SERVICE_STATUS.RUNNING,
    ...extra,
  };
}

/** 服务是否真正就绪：无端口服务（如脚本型）以进程存活为准 */
function _isReady(port, listening, health) {
  if (!port) return true;
  if (listening !== true) return false;
  // 健康探测失败但仍监听端口时，不因此判为未就绪（很多服务不响应 GET /）
  return health !== false;
}

/**
 * 健康探测：HTTP 服务 GET /，其它（TCP 类）退化为端口连通探测。
 * @param {number} port
 * @param {object|null} script
 */
async function _probeHealth(port, script) {
  try {
    const type = (script && script.type) || '';
    if (type === 'java' || type === 'node' || type === 'python' || type === 'go' || type === 'php') {
      const r = await probeHttp(port, '/', 1500);
      // HTTP 探测成功即健康；连接失败时退化为端口探测结果
      return r.ok ? true : await isPortListening(port);
    }
    return await isPortListening(port);
  } catch (_) {
    return null;
  }
}

// ============================================================
// 外部托管服务（pm2 / systemd）检测与操作
//
// 这些服务不受本模块 PID 生命周期管理，只做只读检测 +
// 通过各自 CLI（pm2 / systemctl）启停，命令均走 commandRunner 白名单。
// 伪路径约定：'pm2://<name>'、'systemd://<unit>'，用作服务 id/path 贯穿全链路。
// ============================================================

/** 外部服务伪路径前缀 */
const EXTERNAL_PREFIXES = ['pm2://', 'systemd://'];

/** 判断是否为外部托管服务的伪路径 */
function isExternalPath(projectPath) {
  return typeof projectPath === 'string'
    && EXTERNAL_PREFIXES.some((p) => projectPath.startsWith(p));
}

/** pm2 状态 -> 监控五态映射 */
function _mapPm2Status(pm2Status) {
  switch (pm2Status) {
    case 'online': return SERVICE_STATUS.RUNNING;
    case 'launching': return SERVICE_STATUS.STARTING;
    case 'errored': return SERVICE_STATUS.CRASHED;
    case 'stopped':
    case 'deleted':
    default: return SERVICE_STATUS.STOPPED;
  }
}

/**
 * 检测当前系统所有 pm2 / systemd(nginx) 服务，返回描述数组。
 * - pm2：由 `pm2 jlist` 获取进程与状态，端口通过 /proc 匹配该 pid 的 LISTEN socket 自动识别
 * - systemd：当前内置 nginx 单元（systemctl is-active + 80/443 端口探测）
 */
async function detectExternalServices() {
  const out = [];

  // ---- pm2 托管 ----
  try {
    const pm2 = await commandRunner.run({ bin: 'pm2', args: ['jlist'] }, {}, 10000);
    if (pm2.code === 0 && pm2.stdout.trim()) {
      const list = JSON.parse(pm2.stdout);
      for (const p of list) {
        const status = _mapPm2Status(p.pm2_env?.status);
        const pid = p.pid || null;
        // 端口自动识别：读该进程监听的 LISTEN socket
        const ports = pid && status === SERVICE_STATUS.RUNNING
          ? getListeningPortsForPid(pid)
          : [];
        const startedAt = p.pm2_env?.pm_uptime
          ? new Date(Number(p.pm2_env.pm_uptime)).toISOString()
          : null;
        out.push({
          id: encodeProjectId('pm2://' + p.name),
          path: 'pm2://' + p.name,
          name: p.name,
          type: 'node',
          source: 'pm2',
          pm2Name: p.name,
          pid,
          running: status === SERVICE_STATUS.RUNNING,
          status,
          statusText: STATUS_TEXT[status] || status,
          port: ports[0] || null,
          ports,
          listening: ports.length > 0,
          health: null,
          startedAt,
          uptimeSec: startedAt && status === SERVICE_STATUS.RUNNING
            ? Math.floor((Date.now() - Number(p.pm2_env.pm_uptime)) / 1000)
            : 0,
          cpuPercent: p.monit?.cpu ?? null,
          memRssMb: p.monit?.memory ? Math.round(p.monit.memory / 1024 / 1024 * 10) / 10 : null,
          cwd: p.pm2_env?.pm_cwd || null,
        });
      }
    }
  } catch (e) {
    logger.debug(`[Monitor] pm2 检测失败: ${e.message}`);
  }

  // ---- systemd 托管（内置 nginx） ----
  try {
    const active = await commandRunner.run(
      { bin: 'systemctl', args: ['is-active', 'nginx'] }, {}, 5000,
    );
    // is-active 输出 active/inactive/failed/unknown；退出码 0 = active
    const state = (active.stdout || '').trim() || 'unknown';
    const status = state === 'active'
      ? SERVICE_STATUS.RUNNING
      : (state === 'failed' ? SERVICE_STATUS.CRASHED : SERVICE_STATUS.STOPPED);

    let mainPid = null;
    try {
      const show = await commandRunner.run(
        { bin: 'systemctl', args: ['show', 'nginx', '-p', 'MainPID', '--value'] }, {}, 5000,
      );
      const v = parseInt((show.stdout || '').trim(), 10);
      mainPid = Number.isInteger(v) && v > 0 ? v : null;
    } catch (_) {}

    // nginx 主进程 + worker 都可能持有 80/443，此处以端口连通性为准
    const ports = [];
    for (const port of [80, 443]) {
      // eslint-disable-next-line no-await-in-loop
      if (await isPortListening(port)) ports.push(port);
    }

    out.push({
      id: encodeProjectId('systemd://nginx'),
      path: 'systemd://nginx',
      name: 'nginx (systemd)',
      type: 'nginx',
      source: 'systemd',
      systemdUnit: 'nginx',
      pid: mainPid,
      running: status === SERVICE_STATUS.RUNNING,
      status,
      statusText: STATUS_TEXT[status] || status,
      port: ports[0] || null,
      ports,
      listening: ports.length > 0,
      health: null,
      startedAt: null,
      uptimeSec: 0,
      cpuPercent: null,
      memRssMb: null,
      cwd: '/etc/nginx',
    });
  } catch (e) {
    logger.debug(`[Monitor] systemd nginx 检测失败: ${e.message}`);
  }

  return out;
}

/** 从缓存检测结果中找某个外部服务（每次实时检测，pm2 jlist 开销可接受） */
async function _findExternal(projectPath) {
  const list = await detectExternalServices();
  return list.find((s) => s.path === projectPath) || null;
}

// ============================================================
// pm2 托管目录项目的识别与委派
//
// 场景：被监控的工作区目录项目（如 /opt/workspace/ai-cast-hub/server）
// 实际上由 pm2 托管运行，而非本模块 spawn。此时需要：
//  - getStatus 反映 pm2 真实运行状态 / 监听端口 / 资源占用（而不是误报「已停止」）
//  - start/stop/restart 经 pm2 CLI 操作，而非本模块 spawn
// ============================================================

/** pm2 jlist 结果缓存（5 秒），避免频繁调用开销 */
let _pm2ListCache = { at: 0, list: [] };

async function getPm2List() {
  const now = Date.now();
  if (_pm2ListCache.list && now - _pm2ListCache.at < 5000) return _pm2ListCache.list;
  let list = [];
  try {
    const r = await commandRunner.run({ bin: 'pm2', args: ['jlist'] }, {}, 10000);
    if (r.code === 0 && r.stdout.trim()) list = JSON.parse(r.stdout);
  } catch (_) {
    list = [];
  }
  _pm2ListCache = { at: now, list };
  return list;
}

/** 把 pm2 进程对象转换为统一状态片段 */
function _pm2ToStatus(p) {
  const status = _mapPm2Status(p.pm2_env?.status);
  const pid = p.pid || null;
  const ports = pid && status === SERVICE_STATUS.RUNNING
    ? getListeningPortsForPid(pid)
    : [];
  const uptime = p.pm2_env?.pm_uptime
    ? Math.floor((Date.now() - Number(p.pm2_env.pm_uptime)) / 1000)
    : 0;
  return {
    pm2Name: p.name,
    pid,
    status,
    statusText: STATUS_TEXT[status] || status,
    running: status === SERVICE_STATUS.RUNNING,
    ports,
    port: ports[0] || null,
    listening: ports.length > 0,
    uptimeSec: uptime,
    cpuPercent: p.monit?.cpu ?? null,
    memRssMb: p.monit?.memory ? Math.round(p.monit.memory / 1024 / 1024 * 10) / 10 : null,
    cwd: p.pm2_env?.pm_cwd || null,
  };
}

/**
 * 判断某工作区目录项目是否由 pm2 托管（cwd 匹配）。
 * @returns {Promise<object|null>} pm2 状态片段或 null
 */
async function matchPm2ForPath(projectPath) {
  try {
    const list = await getPm2List();
    for (const p of list) {
      const cwd = p.pm2_env?.pm_cwd;
      if (cwd && (cwd === projectPath || projectPath.startsWith(cwd + path.sep))) {
        return _pm2ToStatus(p);
      }
    }
  } catch (_) {}
  return null;
}

/**
 * 解析某 projectPath 应走哪种「外部托管」动作：
 *  - 伪路径（pm2:// 或 systemd://）→ 直接返回
 *  - 用户覆盖指定 pm2Name → 返回 pm2://name
 *  - 目录项目被 pm2 托管（cwd 匹配）→ 返回 pm2://name
 * @returns {Promise<string|null>}
 */
async function resolveExternalManaged(projectPath) {
  if (isExternalPath(projectPath)) return projectPath;
  const ov = projectStore.getOverrides(projectPath);
  if (ov && ov.pm2Name) return 'pm2://' + ov.pm2Name;
  const pm2 = await matchPm2ForPath(projectPath);
  if (pm2 && pm2.pm2Name) return 'pm2://' + pm2.pm2Name;
  return null;
}

/** pm2 托管项目的日志路径（~/.pm2/logs/<name>-out.log） */
function pm2LogPathFor(projectPath) {
  const ov = projectStore.getOverrides(projectPath);
  const name = ov && ov.pm2Name;
  if (!name) return null;
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) return null;
  const os = require('os');
  return path.join(os.homedir(), '.pm2', 'logs', `${name}-out.log`);
}

/**
 * 读取外部服务状态（供 GET /services/:id 兜底）。
 * @returns {Promise<object|null>}
 */
async function getExternalStatusByPath(projectPath) {
  if (!isExternalPath(projectPath)) return null;
  return _findExternal(projectPath);
}

/**
 * 外部服务启停/重启（pm2 / systemctl）。
 * @param {string} projectPath 伪路径
 * @param {'start'|'stop'|'restart'} action
 * @returns {Promise<{stopped?:boolean, status?:object, output:string}>}
 */
async function externalAction(projectPath, action) {
  const svc = await _findExternal(projectPath);
  if (!svc) throw new Error(`外部服务不存在: ${projectPath}`);

  let r;
  if (svc.source === 'pm2') {
    if (!['start', 'stop', 'restart'].includes(action)) {
      throw new Error(`pm2 不支持的动作: ${action}`);
    }
    r = await commandRunner.run(
      { bin: 'pm2', args: [action, svc.pm2Name] }, {}, 20000,
    );
  } else if (svc.source === 'systemd') {
    if (!['start', 'stop', 'restart'].includes(action)) {
      throw new Error(`systemctl 不支持的动作: ${action}`);
    }
    r = await commandRunner.run(
      { bin: 'systemctl', args: [action, svc.systemdUnit] }, {}, 20000,
    );
  } else {
    throw new Error(`未知外部服务来源: ${svc.source}`);
  }

  if (r.code !== 0) {
    throw new Error(`${action} 失败: ${(r.stderr || r.stdout || '').slice(0, 300)}`);
  }
  appendLog(projectPath, `>>> 外部服务 ${action} 完成 (${svc.source})`, 'INFO');

  const latest = await _findExternal(projectPath);
  return {
    stopped: action === 'stop',
    status: latest,
    output: (r.stdout || '') + (r.stderr || ''),
  };
}

/**
 * 外部服务日志文件路径（供 REST 日志接口与 WS 日志订阅共用）。
 * - pm2：~/.pm2/logs/<name>-out.log（err 进程则为 -error.log）
 * - systemd nginx：/var/log/nginx/error.log
 */
function externalLogPath(projectPath) {
  if (typeof projectPath !== 'string') return null;
  if (projectPath.startsWith('pm2://')) {
    const name = projectPath.slice('pm2://'.length);
    // 仅允许安全字符，防路径穿越
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) return null;
    const os = require('os');
    return path.join(os.homedir(), '.pm2', 'logs', `${name}-out.log`);
  }
  if (projectPath === 'systemd://nginx') {
    return '/var/log/nginx/error.log';
  }
  return null;
}

/** 启动外部托管服务（供 start 兜底调用） */
async function startExternal(projectPath) {
  if (!isExternalPath(projectPath)) return null;
  return externalAction(projectPath, 'start');
}

module.exports = {
  start,
  stop,
  restart,
  build,
  getStatus,
  onStatusChange,
  appendLog,
  logPathFor,
  externalLogPath,
  pm2LogPathFor,
  matchPm2ForPath,
  checkPortLock,
  buildScript,
  detectExternalServices,
  getExternalStatusByPath,
  SERVICE_STATUS,
};
