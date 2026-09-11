/**
 * 服务器监控模块 — 权限控制
 *
 * 复用项目原有设备认证：req.deviceUuid 由 deviceAuth 中间件注入。
 * 角色来源于配置中的 roles 映射；未启用权限控制时默认全部为管理员。
 *
 * 角色：
 *  - admin（管理）：完整启停、重启、拉代码、改配置、编译权限
 *  - readonly（只读）：仅查看状态、日志、配置，禁止运维操作
 */

const config = require('./config');

/**
 * 解析请求对应的角色。
 * @param {string} deviceUuid
 * @returns {'admin'|'readonly'}
 */
function getRole(deviceUuid) {
  if (!config.get().enablePermission) return 'admin';
  return config.get().roles[deviceUuid] || 'readonly';
}

/**
 * 管理员权限中间件。放到需要写操作的路由前。
 * 依赖前置的 deviceAuth（已注入 req.deviceUuid / req.role）。
 */
function requireAdmin(req, res, next) {
  const role = getRole(req.deviceUuid);
  if (role !== 'admin') {
    return res.status(403).json({
      code: 403,
      data: null,
      message: '权限不足：需要管理员权限',
    });
  }
  req.monitorRole = 'admin';
  next();
}

/**
 * 注入角色到 req（只读路由也建议加，便于审计记录操作人角色）。
 */
function attachRole(req, res, next) {
  req.monitorRole = getRole(req.deviceUuid);
  next();
}

module.exports = { getRole, requireAdmin, attachRole };
