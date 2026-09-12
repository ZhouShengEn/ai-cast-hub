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
 * HTTP 健康探测：GET http://127.0.0.1:port/path
 * 只要拿到任意 HTTP 响应码（含 4xx/5xx）即认为服务进程在正常工作，
 * 只有连接失败 / 超时才算不健康。
 * @param {number} port
 * @param {string} [path]
 * @param {number} [timeoutMs]
 * @returns {Promise<{ok:boolean, status?:number, error?:string}>}
 */
function probeHttp(port, path = '/', timeoutMs = 1500) {
  return new Promise((resolve) => {
    const http = require('http');
    const req = http.request(
      { host: '127.0.0.1', port, path, method: 'GET', timeout: timeoutMs },
      (res) => {
        const status = res.statusCode || 0;
        res.resume(); // 丢弃响应体，避免占用连接
        resolve({ ok: true, status });
      },
    );
    let settled = false;
    const done = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    req.setTimeout(timeoutMs, () => {
      req.destroy();
      done({ ok: false, error: 'timeout' });
    });
    req.once('error', (e) => done({ ok: false, error: e.message }));
    req.end();
  });
}

/**
 * 读取进程启动命令（/proc/<pid>/cmdline），用于「进程名 / 启动命令匹配」，
 * 避免 PID 复用导致的误判（PID 存在但已不是本服务）。
 * @param {number} pid
 * @returns {string|null}
 */
function readCmdline(pid) {
  try {
    const raw = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
    return raw.replace(/\0+$/, '').split('\0').join(' ').trim() || null;
  } catch (_) {
    return null;
  }
}

/**
 * 判断存活进程是否「像」本服务：用启动脚本的 bin/关键字做宽松匹配。
 * 匹配不上时返回 true（保守：宁可相信 PID，也不要把正常服务判成未运行）。
 * @param {number} pid
 * @param {{bin?:string, args?:string[]}} [script]
 * @returns {boolean}
 */
