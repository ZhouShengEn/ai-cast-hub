import { ref, shallowRef } from 'vue'

/**
 * WebRTC 封装 Composable（多实例模式）
 *
 * 每个 namespace（如 'cast', 'message'）拥有独立的 RTCPeerConnection，
 * 避免投屏和消息传输因共享 PC 而互相干扰。
 *
 * @param {string} namespace - 实例标识（默认 'default'）
 * @param {object} [config] - RTCPeerConnection 初始配置
 */
export function useWebRTC(namespace = 'default', config = {}) {
  if (!_instances.has(namespace)) {
    _instances.set(namespace, _createInstance(namespace, config))
  }
  return _instances.get(namespace).api
}

// ---- 模块级实例存储 ----
const _instances = new Map()
const DEFAULT_STUN = [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] }]

function _createInstance(ns, config) {
  const state = {
    pc: null,
    iceServers: [...DEFAULT_STUN],
    connectionState: ref('new'),
    remoteStream: shallowRef(null),
    dataChannel: shallowRef(null),
    iceCandidateCallbacks: new Set(),
    trackCallbacks: new Set(),
    dataChannelCallbacks: new Set(),
    connectionStateCallbacks: new Set(),
  }

  const log = (...args) => console.log(`[WebRTC:${ns}]`, ...args)
  const warn = (...args) => console.warn(`[WebRTC:${ns}]`, ...args)

  /** 初始化 RTCPeerConnection */
  function ensurePC() {
    if (state.pc) return state.pc

    const mergedConfig = {
      iceServers: state.iceServers,
      ...config,
    }
    state.pc = new RTCPeerConnection(mergedConfig)
    log('创建 RTCPeerConnection, ICE servers:', state.iceServers.length)

    state.pc.onconnectionstatechange = () => {
      state.connectionState.value = state.pc.connectionState
      log('连接状态:', state.pc.connectionState)
      state.connectionStateCallbacks.forEach((fn) => fn(state.pc.connectionState))
    }

    state.pc.oniceconnectionstatechange = () => {
      log('ICE 状态:', state.pc.iceConnectionState)
    }

    state.pc.onicecandidate = (event) => {
      log('ICE candidate:', event.candidate ? '已生成' : '完成')
      if (event.candidate) {
        state.iceCandidateCallbacks.forEach((fn) => fn(event.candidate))
      }
    }

    state.pc.ontrack = (event) => {
      log('收到 track')
      if (event.streams && event.streams[0]) {
        state.remoteStream.value = event.streams[0]
      }
      state.trackCallbacks.forEach((fn) => fn(event))
    }

    state.pc.ondatachannel = (event) => {
      log('收到远端 DataChannel:', event.channel.label)
      state.dataChannel.value = event.channel
      state.dataChannelCallbacks.forEach((fn) => fn(event.channel))
    }

    return state.pc
  }

  /** 设置 H.264 视频解码偏好 */
  function setH264Preference() {
    if (!state.pc) return
    try {
      const transceivers = state.pc.getTransceivers()
      if (!transceivers || transceivers.length === 0) {
        log('暂无 transceiver，跳过 H.264 偏好设置')
        return
      }
      transceivers.forEach((transceiver) => {
        if (transceiver.receiver?.track?.kind !== 'video') return
        const codecs = RTCRtpReceiver.getCapabilities?.('video')?.codecs || []
        if (codecs.length === 0) return
        const preferred = [
          ...codecs.filter(c =>
            c.mimeType.toLowerCase().includes('h264') || c.mimeType.toLowerCase().includes('h.264')
          ),
          ...codecs.filter(c =>
            !c.mimeType.toLowerCase().includes('h264') && !c.mimeType.toLowerCase().includes('h.264')
          ),
        ]
        if (preferred.length > 0) {
          transceiver.setCodecPreferences(preferred)
          log('H.264 解码偏好已设置')
        }
      })
    } catch (e) {
      warn('H.264 preference set failed:', e)
    }
  }

  /** 重置 PC */
  function resetPC() {
    if (state.dataChannel.value) {
      try { state.dataChannel.value.close() } catch (_) {}
      state.dataChannel.value = null
    }
    if (state.pc) {
      try { state.pc.close() } catch (_) {}
      state.pc = null
    }
    state.remoteStream.value = null
    state.connectionState.value = 'new'
    log('PC 已重置')
  }

  // ---- 公开的 API（闭包捕获 state） ----
  const api = {
    connectionState: state.connectionState,
    remoteStream: state.remoteStream,
    dataChannel: state.dataChannel,

    async createOffer(sdpCallback) {
      ensurePC()
      const offer = await state.pc.createOffer()
      await state.pc.setLocalDescription(offer)
      if (sdpCallback) sdpCallback(state.pc.localDescription)
      return state.pc.localDescription
    },

    async handleOffer(sdp, sdpCallback) {
      ensurePC()
      log('处理远端 Offer (SDP 长度:', sdp.length, ')')
      await state.pc.setRemoteDescription(new RTCSessionDescription({ type: 'offer', sdp }))
      setH264Preference()
      const answer = await state.pc.createAnswer()
      await state.pc.setLocalDescription(answer)
      log('已创建 Answer')
      if (sdpCallback) sdpCallback({ signalType: 'answer', sdp: answer.sdp })
      return state.pc.localDescription
    },

    async handleAnswer(sdp) {
      if (!state.pc) {
        warn('handleAnswer: pc 不存在')
        return
      }
      log('处理远端 Answer (SDP 长度:', sdp.length, ')')
      await state.pc.setRemoteDescription(new RTCSessionDescription({ type: 'answer', sdp }))
    },

    async handleIceCandidate(candidate) {
      if (!state.pc) {
        warn('handleIceCandidate: pc 不存在')
        return
      }
      try {
        await state.pc.addIceCandidate(new RTCIceCandidate(candidate))
      } catch (err) {
        warn('ICE candidate add failed:', err)
      }
    },

    createDataChannel(label) {
      ensurePC()
      const channel = state.pc.createDataChannel(label)
      state.dataChannel.value = channel
      log('创建 DataChannel:', label)
      return channel
    },

    onIceCandidate(fn) { state.iceCandidateCallbacks.add(fn) },
    offIceCandidate(fn) { state.iceCandidateCallbacks.delete(fn) },
    onTrack(fn) { state.trackCallbacks.add(fn) },
    offTrack(fn) { state.trackCallbacks.delete(fn) },
    onDataChannel(fn) { state.dataChannelCallbacks.add(fn) },
    offDataChannel(fn) { state.dataChannelCallbacks.delete(fn) },
    onConnectionStateChange(fn) { state.connectionStateCallbacks.add(fn) },
    offConnectionStateChange(fn) { state.connectionStateCallbacks.delete(fn) },

    setIceServers(servers) {
      state.iceServers = servers || [...DEFAULT_STUN]
      log('ICE servers updated:', state.iceServers.length)
    },

    async fetchIceServers() {
      try {
        const client = (await import('../api/client.js')).default
        const data = await client.get('/api/v1/webrtc/config')
        if (data?.iceServers) {
          state.iceServers = data.iceServers
          log('fetched ICE servers:', data.iceServers.length)
          return
        }
      } catch (e) {
        warn('获取 ICE 配置失败，使用默认 STUN:', e)
      }
      state.iceServers = [...DEFAULT_STUN]
    },

    close() {
      resetPC()
    },
  }

  return { api }
}
