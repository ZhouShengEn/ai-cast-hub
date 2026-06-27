/**
 * ApiKey 数据模型 — 内存降级方案
 */

/** @type {Map<string, object>} */
const _keys = new Map();
let _nextId = 1;

async function save(provider, encryptedKey, label = '') {
  const now = new Date().toISOString();
  if (_keys.has(provider)) {
    const existing = _keys.get(provider);
    existing.encrypted_key = encryptedKey;
    existing.key_label = label;
    existing.created_at = now;
    return existing;
  }
  const key = { id: _nextId++, provider, encrypted_key: encryptedKey, key_label: label, created_at: now };
  _keys.set(provider, key);
  return key;
}

async function findByProvider(provider) {
  return _keys.get(provider) || null;
}

async function listAll() {
  return Array.from(_keys.values()).sort((a, b) => b.created_at.localeCompare(a.created_at));
}

async function deleteById(id) {
  for (const [provider, key] of _keys) {
    if (key.id === Number(id)) {
      _keys.delete(provider);
      return key; // 返回被删记录，供调用方获取 provider 名称
    }
  }
  return null;
}

module.exports = { save, findByProvider, listAll, deleteById };
