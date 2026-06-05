import axios from 'axios'

/**
 * Axios 实例 — 自动认证 + 响应解包
 *
 * 基础路径: /api/v1
 * 自动注入请求头: X-Device-UUID, X-Transfer-Key
 * 统一响应处理: code===0 解包 data, code!==0 抛出错误
 */
const client = axios.create({
  baseURL: '/api/v1',
  timeout: 30000,
  headers: { 'Content-Type': 'application/json' },
})

/** 请求拦截器：自动附加设备认证信息 */
client.interceptors.request.use((config) => {
  const deviceUuid = localStorage.getItem('deviceUuid')
  const transferKey = localStorage.getItem('transferKey')
  if (deviceUuid) {
    config.headers['X-Device-UUID'] = deviceUuid
  }
  if (transferKey) {
    config.headers['X-Transfer-Key'] = transferKey
  }
  return config
})

/** 响应拦截器：统一解包 data，code !== 0 时抛出错误 */
client.interceptors.response.use(
  (response) => {
    const body = response.data
    // 标准 REST 响应: { code, data, message }
    if (body && typeof body.code !== 'undefined') {
      if (body.code === 0) {
        return body.data
      }
      const err = new Error(body.message || '请求失败')
      err.code = body.code
      err.data = body.data
      throw err
    }
    // 非标准响应直接返回
    return body
  },
  (error) => {
    // 网络错误或服务端错误统一处理
    const message = error.response?.data?.message || error.message || '网络请求失败'
    const err = new Error(message)
    err.status = error.response?.status
    err.originalError = error
    throw err
  }
)

export default client
