/**
 * 服务器监控模块 — 项目扫描器
 *
 * 固定扫描根目录（默认 /opt/workspace），受 maxDepth 限制防止无限递归；
 * 支持忽略列表；自动识别项目类型；与 projectStore 覆盖项合并。
 *
 * 输出「项目静态描述」列表，不含运行时状态（运行时状态由 processManager 附加）。
 */

const fs = require('fs');
const path = require('path');
const config = require('./config');
const projectStore = require('./projectStore');
const { detect } = require('./typeDetector');
const { listSubDirs } = require('./util');
const { encodeProjectId } = require('./ids');
const { PROJECT_TYPES } = require('./constants');
const logger = require('../../utils/logger');

/** 扫描缓存 */
let _cache = null;
let _cacheAt = 0;
const CACHE_TTL_MS = 30 * 1000; // 30s 内复用缓存，避免高频 IO

/**
 * 执行扫描。
 * @param {boolean} force 忽略缓存强制重扫
 * @returns {Project[]} 项目静态描述数组
 */
function scan(force = false) {
  const now = Date.now();
  if (!force && _cache && now - _cacheAt < CACHE_TTL_MS) {
    return _cache;
  }

  const cfg = config.get();
  const root = cfg.scanRoot;
  const maxDepth = cfg.maxDepth;
  const ignore = new Set(cfg.ignoreList || []);

  const projects = [];

  if (!root || !fs.existsSync(root)) {
    logger.warn(`[Monitor] 扫描根目录不存在: ${root}`);
    _cache = projects;
    _cacheAt = now;
    return projects;
  }

  // 候选目录：扫描根 + 递归子目录（受 maxDepth 限制）
  const candidates = [root, ...listSubDirs(root, maxDepth)];
  const seen = new Set();

  for (const dir of candidates) {
    if (seen.has(dir)) continue;
    seen.add(dir);
    if (ignore.has(dir)) continue;

    // 解析覆盖项
    const override = projectStore.getOverrides(dir);
    if (override.typeOverride) {
      // 手动指定类型（即便未识别也纳入）
    }

    let det = detect(dir);
    // 应用类型覆盖
    if (override.typeOverride && override.typeOverride !== det.type) {
      det = { ...det, type: override.typeOverride, confidence: 1, signals: [...det.signals, 'manual-override'] };
    }

    // 未识别且未被用户手动配置（无覆盖或相关配置）则跳过，降低噪声
    const hasManualConfig = override.typeOverride || override.customScript || override.displayName;
    if (det.type === PROJECT_TYPES.UNKNOWN && !hasManualConfig) {
      continue;
    }

    const name = override.displayName || path.basename(dir);

    projects.push({
      id: encodeProjectId(dir),
      path: dir,
      name,
      type: det.type,
      signals: det.signals,
      details: det.details || {},
      confidence: det.confidence,
      ignore: ignore.has(dir),
      source: 'auto',
      overrideKeys: Object.keys(override),
    });
  }

  logger.info(`[Monitor] 扫描完成: 发现 ${projects.length} 个项目 (root=${root}, depth=${maxDepth})`);
  _cache = projects;
  _cacheAt = now;
  return projects;
}

/** 失效缓存（配置变更或强制刷新时调用） */
function invalidate() {
  _cache = null;
  _cacheAt = 0;
}

module.exports = { scan, invalidate };
