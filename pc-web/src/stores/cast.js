import { defineStore } from 'pinia'

const LOG = '[CastStore]'

/**
 * 投屏连接阶段。
 *
 * 比原来多拆出 pairing / signaling 两档，便于 UI 和日志定位「卡在哪一步」：
 *   disconnected 未连接
 *   pairing      配对中（已发起投屏，等待手机接入房间）
 *   signaling    信令已连接（WebSocket 就绪 + 房间已建立）
 *   connecting   WebRTC 连接中（ICE 协商）
 *   connected    投屏成功
 *   error        连接失败
 */
export const CastStage = {
  DISCONNECTED: 'disconnected',
  PAIRING: 'pairing',
  SIGNALING: 'signaling',
  CONNECTING: 'connecting',
  CONNECTED: 'connected',
  ERROR: 'error',
}

const STAGE_TEXT = {
  disconnected: '未连接',
  pairing: '配对中',
  signaling: '信令已连接',
  connecting: 'WebRTC 连接中',
  connected: '投屏成功',
  error: '连接失败',
}

/**
 * 投屏状态 Store
 *
 * 约定：UI 一律只读这里的状态，组件内不得再维护一份独立的连接状态。
 * 所有状态变更必须经过 setConnectionState / setError，便于集中打日志和清残留。
 */
export const useCastStore = defineStore('cast', {
  state: () => ({
    /** 连接阶段，取值见 CastStage */
    connectionState: CastStage.DISCONNECTED,
    /** 当前房间 ID */
    roomId: null,
    /** 远程视频流（MediaStream） */
    remoteStream: null,
    /** 投屏二维码数据 */
    qrCodeData: null,
    /** 错误信息（仅 error 阶段非空） */
    error: null,

    // ---- 细粒度子状态，用于定位与 UI 判断 ----
    /** 信令 WebSocket 是否已连接 */
    signalingConnected: false,
    /** WebRTC PeerConnection 的 connectionState */
    peerState: 'new',
    /** 远程控制 DataChannel 是否已打开 */
    controlChannelOpen: false,
    /** 最近一次状态变更时间戳 */
    lastUpdatedAt: null,
  }),

  getters: {
    /** 当前阶段的中文描述 */
    stageText: (state) => STAGE_TEXT[state.connectionState] || state.connectionState,
    /** 是否允许下发远程控制指令 */
    canControl: (state) =>
      state.connectionState === CastStage.CONNECTED && state.controlChannelOpen,
  },

  actions: {
    /**
     * 统一状态写入口
     * @param {string} state - CastStage 取值
     * @param {string} [reason] - 变更原因，仅用于日志
     */
    setConnectionState(state, reason = '') {
      const prev = this.connectionState

      // 关键修复：只要不是失败态就清空历史错误。
      // 旧实现只在进入 error 时写 error、从不清空，导致一次失败后
      // 即使后续重连成功，UI 也永久停留在「连接失败」。
      if (state !== CastStage.ERROR) {
        this.error = null
      }

      this.connectionState = state
      this.lastUpdatedAt = Date.now()

      if (prev !== state) {
        const extra = reason ? ` (${reason})` : ''
        console.log(`${LOG} ${STAGE_TEXT[prev]} → ${STAGE_TEXT[state]}${extra}`)
      }
    },

    /** 进入失败态并记录原因 */
    setError(message) {
      this.error = message || '连接失败'
      this.connectionState = CastStage.ERROR
      this.lastUpdatedAt = Date.now()
      console.warn(`${LOG} ❌ ${this.error}`)
    },

    /**
     * 为重连 / 重新配对重置全部状态。
     * 发起重连、设备重新配对、重建 PeerConnection 前都必须调用，
     * 否则旧的错误标记与子状态会残留到新会话里。
     */
    resetForReconnect() {
      console.log(`${LOG} 重置状态，准备重新连接`)
      this.error = null
      this.connectionState = CastStage.DISCONNECTED
      this.signalingConnected = false
      this.peerState = 'new'
      this.controlChannelOpen = false
      this.roomId = null
      this.lastUpdatedAt = Date.now()
    },

    setRoomId(roomId) {
      this.roomId = roomId
    },

    setSignalingConnected(connected) {
      if (this.signalingConnected === connected) return
      this.signalingConnected = connected
      console.log(`${LOG} 信令 ${connected ? '已连接' : '已断开'}`)
      // 信令恢复且当前处于失败态时，主动退回未连接态，允许后续流程继续推进
      if (connected && this.connectionState === CastStage.ERROR) {
        this.setConnectionState(CastStage.DISCONNECTED, '信令恢复，清除失败标记')
      }
    },

    setPeerState(state) {
      if (this.peerState === state) return
      this.peerState = state
      console.log(`${LOG} PeerConnection: ${state}`)

      // 链路恢复：只要 PC 回到 connected，就清除失败态并置为投屏成功
      if (state === 'connected') {
        this.setConnectionState(CastStage.CONNECTED, 'PeerConnection 已连接')
      } else if (state === 'failed' || state === 'closed') {
        this.setError(`WebRTC 连接${state === 'failed' ? '失败' : '已关闭'}`)
      } else if (state === 'disconnected') {
        // disconnected 在 WebRTC 里是可恢复状态，只降级不判死
        if (this.connectionState === CastStage.CONNECTED) {
          this.setConnectionState(CastStage.CONNECTING, 'PeerConnection 断开，等待恢复')
        }
      }
    },

    setControlChannelOpen(open) {
      if (this.controlChannelOpen === open) return
      this.controlChannelOpen = open
      console.log(`${LOG} 控制通道 ${open ? '已打开' : '已关闭'}`)
    },

    /** 生成投屏二维码 */
    generateQRCode(deviceUuid) {
      this.qrCodeData = JSON.stringify({
        deviceUuid: deviceUuid || localStorage.getItem('deviceUuid') || '',
        roomType: 'cast',
      })
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
      this.connectionState = CastStage.DISCONNECTED
      this.error = null
      this.signalingConnected = false
      this.peerState = 'new'
      this.controlChannelOpen = false
      this.lastUpdatedAt = Date.now()
      console.log(`${LOG} 已清理`)
    },
  },
})
