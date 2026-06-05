/**
 * 设备管理路由
 *
 * POST /register  — 注册设备
 * GET  /info      — 获取当前设备信息
 * POST /bind      — 扫码绑定PC设备
 * GET  /list      — 列出已配对设备
 */

const { Router } = require('express');
const DeviceModel = require('../models/Device');
const { generateTransferKey } = require('../utils/uid');
const { deviceRegisterSchema } = require('../utils/validators');
const logger = require('../utils/logger');

const router = Router();

/**
 * POST /api/v1/device/register
 * 注册新设备或更新已有设备信息
 * Body: { deviceName: string, platform: 'android'|'ios'|'web' }
 */
router.post('/register', async (req, res, next) => {
  try {
    const { deviceName, platform } = deviceRegisterSchema.parse(req.body);

    // /register 在白名单中，deviceAuth 不会运行，直接从 header 读取
    const deviceUuid = req.deviceUuid || (req.headers['x-device-uuid'] || '').trim();
    if (!deviceUuid) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '缺少设备标识 (X-Device-UUID)',
      });
    }
    const transferKey = generateTransferKey();

    const device = await DeviceModel.register(deviceUuid, deviceName, platform, transferKey);

    logger.info(`[Device] 设备注册: ${deviceUuid} (${deviceName}) platform=${platform}`);

    res.json({
      code: 0,
      data: {
        deviceUuid: device.device_uuid,
        deviceName: device.device_name,
        platform: device.platform,
        transferKey,
        createdAt: device.created_at,
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/device/info
 * 获取当前已认证设备的信息
 */
router.get('/info', async (req, res, next) => {
  try {
    const device = await DeviceModel.findByUuid(req.deviceUuid);
    if (!device) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '设备未注册',
      });
    }

    // 更新最后在线时间
    await DeviceModel.updateLastSeen(req.deviceUuid);

    res.json({
      code: 0,
      data: {
        deviceUuid: device.device_uuid,
        deviceName: device.device_name,
        platform: device.platform,
        createdAt: device.created_at,
        lastSeenAt: device.last_seen_at,
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/v1/device/bind
 * 扫码绑定 PC 设备
 * Body: { targetDeviceUuid: string }
 */
router.post('/bind', async (req, res, next) => {
  try {
    const { targetDeviceUuid } = req.body || {};
    const myDeviceUuid = req.deviceUuid || (req.headers['x-device-uuid'] || '').trim();

    if (!targetDeviceUuid) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '请提供目标设备 UUID',
      });
    }

    const targetDevice = await DeviceModel.findByUuid(targetDeviceUuid);
    if (!targetDevice) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '目标设备未注册',
      });
    }

    logger.info(`[Device] 设备绑定: ${myDeviceUuid} → ${targetDeviceUuid}`);

    res.json({
      code: 0,
      data: {
        deviceUuid: targetDevice.device_uuid,
        deviceName: targetDevice.device_name,
        platform: targetDevice.platform,
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/device/list
 * 列出所有已配对设备
 */
router.get('/list', async (req, res, next) => {
  try {
    const devices = await DeviceModel.listAll();

    res.json({
      code: 0,
      data: {
        devices: devices.map(d => ({
          deviceUuid: d.device_uuid,
          deviceName: d.device_name,
          platform: d.platform,
          createdAt: d.created_at,
          lastSeenAt: d.last_seen_at,
        })),
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
