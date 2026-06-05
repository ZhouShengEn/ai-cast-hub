import client from './client'

/**
 * 设备 API — 注册、绑定、设备列表
 */
export default {
  /** 注册当前设备 */
  async register(name, platform = 'web') {
    return client.post('/device/register', { name, platform })
  },

  /** 获取当前设备信息 */
  async getInfo() {
    return client.get('/device/info')
  },

  /** 绑定目标设备（手机） */
  async bindDevice(targetUuid) {
    return client.post('/device/bind', { targetUuid })
  },

  /** 获取已绑定设备列表 */
  async getDeviceList() {
    return client.get('/device/list')
  },
}
