/**
 * 文件传输路由
 *
 * POST /transfer/init           — 初始化文件传输
 * GET  /transfer/:id            — 查询传输详情
 * POST /transfer/:id/complete   — 标记传输完成
 * GET  /transfer/:id/chunks     — 获取已接收的分片列表（断点续传）
 * POST /transfer/:id/chunk      — 记录已接收的分片（断点续传）
 * POST /transfer/:id/expire     — 标记传输过期
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

    // 启动 30 分钟超时计时器
    fileRecordService.setTransferTimeout(record.id, 30 * 60 * 1000).catch(() => {});

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

    // 终止超时计时器
    fileRecordService.clearTransferTimeout(id).catch(() => {});

    res.json({
      code: 0,
      data: { status: success !== false ? 'completed' : 'failed' },
      message: '传输状态已更新',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/file/transfer/:id/chunks
 * 获取已接收的分片列表（用于断点续传）
 */
router.get('/transfer/:id/chunks', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '传输 ID 格式无效',
      });
    }

    const chunks = await fileRecordService.getReceivedChunks(id);

    res.json({
      code: 0,
      data: { receivedChunks: chunks },
      message: 'ok',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/v1/file/transfer/:id/chunk
 * 记录已接收的分片（用于断点续传）
 * Body: { chunkIndex: number }
 */
router.post('/transfer/:id/chunk', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '传输 ID 格式无效',
      });
    }

    const { chunkIndex } = req.body || {};
    if (typeof chunkIndex !== 'number' || chunkIndex < 0) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '分片索引格式无效',
      });
    }

    const recorded = await fileRecordService.recordReceivedChunk(id, chunkIndex);

    if (!recorded) {
      return res.status(404).json({
        code: 404,
        data: null,
        message: '传输记录不存在',
      });
    }

    // 分片活动重置超时计时器（已在 recordReceivedChunk 内部处理）

    res.json({
      code: 0,
      data: { chunkIndex },
      message: '分片已记录',
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/v1/file/transfer/:id/expire
 * 客户端主动标记传输过期（本地超时触发）
 */
router.post('/transfer/:id/expire', async (req, res, next) => {
  try {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) {
      return res.status(400).json({
        code: 400,
        data: null,
        message: '传输 ID 格式无效',
      });
    }

    const updated = await fileRecordService.completeTransfer(id, false);
    // 手动更新为 expired 状态
    const FileTransferModel = require('../../models/FileTransfer');
    await FileTransferModel.updateStatus(id, 'expired');

    res.json({
      code: 0,
      data: { status: 'expired' },
      message: '传输已过期',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
