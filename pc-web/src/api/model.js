import client from './client'

/**
 * 模型 API — 模型列表、API Key 管理
 */
export default {
  /** 获取可用 AI 模型列表 */
  async getModels() {
    return client.get('/model/list')
  },

  /** 添加 API Key */
  async addApiKey(provider, apiKey, label = '') {
    return client.post('/model/apikey', { provider, apiKey, label })
  },

  /** 获取已配置的 API Key 列表 */
  async getApiKeys() {
    return client.get('/model/apikeys')
  },

  /** 删除 API Key */
  async deleteApiKey(id) {
    return client.delete(`/model/apikey/${id}`)
  },
}