function processMatchesScript(pid, script) {
  try {
    const cmd = readCmdline(pid);
    if (!cmd) return true; // 读不到（非 Linux / 权限）不误判
    if (!script || !script.bin) return true;
    const bin = String(script.bin).split('/').pop();
    if (!bin) return true;
    return cmd.includes(bin) || cmd.includes(String(script.bin));
  } catch (_) {
    return true;
  }
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

/**
 * 获取某进程监听的 TCP 端口列表（读 /proc/net/tcp{,6} + /proc/<pid>/fd socket inode 映射）。
 * 用于 pm2 托管进程的端口自动识别（pm2 jlist 不带端口信息）。
 * @param {number} pid
 * @returns {number[]} 监听端口数组（可能为空）
 */
function getListeningPortsForPid(pid) {
  try {
    // 1. 收集全系统 LISTEN socket: inode -> port
    const inodeToPort = new Map();
    for (const file of ['/proc/net/tcp', '/proc/net/tcp6']) {
      let raw;
      try {
        raw = fs.readFileSync(file, 'utf8');
      } catch (_) {
        continue;
      }
      const lines = raw.split('\n').slice(1); // 跳过表头
      for (const line of lines) {
        const cols = line.trim().split(/\s+/);
        if (cols.length < 10) continue;
        // 状态 0A = LISTEN
        if (cols[3] !== '0A') continue;
        const localPort = parseInt(cols[1].split(':')[1], 16);
        const inode = cols[9];
        if (localPort > 0 && inode) inodeToPort.set(inode, localPort);
      }
    }
    if (inodeToPort.size === 0) return [];

    // 2. 遍历进程 fd，匹配 socket:[inode]
    const ports = new Set();
    const fdDir = `/proc/${pid}/fd`;
    let fds;
    try {
      fds = fs.readdirSync(fdDir);
    } catch (_) {
      return [];
    }
    for (const fd of fds) {
      let link;
      try {
        link = fs.readlinkSync(`${fdDir}/${fd}`);
      } catch (_) {
        continue;
      }
      const m = link.match(/^socket:\[(\d+)\]$/);
      if (!m) continue;
      const port = inodeToPort.get(m[1]);
      if (port) ports.add(port);
    }
    return [...ports].sort((a, b) => a - b);
  } catch (_) {
    return [];
  }
}

/**
 * 通过端口反查监听该端口的进程 PID（与 getListeningPortsForPid 互逆）。
 * 用于「即便本模块无运行记录 / 记录的 PID 已失效，只要端口在监听即可判定运行中」。
 * 读取 /proc/net/tcp{,6} 的 LISTEN socket（端口 -> inode），再遍历 /proc/<pid>/fd
 * 匹配 socket:[inode] 得到 pid。非 Linux / 读取失败返回 null（前端降级）。
 * @param {number} port
 * @returns {number|null}
 */
function findPidByPort(port) {
  try {
    const targetHex = Number(port).toString(16).padStart(4, '0');
    const listeningInodes = new Set();
    for (const file of ['/proc/net/tcp', '/proc/net/tcp6']) {
      let raw;
      try {
        raw = fs.readFileSync(file, 'utf8');
      } catch (_) {
        continue;
      }
      for (const line of raw.split('\n').slice(1)) {
        const cols = line.trim().split(/\s+/);
        if (cols.length < 10) continue;
        if (cols[3] !== '0A') continue; // 状态 0A = LISTEN
        const localPort = parseInt(cols[1].split(':')[1], 16);
        if (localPort === Number(port)) listeningInodes.add(cols[9]);
      }
    }
    if (listeningInodes.size === 0) return null;

    let pids;
    try {
      pids = fs.readdirSync('/proc');
    } catch (_) {
      return null;
    }
    for (const pidStr of pids) {
      if (!/^\d+$/.test(pidStr)) continue;
      const fdDir = `/proc/${pidStr}/fd`;
      let fds;
      try {
        fds = fs.readdirSync(fdDir);
      } catch (_) {
        continue;
      }
      for (const fd of fds) {
        let link;
        try {
          link = fs.readlinkSync(`${fdDir}/${fd}`);
        } catch (_) {
          continue;
        }
        const m = link.match(/^socket:\[(\d+)\]$/);
        if (m && listeningInodes.has(m[1])) return Number(pidStr);
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

/**
 * 读取进程真实启动时间（ISO），用于「运行时常」精准展示。
 * 公式：系统启动时间(btime, 来自 /proc/stat) + 进程 starttime(时钟滴答) / CLK_TCK。
 * 比「本模块记录的启动时刻」更准（能覆盖被回收/换 pid 的外部托管进程）。
 * @param {number} pid
 * @returns {string|null} ISO 时间或 null
 */
function getProcessStartIso(pid) {
  try {
    const stat = fs.readFileSync('/proc/stat', 'utf8');
    const btimeMatch = stat.match(/^btime\s+(\d+)/m);
    if (!btimeMatch) return null;
    const btime = parseInt(btimeMatch[1], 10);

    const procStat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    const idx = procStat.lastIndexOf(')');
    const parts = procStat.slice(idx + 2).split(' ');
    const starttime = parseInt(parts[19], 10) || 0;
    const ticks = 100; // sysconf _SC_CLK_TCK
    const startSec = btime + starttime / ticks;
    if (!Number.isFinite(startSec)) return null;
    return new Date(startSec * 1000).toISOString();
  } catch (_) {
    return null;
  }
}

module.exports = {
  isWithinSandbox,
  safeJoin,
  validateEnv,
  isPortListening,
  probeHttp,
  readCmdline,
  processMatchesScript,
  readProcStat,
  isPidAlive,
  computeCpuPercent,
  md5File,
  listSubDirs,
  readTail,
  getListeningPortsForPid,
  findPidByPort,
  getProcessStartIso,
};
