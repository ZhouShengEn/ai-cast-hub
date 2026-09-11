/**
 * 服务器监控模块 — 操作审计日志
 *
 * 记录所有 Web 端运维操作：启动 / 停止 / 重启 / git pull / 编译 / Nginx 配置修改。
 * 留存：操作人、时间、服务名、操作类型、执行日志、成功状态。
 * 持久化为 JSONL（每行一条），支持查询与导出。
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('./config');

const AUDIT_FILE = path.join(config.DATA_DIR, 'audit.jsonl');

function ensureFile() {
  if (!fs.existsSync(AUDIT_FILE)) {
    fs.mkdirSync(path.dirname(AUDIT_FILE), { recursive: true });
    fs.writeFileSync(AUDIT_FILE, '', 'utf8');
  }
}

/**
 * 记录一条审计。
 * @param {object} entry
 * @param {string} entry.operator 操作者（设备标识 / 角色）
 * @param {string} entry.serviceName 服务名
 * @param {string} entry.servicePath 服务路径
 * @param {string} entry.action 操作类型
 * @param {boolean} entry.success
 * @param {string} [entry.detail] 执行日志摘要
 */
function log(entry) {
  ensureFile();
  const record = {
    id: crypto.randomBytes(6).toString('hex'),
    time: new Date().toISOString(),
    operator: entry.operator || 'unknown',
    serviceName: entry.serviceName || '-',
    servicePath: entry.servicePath || '-',
    action: entry.action,
    success: !!entry.success,
    detail: entry.detail || '',
  };
  try {
    fs.appendFileSync(AUDIT_FILE, JSON.stringify(record) + '\n', 'utf8');
  } catch (e) {
    const logger = require('../../utils/logger');
    logger.error(`[Monitor] 审计写入失败: ${e.message}`);
  }
  return record;
}

/**
 * 查询审计（按时间倒序）。
 * @param {object} [opts] { page=1, pageSize=50, action?, serviceName? }
 */
function query(opts = {}) {
  ensureFile();
  const { page = 1, pageSize = 50, action, serviceName } = opts;
  const lines = fs.readFileSync(AUDIT_FILE, 'utf8').split('\n').filter(Boolean);
  let records = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  if (action) records = records.filter((r) => r.action === action);
  if (serviceName) records = records.filter((r) => r.serviceName && r.serviceName.includes(serviceName));
  records.reverse(); // 最新在前
  const total = records.length;
  const start = (page - 1) * pageSize;
  return { total, page, pageSize, items: records.slice(start, start + pageSize) };
}

/** 导出全部审计（JSON 字符串） */
function exportAll() {
  ensureFile();
  const lines = fs.readFileSync(AUDIT_FILE, 'utf8').split('\n').filter(Boolean);
  const records = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  return JSON.stringify(records, null, 2);
}

module.exports = { log, query, exportAll };
