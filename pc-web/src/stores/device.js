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
    /**
     * 待重连设备集合：uuid -> true
     *
     * 设备离线时**保留绑定关系**，仅标记为「待重连」；
     * 设备重新上线后由服务端推送 device_rebind，自动清除该标记。
     * 这样 App 下线再上线无需任何手动操作即可恢复配对（P1-4）。
     */
    pendingReconnect: {},
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
        const incoming = Array.isArray(data) ? data : []
        // 周期性全量刷新时保留 WS 实时推送的在线状态，避免实时态被整体覆盖（P2-6）
        const prevOnline = new Map(
          this.pairedDevices.map((d) => [d.uuid || d.id || d.deviceUuid, d.isOnline]),
        )
        this.pairedDevices = incoming.map((d) => {
          const uuid = d.uuid || d.id || d.deviceUuid
          return prevOnline.has(uuid) ? { ...d, isOnline: prevOnline.get(uuid) } : d
        })
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
      // 离线 → 标记待重连（绑定关系保留）；上线 → 清除标记
      if (online) {
        this.clearPendingReconnect(deviceUuid)
      } else {
        this.markPendingReconnect(deviceUuid)
      }
    },

    /**
     * 标记设备为「待重连」（下线但绑定仍在）
     * @param {string} deviceUuid
     */
    markPendingReconnect(deviceUuid) {
      if (!deviceUuid) return
      this.pendingReconnect = { ...this.pendingReconnect, [deviceUuid]: true }
    },

    /**
     * 清除「待重连」标记（设备已重新上线并完成自动重连）
     * @param {string} deviceUuid
     */
    clearPendingReconnect(deviceUuid) {
      if (!deviceUuid || !this.pendingReconnect[deviceUuid]) return
      const next = { ...this.pendingReconnect }
      delete next[deviceUuid]
      this.pendingReconnect = next
    },

    /**
     * 服务端推送 device_rebind（设备重新上线自动恢复绑定）
     * @param {object} payload { deviceUuid, deviceName, platform, isOnline, boundAt }
     */
    applyRebind(payload) {
      if (!payload?.deviceUuid) return
      const uuid = payload.deviceUuid
      this.clearPendingReconnect(uuid)
      const idx = this.pairedDevices.findIndex(
        (d) => (d.uuid || d.id || d.deviceUuid) === uuid,
      )
      const merged = {
        uuid,
        deviceUuid: uuid,
        id: uuid,
        name: payload.deviceName || (idx >= 0 ? this.pairedDevices[idx].name : '设备'),
        deviceName: payload.deviceName || (idx >= 0 ? this.pairedDevices[idx].name : '设备'),
        platform: payload.platform || (idx >= 0 ? this.pairedDevices[idx].platform : 'android'),
        isOnline: payload.isOnline !== false,
        lastSeen: new Date().toISOString(),
      }
      if (idx >= 0) {
        this.pairedDevices.splice(idx, 1, { ...this.pairedDevices[idx], ...merged })
      } else {
        // 本地列表里没有（例如刷新过页面）→ 补回，保证绑定关系不丢
        this.pairedDevices = [merged, ...this.pairedDevices]
      }
      this.isConnected = this.pairedDevices.some((d) => d.isOnline)
    },

    /**
     * 设备在线状态文本：在线 / 待重连 / 离线
     * @param {object} device
     */
    deviceStatusText(device) {
      const uuid = device?.uuid || device?.id || device?.deviceUuid
      if (device?.isOnline) return '在线'
      if (uuid && this.pendingReconnect[uuid]) return '待重连'
      return '离线'
    },
  },
})
