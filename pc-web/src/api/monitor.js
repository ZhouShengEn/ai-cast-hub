/**
 * 服务器监控模块 — API 客户端
 * 复用全局 client（自动注入设备认证头、解包 { code, data, message }）。
 * 基础路径：/api/v1/server-monitor
 */
import client from './client'

const B = '/server-monitor'

export const monitorApi = {
  // ---- 配置 ----
  getConfig: () => client.get(`${B}/config`),
  updateConfig: (patch) => client.put(`${B}/config`, patch),
  addIgnore: (path) => client.post(`${B}/config/ignore`, { path }),
  removeIgnore: (path) => client.delete(`${B}/config/ignore?path=${encodeURIComponent(path)}`),

  // ---- 扫描 / 服务 ----
  scan: () => client.post(`${B}/scan`),
  getServices: () => client.get(`${B}/services`),
  getService: (id) => client.get(`${B}/services/${id}`),
  getExternal: () => client.get(`${B}/services/external`),

  startService: (id) => client.post(`${B}/services/${id}/start`),
  stopService: (id) => client.post(`${B}/services/${id}/stop`),
  restartService: (id) => client.post(`${B}/services/${id}/restart`),
  buildService: (id) => client.post(`${B}/services/${id}/build`),
  getLogs: (id, lines = 500) => client.get(`${B}/services/${id}/logs?lines=${lines}`),

  getGit: (id) => client.get(`${B}/services/${id}/git`),
  pullGit: (id, rebase = false) => client.post(`${B}/services/${id}/git/pull`, { rebase }),

  setPort: (id, port) => client.put(`${B}/services/${id}/port`, { port }),
  setEnv: (id, env) => client.put(`${B}/services/${id}/env`, { env }),
  setScript: (id, payload) => client.put(`${B}/services/${id}/script`, payload),
  setDisplayName: (id, name) => client.put(`${B}/services/${id}/display-name`, { name }),

  // ---- Nginx ----
  nginxListConfigs: () => client.get(`${B}/nginx/configs`),
  nginxGetConfig: (id) => client.get(`${B}/nginx/configs/${id}`),
  nginxSaveConfig: (id, content) => client.put(`${B}/nginx/configs/${id}`, { content }),
  nginxTest: () => client.post(`${B}/nginx/test`),
  nginxReload: () => client.post(`${B}/nginx/reload`),
  nginxControl: (action) => client.post(`${B}/nginx/control`, { action }),
  nginxLogs: (type, lines = 200) => client.get(`${B}/nginx/logs/${type}?lines=${lines}`),
  nginxLinks: () => client.get(`${B}/nginx/links`),
  nginxSetLink: (payload) => client.post(`${B}/nginx/links`, payload),
  nginxRemoveLink: (linkId) => client.delete(`${B}/nginx/links/${linkId}`),

  // ---- 审计 ----
  getAudit: (params = {}) => client.get(`${B}/audit`, { params }),
  exportAudit: () => client.get(`${B}/audit/export`, { responseType: 'blob' }),

  // ---- 系统 / 角色 ----
  getSystem: () => client.get(`${B}/system`),
  getRoles: () => client.get(`${B}/roles`),
  setRole: (deviceUuid, role) => client.put(`${B}/roles/${deviceUuid}`, { role }),

  health: () => client.get(`${B}/health`),
}

export default monitorApi
