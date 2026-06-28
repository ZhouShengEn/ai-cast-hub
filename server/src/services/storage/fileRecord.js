/**
 * 文件传输记录服务
 *
 * 封装 FileTransfer 模型，提供文件传输生命周期管理:
 * - 初始化传输
 * - 更新状态
 * - 查询传输信息
 */

const FileTransferModel = require('../../models/FileTransfer');
const logger = require('../../utils/logger');

/**
 * 初始化文件传输
 * @param {string} fromDeviceId - 发送方设备 UUID
 * @param {string} toDeviceId - 接收方设备 UUID
 * @param {string} fileName - 文件名
 * @param {number} fileSize - 文件大小（字节）
 * @param {string} checksum - 校验和
 * @returns {Promise<object>} 传输记录
 */
async function initTransfer(fromDeviceId, toDeviceId, fileName, fileSize, checksum) {
  const record = await FileTransferModel.create(
    fromDeviceId,
    toDeviceId,
    fileName,
    fileSize,
    checksum
  );
  logger.info(`[FileRecord] 传输初始化 #${record.id}: ${fileName} (${fileSize} bytes) ${fromDeviceId} → ${toDeviceId}`);
  return record;
}

/**
 * 标记传输完成
 * @param {number} transferId - 传输记录 ID
 * @param {boolean} success - 是否成功
 * @returns {Promise<boolean>} 是否更新成功
 */
async function completeTransfer(transferId, success) {
  const status = success ? 'completed' : 'failed';
  const result = await FileTransferModel.updateStatus(transferId, status);
  logger.info(`[FileRecord] 传输 #${transferId} ${status}`);
  return result;
}

/**
 * 查询传输详情
 * @param {number} transferId - 传输记录 ID
 * @returns {Promise<object|null>} 传输记录或 null
 */
async function getTransferInfo(transferId) {
  return FileTransferModel.findById(transferId);
}

/**
 * 查询设备相关传输记录
 * @param {string} deviceId - 设备 UUID
 * @returns {Promise<Array<object>>} 传输记录列表
 */
async function getDeviceTransfers(deviceId) {
  return FileTransferModel.findByDevice(deviceId);
}

/**
 * 记录已接收的分片
 * @param {number} transferId - 传输记录 ID
 * @param {number} chunkIndex - 分片索引
 * @returns {Promise<boolean>} 是否记录成功
 */
async function recordReceivedChunk(transferId, chunkIndex) {
  return FileTransferModel.addReceivedChunk(transferId, chunkIndex);
}

/**
 * 获取已接收的分片列表
 * @param {number} transferId - 传输记录 ID
 * @returns {Promise<number[]>} 已接收分片索引数组
 */
async function getReceivedChunks(transferId) {
  return FileTransferModel.getReceivedChunks(transferId);
}

/**
 * 设置传输超时
 * @param {number} transferId - 传输记录 ID
 * @param {number} timeoutMs - 超时毫秒数
 */
async function setTransferTimeout(transferId, timeoutMs) {
  FileTransferModel.setTransferTimeout(transferId, timeoutMs);
}

/**
 * 清除传输超时
 * @param {number} transferId - 传输记录 ID
 */
async function clearTransferTimeout(transferId) {
  FileTransferModel.clearTransferTimeout(transferId);
}

module.exports = {
  initTransfer,
  completeTransfer,
  getTransferInfo,
  getDeviceTransfers,
  recordReceivedChunk,
  getReceivedChunks,
  setTransferTimeout,
  clearTransferTimeout,
};
