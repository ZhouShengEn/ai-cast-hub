/**
 * TokenUsage 数据模型 — 内存降级方案
 */

/** @type {Array<object>} */
const _records = [];

async function record(deviceId, modelName, provider, inputTokens, outputTokens) {
  const now = new Date().toISOString();
  const rec = {
    id: _records.length + 1,
    device_id: deviceId,
    model_name: modelName,
    model_provider: provider,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cost: 0,
    created_at: now,
  };
  _records.push(rec);
  return rec;
}

function _filter(deviceId, startDate, endDate) {
  return _records.filter(r => {
    if (r.device_id !== deviceId) return false;
    if (startDate && r.created_at < startDate) return false;
    if (endDate && r.created_at > endDate) return false;
    return true;
  });
}

async function queryByDevice(deviceId, startDate, endDate) {
  return _filter(deviceId, startDate, endDate)
    .sort((a, b) => b.created_at.localeCompare(a.created_at))
    .slice(0, 500);
}

async function aggregateByModel(deviceId, startDate, endDate) {
  const rows = _filter(deviceId, startDate, endDate);
  const map = new Map();
  for (const r of rows) {
    const key = `${r.model_name}|${r.model_provider}`;
    if (!map.has(key)) {
      map.set(key, {
        model_name: r.model_name,
        model_provider: r.model_provider,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_tokens: 0,
        total_cost: 0,
        request_count: 0,
      });
    }
    const s = map.get(key);
    s.total_input_tokens += r.input_tokens;
    s.total_output_tokens += r.output_tokens;
    s.total_tokens += r.input_tokens + r.output_tokens;
    s.total_cost += r.cost;
    s.request_count++;
  }
  return Array.from(map.values()).sort((a, b) => b.total_tokens - a.total_tokens);
}

async function aggregateByDevice(startDate, endDate) {
  let rows = _records;
  if (startDate) rows = rows.filter(r => r.created_at >= startDate);
  if (endDate) rows = rows.filter(r => r.created_at <= endDate);
  const map = new Map();
  for (const r of rows) {
    if (!map.has(r.device_id)) {
      map.set(r.device_id, {
        device_id: r.device_id,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_tokens: 0,
        total_cost: 0,
        request_count: 0,
      });
    }
    const s = map.get(r.device_id);
    s.total_input_tokens += r.input_tokens;
    s.total_output_tokens += r.output_tokens;
    s.total_tokens += r.input_tokens + r.output_tokens;
    s.total_cost += r.cost;
    s.request_count++;
  }
  return Array.from(map.values()).sort((a, b) => b.total_tokens - a.total_tokens);
}

module.exports = { record, queryByDevice, aggregateByModel, aggregateByDevice };
