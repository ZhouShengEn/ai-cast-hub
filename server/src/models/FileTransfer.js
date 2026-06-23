/**
 * FileTransfer 数据模型 — 内存降级方案
 */

/** @type {Map<number, object>} */
const _transfers = new Map();
let _nextId = 1;

async function create(fromDeviceId, toDeviceId, fileName, fileSize, checksum) {
  const now = new Date().toISOString();
  const id = _nextId++;
  const transfer = { id, from_device_id: fromDeviceId, to_device_id: toDeviceId, file_name: fileName, file_size: fileSize, status: 'pending', checksum, created_at: now, completed_at: null };
  _transfers.set(id, transfer);
  return transfer;
}

async function updateStatus(id, status) {
  const transfer = _transfers.get(Number(id));
  if (!transfer) return false;
  transfer.status = status;
  if (status === 'completed' || status === 'failed') {
    transfer.completed_at = new Date().toISOString();
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

module.exports = { create, updateStatus, findByDevice, findById };
