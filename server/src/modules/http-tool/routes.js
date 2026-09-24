/**
 * HTTP 接口调试工具 — REST API 路由
 *
 * 挂载于 /api/v1/http-tool（在 src/routes/index.js 中挂载）。
 * 复用全局 deviceAuth（src/index.js 统一包裹），此处不做账号/权限隔离：
 * 按产品要求全站共享同一份接口列表与请求记录。
 *
 * 约定响应：{ code:0, data, message }，错误 code 非 0。
 *
 * 接口:
 *   GET    /apis              接口列表
 *   POST   /apis              新增接口
 *   PUT    /apis/:id          更新接口（改名/改参数）
 *   DELETE /apis/:id          删除接口
 *   GET    /records           请求记录（时间倒序）
 *   POST   /records           追加一条请求记录
 *   DELETE /records/:id       删除单条记录
 *   DELETE /records           清空全部记录
 */

const { Router } = require('express');
const store = require('./store');

const router = Router();

const ok = (res, data, message = 'ok') => res.json({ code: 0, data, message });
const fail = (res, status, message) =>
  res.status(status).json({ code: status, data: null, message });

// ============================================================
// 接口列表
// ============================================================

router.get('/apis', (req, res) => {
  ok(res, { list: store.listApis() });
});

router.post('/apis', (req, res) => {
  const result = store.saveApi(req.body || {});
  if (result.error) return fail(res, 400, result.error);
  ok(res, { api: result.api }, '接口已保存');
});

router.put('/apis/:id', (req, res) => {
  const result = store.saveApi(req.body || {}, req.params.id);
  if (result.error) {
    return fail(res, result.error === '接口不存在' ? 404 : 400, result.error);
  }
  ok(res, { api: result.api }, '接口已更新');
});

router.delete('/apis/:id', (req, res) => {
  const result = store.deleteApi(req.params.id);
  if (result.error) return fail(res, 404, result.error);
  ok(res, {}, '接口已删除');
});

// ============================================================
// 请求记录
// ============================================================

router.get('/records', (req, res) => {
  ok(res, { list: store.listRecords() });
});

router.post('/records', (req, res) => {
  const result = store.addRecord(req.body || {});
  if (result.error) return fail(res, 400, result.error);
  ok(res, { record: result.record }, '记录已保存');
});

router.delete('/records/:id', (req, res) => {
  const result = store.deleteRecord(req.params.id);
  if (result.error) return fail(res, 404, result.error);
  ok(res, {}, '记录已删除');
});

// 清空全部记录（注意：该路由必须放在 /records/:id 之后，避免 clear 被当成 id）
router.delete('/records', (req, res) => {
  store.clearRecords();
  ok(res, {}, '记录已清空');
});

module.exports = router;
