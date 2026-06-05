/**
 * 设备认证中间件
 *
 * 验证请求头中的 X-Device-UUID 和 X-Transfer-Key:
 * - 从 headers 读取 X-Device-UUID 和 X-Transfer-Key
 * - 查询数据库验证设备存在且 transfer_key 匹配
 * - 验证通过后将 device 对象挂载到 req.device 和 req.deviceUuid
 *
 * 白名单路由跳过认证（由 index.js 中的白名单逻辑控制）
 */

const DeviceModel = require('../models/Device');
const logger = require('../utils/logger');

/**
 * 设备认证中间件
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
async function deviceAuth(req, res, next) {
  const authHeader = req.headers['x-device-uuid'];
  const transferKey = req.headers['x-transfer-key'];

  if (!authHeader || typeof authHeader !== 'string' || authHeader.trim().length === 0) {
    return res.status(401).json({
      code: 401,
      data: null,
      message: '缺少设备标识，请先注册设备',
    });
  }

  const deviceUuid = authHeader.trim();

  // 校验 UUID 格式（简单长度校验）
  if (deviceUuid.length < 8 || deviceUuid.length > 128) {
    return res.status(400).json({
      code: 400,
      data: null,
      message: '设备标识格式无效',
    });
  }

  try {
    // 查询数据库验证设备
    const device = await DeviceModel.findByUuid(deviceUuid);

    if (!device) {
      return res.status(401).json({
        code: 401,
        data: null,
        message: '设备未注册，请先注册设备',
      });
    }

    // 如果提供了 transferKey，验证是否匹配
    if (transferKey) {
      if (typeof transferKey !== 'string' || transferKey.trim().length === 0) {
        return res.status(400).json({
          code: 400,
          data: null,
          message: '传输密钥格式无效',
        });
      }

      if (device.transfer_key !== transferKey.trim()) {
        return res.status(401).json({
          code: 401,
          data: null,
          message: '传输密钥不匹配',
        });
      }

      req.transferKey = transferKey.trim();
    }

    // 更新最后在线时间（非阻塞）
    DeviceModel.updateLastSeen(deviceUuid).catch(err => {
      logger.debug(`[DeviceAuth] 更新 lastSeen 失败: ${err.message}`);
    });

    // 挂载设备信息到请求对象
    req.deviceUuid = deviceUuid;
    req.device = device;

    next();
  } catch (err) {
    logger.error(`[DeviceAuth] 设备认证查询失败: ${err.message}`);
    return res.status(500).json({
      code: 500,
      data: null,
      message: '认证服务异常',
    });
  }
}

module.exports = deviceAuth;
