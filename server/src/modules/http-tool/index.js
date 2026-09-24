/**
 * HTTP 接口调试工具模块 — 模块入口
 *
 * 解耦原则：完全独立，不依赖、不修改投屏 / WebRTC / 设备等原有业务。
 * - router: 挂载到 /api/v1/http-tool
 * - 数据: server/data/store.json（复用 config/database 的 dataStore）
 */

const router = require('./routes');

module.exports = { router };
