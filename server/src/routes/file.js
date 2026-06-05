/**
 * 文件传输路由
 *
 * POST /transfer/init       — 初始化文件传输
 * GET  /transfer/:id        — 查询传输详情
 * POST /transfer/:id/complete — 标记传输完成
 */

const { Router } = require('express');
const { fileTransferInitSchema } = require('../utils/validators');
const fileRecordService = require('../services/storage/fileRecord');
const DeviceModel = require('../models/Device');
const logger = require('../utils/logger');

const router = Router();

/**
 * POST /api/v1/file/transfer/init
 * 初始化文件传输
 * Body: { fileName, fileSize, checksum, targetDeviceId }
 */
router.post('/transfer/init', async (req, res, next) => {
  try {
    const { fileName, fileSize, checksum, targetDeviceId } = fileTransferInitSchema.parse(req.body);

    // 验证目标设备存在
    const targetDevice = await DeviceModel.findByUuid(targetDeviceId);
    if (!targetDevice) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '目标设备未注册',
      });
    }

    const record = await fileRecordService.initTransfer(
      req.deviceUuid,
      targetDeviceId,
      fileName,
      fileSize,
      checksum
    );

    res.json({
      code: 0,
      data: {
        transferId: record.id,
        fileName: record.file_name,
        fileSize: record.file_size,
        status: record.status,
        createdAt: record.created_at,
      },
      message: '传输已初始化',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/file/transfer/:id
 * 查询传输详情
 */
router.get('/transfer/:id', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '传输 ID 格式无效',
      });
    }

    const record = await fileRecordService.getTransferInfo(id);
    if (!record) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '传输记录不存在',
      });
    }

    res.json({
      code: 0,
      data: {
        id: record.id,
        fromDeviceId: record.from_device_id,
        toDeviceId: record.to_device_id,
        fileName: record.file_name,
        fileSize: record.file_size,
        status: record.status,
        checksum: record.checksum,
        createdAt: record.created_at,
        completedAt: record.completed_at,
      },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/v1/file/transfer/:id/complete
 * 标记传输完成
 * Body: { success: boolean, checksum?: string }
 */
router.post('/transfer/:id/complete', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '传输 ID 格式无效',
      });
    }

    const { success } = req.body || {};
    const updated = await fileRecordService.completeTransfer(id, success !== false);

    if (!updated) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '传输记录不存在',
      });
    }

    res.json({
      code: 0,
      data: { status: success !== false ? 'completed' : 'failed' },
      message: '传输状态已更新',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
