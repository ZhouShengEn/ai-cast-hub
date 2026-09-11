/**
 * 服务器监控模块 — 通用工具函数
 */

const fs = require('fs');
const path = require('path');

/**
 * 规范化并判定 target 是否位于 allowedRoots 中任一目录（含自身）。
 * 用于沙箱越权防护。使用 resolve 消除 ../ 等。
 * @param {string} target
 * @param {string[]} allowedRoots
 * @returns {boolean}
 */
function isWithinSandbox(target, allowedRoots) {
  if (!target || !Array.isArray(allowedRoots) || allowedRoots.length === 0) return false;
  const resolvedTarget = path.resolve(target);
  return allowedRoots.some((root) => {
    const r = path.resolve(root);
    return resolvedTarget === r || resolvedTarget.startsWith(r + path.sep);
  });
}

/**
 * 安全 join：先 join，再校验结果仍在沙箱内，否则抛错。
 * 防止通过 .. 逃逸。
 */
function safeJoin(base, sub, allowedRoots) {
  const joined = path.resolve(base, sub);
  if (!isWithinSandbox(joined, allowedRoots)) {
    throw new Error(`路径越权: ${sub} 不在允许的目录范围内`);
  }
  return joined;
}

/**
 * 校验环境变量对象：KEY 必须符合标识符规则，VALUE 必须为字符串。
 * @param {Record<string,string>} env
 */
function validateEnv(env) {
  if (!env) return;
  for (const [k, v] of Object.entries(env)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) {
      throw new Error(`非法的环境变量名: ${k}`);
    }
    if (typeof v !== 'string') {
      throw new Error(`环境变量值必须为字符串: ${k}`);
    }
  }
}

/**
 * 检测端口是否被监听（TCP 探测）。
 * @param {number} port
 * @param {string} host 默认 127.0.0.1
 * @returns {Promise<boolean>}
 */
function isPortListening(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const net = require('net');
    const sock = new net.Socket();
    let settled = false;
    const done = (res) => {
      if (settled) return;
      settled = true;
      try { sock.destroy(); } catch (_) {}
      resolve(res);
    };
    sock.setTimeout(800);
    sock.once('connect', () => done(true));
    sock.once('timeout', () => done(false));
    sock.once('error', () => done(false));
    try {
      sock.connect(port, host);
    } catch (_) {
      done(false);
    }
  });
}

/**
 * 读取进程 CPU/内存占用（Linux /proc）。
 * 返回 { pid, cpuPercent, memRssBytes, memRssMb, threads } 或 null。
 * 非 Linux 或读取失败返回 null（前端降级展示）。
 */
function readProcStat(pid) {
  try {
    const statPath = `/proc/${pid}/stat`;
    const statusPath = `/proc/${pid}/status`;
    if (!fs.existsSync(statPath)) return null;

    const stat = fs.readFileSync(statPath, 'utf8');
    // 进程名可能含空格，括号包裹；取最后一个 ) 之后
    const idx = stat.lastIndexOf(')');
    const parts = stat.slice(idx + 2).split(' ');
    const utime = parseInt(parts[11], 10) || 0; // 用户态时间（ clock ticks ）
    const stime = parseInt(parts[12], 10) || 0; // 内核态时间
    const starttime = parseInt(parts[19], 10) || 0;
    const ticks = 100; // sysconf _SC_CLK_TCK，通常为 100
    const totalTime = (utime + stime) / ticks;

    // 内存
    let memRssBytes = 0;
    let threads = 0;
    if (fs.existsSync(statusPath)) {
      const status = fs.readFileSync(statusPath, 'utf8');
      const vmRss = status.match(/^VmRSS:\s+(\d+)\s+kB/m);
      if (vmRss) memRssBytes = parseInt(vmRss[1], 10) * 1024;
      const th = status.match(/^Threads:\s+(\d+)/m);
      if (th) threads = parseInt(th[1], 10);
    }

    return {
      pid: Number(pid),
      cpuPercent: null, // 需要两次采样计算，见 processManager
      memRssBytes,
      memRssMb: Math.round((memRssBytes / 1024 / 1024) * 10) / 10,
      threads,
      _utime: utime,
      _stime: stime,
      _starttime: starttime,
      _ticks: ticks,
    };
  } catch (_) {
    return null;
  }
}

/**
 * 进程是否存活（不发送信号，仅探测存在性）。
 * @param {number} pid
 * @returns {boolean}
 */
function isPidAlive(pid) {
  if (!pid) return false;
  try {
    // signal 0: 仅检测存在性，不实际发信号
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM'; // 存在但无权限也算存活
  }
}

/**
 * 计算两个采样点之间的 CPU 占用百分比。
 * @param {object} prev 上一次 readProcStat 结果
 * @param {object} curr 当前 readProcStat 结果
 * @param {number} elapsedMs 两次采样间隔毫秒
 */
function computeCpuPercent(prev, curr, elapsedMs) {
  if (!prev || !curr) return null;
  const prevCpu = (prev._utime + prev._stime) / prev._ticks;
  const currCpu = (curr._utime + curr._stime) / curr._ticks;
  const deltaCpu = currCpu - prevCpu; // 秒
  const elapsedSec = elapsedMs / 1000;
  if (elapsedSec <= 0) return 0;
  const percent = (deltaCpu / elapsedSec) * 100;
  return Math.max(0, Math.round(percent * 10) / 10);
}

/**
 * 安全 MD5（用于配置文件变更检测）。
 */
function md5File(filePath) {
  try {
    const crypto = require('crypto');
    const buf = fs.readFileSync(filePath);
    return crypto.createHash('md5').update(buf).digest('hex');
  } catch (_) {
    return null;
  }
}

/**
 * 递归读取目录（受最大深度限制），跳过隐藏目录与常见噪声目录。
 * 返回子目录绝对路径数组。
 */
const SKIP_DIRS = new Set(['node_modules', '.git', '.svn', 'dist', 'build', 'target', '.idea', '.vscode', 'vendor', '__pycache__']);

function listSubDirs(dir, maxDepth = 1, currentDepth = 0, acc = []) {
  if (currentDepth > maxDepth) return acc;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return acc;
  }
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (e.name.startsWith('.')) continue;
    if (SKIP_DIRS.has(e.name)) continue;
    const full = path.join(dir, e.name);
    acc.push(full);
    if (currentDepth < maxDepth) {
      listSubDirs(full, maxDepth, currentDepth + 1, acc);
    }
  }
  return acc;
}

/**
 * 读取文件最后 N 行（高效：从尾部按块读取）。
 * @param {string} filePath
 * @param {number} lines 行数
 * @returns {Promise<string>}
 */
async function readTail(filePath, lines = 200) {
  return new Promise((resolve, reject) => {
    fs.stat(filePath, (err, stat) => {
      if (err) return reject(err);
      const fileSize = stat.size;
      const CHUNK = 4096;
      let start = Math.max(0, fileSize - CHUNK * Math.ceil(lines / 20));
      const stream = fs.createReadStream(filePath, {
        encoding: 'utf8',
        start,
        end: fileSize,
      });
      let data = '';
      stream.on('data', (chunk) => { data += chunk; });
      stream.on('error', reject);
      stream.on('end', () => {
        const all = data.split('\n');
        // 去掉可能截断的首行
        if (all.length > lines) all = all.slice(all.length - lines);
        resolve(all.join('\n'));
      });
    });
  });
}

module.exports = {
  isWithinSandbox,
  safeJoin,
  validateEnv,
  isPortListening,
  readProcStat,
  isPidAlive,
  computeCpuPercent,
  md5File,
  listSubDirs,
  readTail,
};
