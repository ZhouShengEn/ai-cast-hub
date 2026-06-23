/**
 * Conversation 数据模型 — 内存降级方案
 */

/** @type {Map<number, object>} */
const _convos = new Map();
let _nextId = 1;

async function create(deviceId, modelProvider, modelName, title = '新对话') {
  const now = new Date().toISOString();
  const id = _nextId++;
  const convo = { id, device_id: deviceId, title, model_provider: modelProvider, model_name: modelName, created_at: now, updated_at: now };
  _convos.set(id, convo);
  return convo;
}

async function findById(id) {
  return _convos.get(Number(id)) || null;
}

async function findByDevice(deviceId, limit = 20, offset = 0) {
  const list = Array.from(_convos.values())
    .filter(c => c.device_id === deviceId)
    .sort((a, b) => b.updated_at.localeCompare(a.updated_at));
  return list.slice(offset, offset + limit);
}

async function countByDevice(deviceId) {
  return Array.from(_convos.values()).filter(c => c.device_id === deviceId).length;
}

async function deleteById(id) {
  return _convos.delete(Number(id));
}

async function updateTitle(id, title) {
  const convo = _convos.get(Number(id));
  if (convo) {
    convo.title = title;
    convo.updated_at = new Date().toISOString();
    return true;
  }
  return false;
}

module.exports = { create, findById, findByDevice, countByDevice, deleteById, updateTitle };
