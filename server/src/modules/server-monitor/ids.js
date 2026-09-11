/**
 * 服务器监控模块 — 项目 ID 编解码
 *
 * 项目以绝对路径唯一标识。为在 URL / 路由中安全传递，用 base64url 编码。
 * 可逆，便于服务端从 id 还原路径（无需额外存储映射）。
 */

function encodeProjectId(absPath) {
  return Buffer.from(absPath, 'utf8').toString('base64url');
}

function decodeProjectId(id) {
  try {
    return Buffer.from(id, 'base64url').toString('utf8');
  } catch {
    return null;
  }
}

module.exports = { encodeProjectId, decodeProjectId };
