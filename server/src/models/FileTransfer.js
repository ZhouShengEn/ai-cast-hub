/**
 * FileTransfer 数据模型 — 内存降级方案
 *
 * 支持断点续传：30 分钟超时自动过期，活动重置计时器。
 */

/** 传输超时（30 分钟） */
const TRANSFER_TIMEOUT_MS = 30 * 60 * 1000;

/** @type {Map<number, object>} */
const _transfers = new Map();
/** @type {Map<number, Set<number>>} 记录每个传输已接收的分片索引 */
const _receivedChunks = new Map();
/** @type {Map<number, NodeJS.Timeout>} 传输超时计时器 */
const _transferTimers = new Map();
let _nextId = 1;

async function create(fromDeviceId, toDeviceId, fileName, fileSize, checksum) {
  const now = new Date().toISOString();
  const id = _nextId++;
  const transfer = { id, from_device_id: fromDeviceId, to_device_id: toDeviceId, file_name: fileName, file_size: fileSize, status: 'pending', checksum, created_at: now, completed_at: null };
  _transfers.set(id, transfer);
  _receivedChunks.set(id, new Set());
  setTransferTimeout(id, TRANSFER_TIMEOUT_MS);
  return transfer;
}

async function updateStatus(id, status) {
  const transfer = _transfers.get(Number(id));
  if (!transfer) return false;
  transfer.status = status;
  if (status === 'completed' || status === 'failed' || status === 'expired') {
    transfer.completed_at = new Date().toISOString();
    clearTransferTimeout(id);
    if (status === 'expired') {
      cleanupExpiredTransfer(id);
    }
  }
  return true;
}

async function findByDevice(deviceId) {
  return Array.from(_transfers.values())
    .filter(t => t.from_device_id === deviceId || t.to_device_id === deviceId)
    .sort((a, b) => b.created_at.localeCompare(a.created_at));
}

async function findById(id) {
  return _transfers.get(Number(id)) || null;
}

/**
 * 记录已接收的分片（重置超时计时器）
 * @param {number} id - 传输 ID
 * @param {number} chunkIndex - 分片索引
 * @returns {Promise<boolean>}
 */
async function addReceivedChunk(id, chunkIndex) {
  const chunks = _receivedChunks.get(Number(id));
  if (!chunks) return false;
  chunks.add(chunkIndex);
  // 活动重置超时
  setTransferTimeout(id, TRANSFER_TIMEOUT_MS);
  return true;
}

/**
 * 获取已接收的分片列表
 * @param {number} id - 传输 ID
 * @returns {Promise<number[]>}
 */
async function getReceivedChunks(id) {
  const chunks = _receivedChunks.get(Number(id));
  return chunks ? Array.from(chunks).sort((a, b) => a - b) : [];
}

/**
 * 设置传输超时计时器（自动过期未完成的传输）
 * @param {number} id - 传输 ID
 * @param {number} timeoutMs - 超时毫秒数
 */
function setTransferTimeout(id, timeoutMs) {
  clearTransferTimeout(id);
  const timer = setTimeout(() => {
    const transfer = _transfers.get(Number(id));
    if (transfer && (transfer.status === 'pending' || transfer.status === 'transferring')) {
      updateStatus(id, 'expired');
      console.log(`[FileTransfer] 传输 #${id} 已过期（${timeoutMs / 60000} 分钟无活动）`);
    }
  }, timeoutMs);
  _transferTimers.set(Number(id), timer);
}

/**
 * 清除传输超时计时器
 * @param {number} id - 传输 ID
 */
function clearTransferTimeout(id) {
  const timer = _transferTimers.get(Number(id));
  if (timer) {
    clearTimeout(timer);
    _transferTimers.delete(Number(id));
  }
}

/**
 * 清理过期传输的所有数据
 * @param {number} id - 传输 ID
 */
function cleanupExpiredTransfer(id) {
  _receivedChunks.delete(Number(id));
  _transferTimers.delete(Number(id));
  // 保留传输记录（状态已设为 expired）供查询
}

module.exports = {
  create,
  updateStatus,
  findByDevice,
  findById,
  addReceivedChunk,
  getReceivedChunks,
  setTransferTimeout,
  clearTransferTimeout,
  cleanupExpiredTransfer,
};
