/**
 * 服务器监控模块 — 单项目覆盖配置存储
 *
 * 存储每个项目的用户自定义项（持久化 JSON）：
 *  - typeOverride: 手动指定的项目类型（未知项目手动选择）
 *  - customScript: 手动覆盖的启停/编译脚本
 *  - env: 自定义环境变量 KEY=VALUE
 *  - port: 手动指定的端口（仅未锁定 Nginx 时生效）
 *  - nginxLinkId: 关联的 Nginx 配置 ID（端口锁定）
 *  - displayName: 自定义展示名
 *
 * key 为项目绝对路径。
 */

const fs = require('fs');
const path = require('path');
const config = require('./config');

const FILE = path.join(config.DATA_DIR, 'projects.json');

let _store = {};

function load() {
  try {
    if (fs.existsSync(FILE)) {
      _store = JSON.parse(fs.readFileSync(FILE, 'utf8')) || {};
    }
  } catch {
    _store = {};
  }
  return _store;
}

function save() {
  try {
    fs.writeFileSync(FILE, JSON.stringify(_store, null, 2), 'utf8');
  } catch (err) {
    const logger = require('../../utils/logger');
    logger.error(`[Monitor] 项目覆盖保存失败: ${err.message}`);
  }
}

function getOverrides(projectPath) {
  return _store[projectPath] || {};
}

/**
 * 合并写入单项目覆盖项（浅合并）。
 */
function setOverride(projectPath, patch = {}) {
  _store[projectPath] = { ...(_store[projectPath] || {}), ...patch };
  save();
  return _store[projectPath];
}

function getAll() {
  return _store;
}

function removeOverride(projectPath) {
  delete _store[projectPath];
  save();
}

module.exports = { load, save, getOverrides, setOverride, getAll, removeOverride };
