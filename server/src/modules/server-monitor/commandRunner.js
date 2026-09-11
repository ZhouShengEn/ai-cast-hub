/**
 * 服务器监控模块 — 安全命令执行器（安全核心）
 *
 * 设计原则（对应需求「全局安全约束」）：
 * 1. 严格命令白名单：只能执行 ALLOWED_BINS 中的二进制，禁止任意 shell 注入。
 * 2. 目录沙箱锁定：cwd 必须位于允许的沙箱根目录内，禁止越权访问系统目录。
 * 3. 不拼接前端输入：所有命令以数组参数方式（spawn，无 shell）执行，
 *    前端传入的端口 / 路径 / 环境变量均经过校验，绝不做字符串拼接后交给 shell。
 * 4. 超时自动终止：一次性命令超时后强制 SIGKILL。
 * 5. 优雅终止 + 超时强杀：长期服务停止时先 SIGTERM，超时后 SIGKILL。
 *
 * 注意：本模块本身不维护沙箱根目录，由外部（index.js）通过 setSandboxRoots 注入，
 * 通常包含：扫描根目录 /opt/workspace、允许的 Nginx 配置目录等。
 */

const { spawn } = require('child_process');
const path = require('path');
const { ALLOWED_BINS, MAX_OUTPUT_BUFFER, ENV_KEY_REGEX } = require('./constants');
const { isWithinSandbox, validateEnv } = require('./util');
const logger = require('../../utils/logger');

/** 沙箱根目录（运行时注入） */
let SANDBOX_ROOTS = [];

/** 注入沙箱根目录 */
function setSandboxRoots(roots) {
  if (Array.isArray(roots)) {
    SANDBOX_ROOTS = roots.filter(Boolean).map((r) => path.resolve(r));
    logger.info(`[Monitor] 沙箱根目录已设置: ${SANDBOX_ROOTS.join(', ')}`);
  }
}

function getSandboxRoots() {
  return SANDBOX_ROOTS;
}

/**
 * 校验一次性命令请求参数。
 * @param {object} opts
 * @param {string} opts.bin 二进制名（必须在白名单）
 * @param {string[]} opts.args 参数数组
 * @param {string} [opts.cwd] 工作目录（必须在沙箱内）
 * @param {Record<string,string>} [opts.env] 额外环境变量
 */
function validateRunOpts(opts) {
  if (!opts || typeof opts.bin !== 'string') {
    throw new Error('缺少 bin 参数');
  }
  if (!ALLOWED_BINS.has(opts.bin)) {
    throw new Error(`命令不在白名单: ${opts.bin}`);
  }
  if (!Array.isArray(opts.args)) {
    throw new Error('args 必须为数组');
  }
  for (const a of opts.args) {
    if (typeof a !== 'string') {
      throw new Error('命令参数必须为字符串');
    }
    // 防御性校验：即便无 shell，也禁止明显的 shell 注入字符（双保险）
    if (/[;&|`$()<>\\\n]/.test(a)) {
      throw new Error(`参数包含非法字符: ${a}`);
    }
  }
  if (opts.cwd && !isWithinSandbox(opts.cwd, SANDBOX_ROOTS)) {
    throw new Error(`cwd 越权: 禁止在沙箱外执行 (${opts.cwd})`);
  }
  if (opts.env) {
    validateEnv(opts.env);
  }
}

/**
 * 执行一次性命令（捕获输出，带超时）。
 * 用于 nginx -t、git status、构建等短命令。
 *
 * @param {object} opts 见 validateRunOpts
 * @param {object} [hooks] { onStdout?: (chunk:string)=>void, onStderr?: (chunk:string)=>void }
 * @returns {Promise<{ code:number, stdout:string, stderr:string, timedOut:boolean }>}
 */
function run(opts, hooks = {}, timeoutMs = 60000) {
  validateRunOpts(opts);
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(opts.bin, opts.args, {
        cwd: opts.cwd || SANDBOX_ROOTS[0] || process.cwd(),
        env: { ...process.env, ...(opts.env || {}) },
        windowsHide: true,
      });
    } catch (e) {
      return reject(e);
    }

    let stdout = '';
    let stderr = '';
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill('SIGKILL'); } catch (_) {}
    }, timeoutMs);

    const guard = (s) => (s.length > MAX_OUTPUT_BUFFER ? s.slice(-MAX_OUTPUT_BUFFER) : s);

    child.stdout.on('data', (d) => {
      const str = d.toString();
      if (hooks.onStdout) hooks.onStdout(str);
      stdout = guard(stdout + str);
    });
    child.stderr.on('data', (d) => {
      const str = d.toString();
      if (hooks.onStderr) hooks.onStderr(str);
      stderr = guard(stderr + str);
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code: typeof code === 'number' ? code : 1, stdout, stderr, timedOut });
    });
  });
}

/**
 * 启动长期运行的服务进程（后台驻留）。
 * 使用 detached + 管道输出到日志写入流，进程独立于请求生命周期。
 *
 * @param {object} opts 见 validateRunOpts（无 timeout）
 * @param {import('fs').WriteStream} logStream 日志写入流（由调用方管理）
 * @returns {Promise<{ pid:number, child:import('child_process').ChildProcess }>}
 */
function spawnService(opts, logStream) {
  validateRunOpts(opts);
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(opts.bin, opts.args, {
        cwd: opts.cwd || SANDBOX_ROOTS[0] || process.cwd(),
        env: { ...process.env, ...(opts.env || {}) },
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (e) {
      return reject(e);
    }

    if (logStream) {
      child.stdout.pipe(logStream, { end: false });
      child.stderr.pipe(logStream, { end: false });
    } else {
      child.stdout.resume();
      child.stderr.resume();
    }

    child.on('error', (err) => reject(err));
    child.unref(); // 脱离父进程，独立后台运行

    // 给一点时间确认是否立即崩溃
    const probe = setTimeout(() => {
      resolve({ pid: child.pid, child });
    }, 300);

    child.on('exit', (code, signal) => {
      clearTimeout(probe);
      // 若 300ms 内退出，视为启动失败
      if (!child._started) {
        child._started = true;
        reject(new Error(`进程启动后立即退出 (code=${code}, signal=${signal})`));
      }
    });
    child._started = true;
  });
}

/**
 * 终止进程：先 SIGTERM（优雅），超时后 SIGKILL（强制）。
 * @param {number} pid
 * @param {number} [graceMs=8000] 优雅等待时间
 * @returns {Promise<{ killed:boolean, forced:boolean }>}
 */
function killProcess(pid, graceMs = 8000) {
  return new Promise((resolve) => {
    if (!pid) return resolve({ killed: false, forced: false });
    try {
      process.kill(pid, 'SIGTERM');
    } catch (e) {
      if (e.code === 'ESRCH') return resolve({ killed: true, forced: false });
      return resolve({ killed: false, forced: false });
    }
    let forced = false;
    const t = setTimeout(() => {
      try {
        process.kill(pid, 'SIGKILL');
        forced = true;
      } catch (_) {}
    }, graceMs);

    const check = setInterval(() => {
      try {
        process.kill(pid, 0);
        // 仍存活
      } catch (_) {
        clearTimeout(t);
        clearInterval(check);
        resolve({ killed: true, forced });
      }
    }, 300);
  });
}

module.exports = {
  setSandboxRoots,
  getSandboxRoots,
  run,
  spawnService,
  killProcess,
};
