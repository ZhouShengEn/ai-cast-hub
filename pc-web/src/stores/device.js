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
      try {
        const data = await deviceApi.register(name, 'web')
        this.device = data
        // 持久化设备认证信息
        if (data.uuid) localStorage.setItem('deviceUuid', data.uuid)
        if (data.transferKey) localStorage.setItem('transferKey', data.transferKey)
        if (data.name) localStorage.setItem('deviceName', data.name)
        // 生成绑定二维码
        this.generateQRCode()
        return data
      } catch (err) {
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
    generateQRCode() {
      const uuid = this.device?.uuid || localStorage.getItem('deviceUuid')
      if (!uuid) return
      this.qrCodeData = JSON.stringify({
        deviceUuid: uuid,
        roomType: 'bind',
      })
    },

    /** 清除错误 */
    clearError() {
      this.error = null
    },
  },
})
