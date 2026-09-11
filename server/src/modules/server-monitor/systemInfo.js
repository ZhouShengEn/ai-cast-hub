/**
 * 服务器监控模块 — 系统资源信息
 *
 * 采集：CPU 使用率、内存占用、磁盘占用、负载、运行时长。
 * 全部带 try/catch 降级，非 Linux 环境返回 null 不影响主流程。
 */

const os = require('os');
const fs = require('fs');
const commandRunner = require('./commandRunner');

let _prevCpu = null;
let _prevTs = 0;

/** 读取 /proc/stat 计算 CPU 使用率（Linux） */
function readCpuUsage() {
  try {
    const stat = fs.readFileSync('/proc/stat', 'utf8');
    const line = stat.split('\n').find((l) => l.startsWith('cpu '));
    if (!line) return null;
    const parts = line.trim().split(/\s+/).slice(1).map(Number);
    const idle = parts[3];
    const total = parts.reduce((a, b) => a + b, 0);
    const now = Date.now();
    let usage = null;
    if (_prevCpu && _prevTs) {
      const totalDiff = total - _prevCpu.total;
      const idleDiff = idle - _prevCpu.idle;
      if (totalDiff > 0) {
        usage = Math.max(0, Math.min(100, Math.round(((totalDiff - idleDiff) / totalDiff) * 1000) / 10));
      }
    }
    _prevCpu = { total, idle };
    _prevTs = now;
    return usage;
  } catch {
    return null;
  }
}

async function getSystemInfo() {
  const memTotal = os.totalmem();
  const memFree = os.freemem();
  const memUsed = memTotal - memFree;

  const cpuUsage = readCpuUsage();
  const loadavg = os.loadavg();

  let disk = null;
  try {
    const r = await commandRunner.run({ bin: 'df', args: ['-k', '/'] }, {}, 5000);
    if (r.code === 0) {
      const lines = r.stdout.trim().split('\n');
      const last = lines[lines.length - 1];
      const cols = last.split(/\s+/);
      // cols: Filesystem Size Used Avail Use% Mounted
      if (cols.length >= 5) {
        const totalKb = parseInt(cols[1], 10) || 0;
        const usedKb = parseInt(cols[2], 10) || 0;
        disk = {
          totalBytes: totalKb * 1024,
          usedBytes: usedKb * 1024,
          usedPercent: parseFloat(cols[4].replace('%', '')) || 0,
        };
      }
    }
  } catch (_) {}

  return {
    platform: os.platform(),
    hostname: os.hostname(),
    arch: os.arch(),
    cpuModel: os.cpus()[0]?.model || 'unknown',
    cpuCount: os.cpus().length,
    cpuUsagePercent: cpuUsage,
    loadavg,
    memTotalBytes: memTotal,
    memUsedBytes: memUsed,
    memUsedPercent: memTotal ? Math.round((memUsed / memTotal) * 1000) / 10 : null,
    disk,
    uptimeSec: Math.floor(os.uptime()),
    nodeVersion: process.version,
  };
}

module.exports = { getSystemInfo };
