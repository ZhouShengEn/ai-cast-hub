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
 * Body: { targetUuid: string }
 */
router.post('/bind', async (req, res, next) => {
  try {
    const { targetUuid } = req.body || {}; // 前端传的是 targetUuid
    const myDeviceUuid = req.deviceUuid || (req.headers['x-device-uuid'] || '').trim();

    if (!targetUuid) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '请提供目标设备 UUID',
      });
    }

    if (!myDeviceUuid) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '缺少当前设备 UUID',
      });
    }

    // 检查目标设备是否存在
    const targetDevice = await DeviceModel.findByUuid(targetUuid);
    if (!targetDevice) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '目标设备未注册',
      });
    }

    // 检查当前设备是否存在，不存在则自动注册（手机端可能还未注册）
    let myDevice = await DeviceModel.findByUuid(myDeviceUuid);
    if (!myDevice) {
      // 自动注册手机设备
      myDevice = await DeviceModel.register(
        myDeviceUuid, 
        `Mobile-${myDeviceUuid.substring(0, 8)}`, 
        'android' // 默认 android
      );
    }

    // 执行双向绑定
    const bindResult = await DeviceModel.bindDevices(myDeviceUuid, targetUuid);

    logger.info(`[Device] 设备绑定成功: ${myDeviceUuid} <-> ${targetUuid}`);

    res.json({
      code: 0,
      data: {
        success: true,
        targetDevice: {
          deviceUuid: targetDevice.device_uuid,
          deviceName: targetDevice.device_name,
          platform: targetDevice.platform,
        },
        boundAt: bindResult.boundAt,
      },
      message: '绑定成功',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/device/list
 * 列出当前设备的已配对设备
 */
router.get('/list', async (req, res, next) => {
  try {
    const myDeviceUuid = req.deviceUuid || (req.headers['x-device-uuid'] || '').trim();
    
    if (!myDeviceUuid) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '缺少设备 UUID',
      });
    }

    // 获取已配对设备列表
    const pairedDevices = await DeviceModel.getPairedDevices(myDeviceUuid);

    res.json({
      code: 0,
      data: pairedDevices.map(d => ({
        uuid: d.device_uuid,
        id: d.device_uuid, // 兼容前端
        name: d.device_name,
        deviceName: d.device_name,
        platform: d.platform || 'unknown',
        lastSeen: d.last_seen_at,
        lastSeenAt: d.last_seen_at,
        isOnline: d.isOnline || true,
      })),
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
