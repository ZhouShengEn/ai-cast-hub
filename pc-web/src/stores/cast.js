import { defineStore } from 'pinia'

/**
 * 投屏状态 Store — 管理 WebRTC 投屏连接状态
 */
export const useCastStore = defineStore('cast', {
  state: () => ({
    /** 连接状态: 'disconnected' | 'connecting' | 'connected' | 'error' */
    connectionState: 'disconnected',
    /** 当前房间 ID */
    roomId: null,
    /** 远程视频流（MediaStream） */
    remoteStream: null,
    /** 投屏二维码数据 */
    qrCodeData: null,
    /** 错误信息 */
    error: null,
  }),

  actions: {
    /** 生成投屏二维码 */
    generateQRCode(deviceUuid) {
      this.qrCodeData = JSON.stringify({
        deviceUuid: deviceUuid || localStorage.getItem('deviceUuid') || '',
        roomType: 'cast',
      })
    },

    /** 设置连接状态 */
    setConnectionState(state) {
      this.connectionState = state
      if (state === 'error') {
        this.error = this.error || '连接失败'
      }
    },

    /** 设置远程视频流 */
    setRemoteStream(stream) {
      this.remoteStream = stream
    },

    /** 清理投屏状态 */
    cleanup() {
      if (this.remoteStream) {
        this.remoteStream.getTracks().forEach((track) => track.stop())
      }
      this.remoteStream = null
      this.roomId = null
      this.connectionState = 'disconnected'
      this.error = null
    },
  },
})
