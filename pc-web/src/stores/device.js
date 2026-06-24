import { defineStore } from 'pinia'
import deviceApi from '../api/device'

/**
 * 设备状态 Store — 管理本设备注册、绑定、设备列表
 */
export const useDeviceStore = defineStore('device', {
  state: () => ({
    /** 当前设备信息 */
    device: null,
    /** 已配对设备列表 */
    pairedDevices: [],
    /** 二维码数据（JSON 字符串） */
    qrCodeData: null,
    /** 是否有已连接设备 */
    isConnected: false,
    /** 加载状态 */
    loading: false,
    /** 错误信息 */
    error: null,
  }),

  actions: {
    /** 注册当前 PC 设备 */
    async registerDevice(name = 'PC Web') {
      this.loading = true
      this.error = null
      // 先生成并持久化 UUID（不管 API 是否成功）
      if (!localStorage.getItem('deviceUuid')) {
        localStorage.setItem('deviceUuid', crypto.randomUUID())
      }
      try {
        const data = await deviceApi.register(name, 'web')
        this.device = data
        if (data.transferKey) localStorage.setItem('transferKey', data.transferKey)
        if (data.deviceName) localStorage.setItem('deviceName', data.deviceName)
        return data
      } catch (err) {
        // API 失败也使用本地 UUID（离线可用）
        this.error = err.message
        throw err
      } finally {
        this.loading = false
      }
    },

    /** 获取当前设备信息 */
    async fetchDeviceInfo() {
      this.loading = true
      this.error = null
      try {
        const data = await deviceApi.getInfo()
        this.device = data
        this.isConnected = !!(data && data.pairedDevices && data.pairedDevices.length > 0)
        if (data.pairedDevices) {
          this.pairedDevices = data.pairedDevices
        }
        return data
      } catch (err) {
        this.error = err.message
        throw err
      } finally {
        this.loading = false
      }
    },

    /** 绑定手机设备 */
    async bindDevice(targetUuid) {
      this.loading = true
      this.error = null
      try {
        const data = await deviceApi.bindDevice(targetUuid)
        this.isConnected = true
        await this.fetchDeviceList()
        return data
      } catch (err) {
        this.error = err.message
        throw err
      } finally {
        this.loading = false
      }
    },

    /** 获取已绑定设备列表 */
    async fetchDeviceList() {
      try {
        const data = await deviceApi.getDeviceList()
        this.pairedDevices = Array.isArray(data) ? data : []
        this.isConnected = this.pairedDevices.length > 0
        return data
      } catch (err) {
        this.error = err.message
        throw err
      }
    },

    /** 生成当前设备的绑定二维码数据 */
    async generateQRCode() {
      // 优先使用 API 返回的 deviceUuid，其次从 localStorage 获取
      const uuid = this.device?.deviceUuid || localStorage.getItem('deviceUuid')
      if (!uuid) {
        console.warn('[DeviceStore] 无法生成二维码：缺少设备 UUID')
        this.qrCodeData = null
        return
      }

      // 获取服务器局域网地址，供手机扫码后直连
      let serverUrl = null
      try {
        const info = await deviceApi.getServerInfo()
        serverUrl = info?.serverUrl || null
      } catch (err) {
        console.warn('[DeviceStore] 获取服务器地址失败，使用 fallback:', err.message)
      }
      // Fallback: 使用当前页面的 hostname + 端口 3000（server 直连端口）
      if (!serverUrl) {
        serverUrl = `http://${window.location.hostname}:3000`
        console.log('[DeviceStore] 使用 fallback serverUrl:', serverUrl)
      }

      console.log('[DeviceStore] 生成二维码，UUID:', uuid, 'serverUrl:', serverUrl)
      this.qrCodeData = JSON.stringify({
        deviceUuid: uuid,
        roomType: 'bind',
        serverUrl, // 服务器地址，手机扫码后据此直连
        timestamp: Date.now(),
      })
    },

    /** 清除错误 */
    clearError() {
      this.error = null
    },
  },
})
