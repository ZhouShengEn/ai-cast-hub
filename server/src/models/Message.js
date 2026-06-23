/**
 * Message 数据模型 — 内存降级方案
 */

/** @type {Map<number, Array<object>>} */
const _messages = new Map();
let _nextId = 1;

async function create(convId, role, content, modelInfo = {}) {
  const now = new Date().toISOString();
  const { modelName = '', inputTokens = 0, outputTokens = 0 } = modelInfo;
  const msg = {
    id: _nextId++,
    conversation_id: convId,
    role,
    content,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    model_name: modelName,
    created_at: now,
  };
  const list = _messages.get(Number(convId)) || [];
  list.push(msg);
  _messages.set(Number(convId), list);
  return msg;
}

async function findByConversation(convId, limit = 20) {
  const list = _messages.get(Number(convId)) || [];
  const sorted = list.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  return sorted.slice(-limit);
}

async function countByConversation(convId) {
  const list = _messages.get(Number(convId)) || [];
  return list.length;
}

async function deleteByConversation(convId) {
  _messages.delete(Number(convId));
  return 0;
}

module.exports = { create, findByConversation, countByConversation, deleteByConversation };
