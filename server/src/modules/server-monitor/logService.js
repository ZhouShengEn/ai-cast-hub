/**
 * 服务器监控模块 — 日志服务
 *
 * 提供：
 *  - 读取服务日志最近 N 行（readRecent）
 *  - 增量监听（watch）：轮询文件大小变化，推送新增内容（前端流式展示）
 *  - 前端清空（仅清空内存展示，不删服务器日志文件）—— 由前端控制，这里提供 truncateFile 可选
 *
 * 日志文件由 processManager 写入（每个服务独立 .log）。
 */

const fs = require('fs');
const path = require('path');
const { readTail } = require('./util');

/**
 * 读取服务日志最近 N 行。
 * @param {string} logFilePath
 * @param {number} lines
 */
async function readRecent(logFilePath, lines = 500) {
  if (!logFilePath || !fs.existsSync(logFilePath)) {
    return { ok: false, content: '', message: '日志文件不存在' };
  }
  try {
    const content = await readTail(logFilePath, lines);
    return { ok: true, content, path: logFilePath };
  } catch (e) {
    return { ok: false, content: '', message: e.message };
  }
}

/**
 * 增量监听日志文件。
 * 轮询文件大小，读取新增字节并回调。
 * @param {string} logFilePath
 * @param {(chunk:string)=>void} onChunk
 * @param {number} [intervalMs=1000]
 * @returns {Function} 停止监听函数
 */
function watch(logFilePath, onChunk, intervalMs = 1000) {
  let lastSize = 0;
  try { lastSize = fs.statSync(logFilePath).size; } catch { lastSize = 0; }
  let stopped = false;

  const timer = setInterval(() => {
    if (stopped) return;
    try {
      const stat = fs.statSync(logFilePath);
      if (stat.size < lastSize) {
        // 文件被截断或重建
        lastSize = 0;
      }
      if (stat.size > lastSize) {
        const stream = fs.createReadStream(logFilePath, { start: lastSize, end: stat.size });
        let buf = '';
        stream.on('data', (d) => { buf += d.toString(); });
        stream.on('end', () => {
          lastSize = stat.size;
          if (buf) onChunk(buf);
        });
        stream.on('error', () => {});
      }
    } catch (_) {}
  }, intervalMs);

  return () => {
    stopped = true;
    clearInterval(timer);
  };
}

/** 清空服务器上的日志文件（高危，默认不暴露给前端） */
function truncateFile(logFilePath) {
  try { fs.writeFileSync(logFilePath, '', 'utf8'); return true; } catch { return false; }
}

module.exports = { readRecent, watch, truncateFile };
