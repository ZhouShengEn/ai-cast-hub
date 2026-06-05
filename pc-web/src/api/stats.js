import client from './client'

/**
 * 统计 API — Token 用量统计
 */
export default {
  /** 获取 Token 用量统计 */
  async getTokenStats(params = {}) {
    return client.get('/stats/tokens', { params })
  },

  /** 按模型获取 Token 用量 */
  async getTokenStatsByModel(params = {}) {
    return client.get('/stats/tokens/by-model', { params })
  },
}
