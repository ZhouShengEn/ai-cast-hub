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
    /** 连接码（6 位数字） */
    pairCode: null,
    /** 连接码过期时间戳（毫秒） */
    pairCodeExpiresAt: null,
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

    /** 生成连接码（替代二维码） */
    async generatePairCode() {
      const uuid = this.device?.deviceUuid || localStorage.getItem('deviceUuid')
      if (!uuid) {
        console.warn('[DeviceStore] 无法生成连接码：缺少设备 UUID')
        this.pairCode = null
        return
      }
      try {
        const data = await deviceApi.generatePairCode()
        this.pairCode = data?.pairCode || null
        // expiresIn 单位为秒
        this.pairCodeExpiresAt = Date.now() + (data?.expiresIn || 300) * 1000
        console.log('[DeviceStore] 连接码:', this.pairCode, '过期时间:', new Date(this.pairCodeExpiresAt).toLocaleTimeString())
      } catch (err) {
        console.warn('[DeviceStore] 生成连接码失败:', err.message)
        this.pairCode = null
      }
    },

    /** 清除错误 */
    clearError() {
      this.error = null
    },

    /** 解除设备绑定 */
    async unbindDevice(targetUuid) {
      this.loading = true
      this.error = null
      try {
        await deviceApi.unbindDevice(targetUuid)
        await this.fetchDeviceList()
        return true
      } catch (err) {
        this.error = err.message
        throw err
      } finally {
        this.loading = false
      }
    },

    /**
     * 收到服务端 device_status 事件时，即时更新已配对设备的在线状态（无需重新拉取列表）。
     * @param {string} deviceUuid - 状态变化的设备 UUID
     * @param {boolean} online - 是否在线
     */
    setDeviceOnline(deviceUuid, online) {
      if (!deviceUuid) return
      const target = this.pairedDevices.find(
        (d) => (d.uuid || d.id || d.deviceUuid) === deviceUuid,
      )
      if (!target) return
      const idx = this.pairedDevices.indexOf(target)
      const updated = {
        ...target,
        isOnline: online,
        lastSeen: online ? new Date().toISOString() : target.lastSeen,
      }
      this.pairedDevices.splice(idx, 1, updated)
      this.isConnected = this.pairedDevices.some((d) => d.isOnline)
    },
  },
})
