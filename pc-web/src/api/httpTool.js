import client from './client'

/**
 * HTTP 接口调试工具 — 服务端 API
 *
 * 数据全部存服务端（server/data/store.json），全局共享一份，
 * 换设备/换浏览器登录后读到的都是同一份接口列表与请求记录。
 */
export default {
  // ---- 接口列表 ----
  /** @returns {Promise<{list: Array}>} */
  async listApis() {
    return client.get('/http-tool/apis')
  },
  async createApi(payload) {
    return client.post('/http-tool/apis', payload)
  },
  /** 部分更新：未传的字段沿用原值（因此重命名只需传 name） */
  async updateApi(id, payload) {
    return client.put(`/http-tool/apis/${id}`, payload)
  },
  async deleteApi(id) {
    return client.delete(`/http-tool/apis/${id}`)
  },

  // ---- 请求记录 ----
  /** @returns {Promise<{list: Array}>} 已按时间倒序 */
  async listRecords() {
    return client.get('/http-tool/records')
  },
  async createRecord(payload) {
    return client.post('/http-tool/records', payload)
  },
  async deleteRecord(id) {
    return client.delete(`/http-tool/records/${id}`)
  },
  async clearRecords() {
    return client.delete('/http-tool/records')
  },
}
