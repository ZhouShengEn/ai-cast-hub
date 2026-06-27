import { ref, shallowRef } from 'vue'

/**
 * WebRTC 封装 Composable（单例模式）
 *
 * 全局只创建一个 RTCPeerConnection，处理 SDP 交换、ICE 候选、
 * 远程媒体流接收和 DataChannel。
 *
 * 多个 composable（如 useMessageTransfer, useCastReceiver）共享同一 pc 实例。
 */

// ---- 单例状态（模块级，所有调用共享） ----
let pc = null
let _iceServers = [{ urls: 'stun:stun.l.google.com:19302' }]
const connectionState = ref('new')
const remoteStream = shallowRef(null)
const dataChannel = shallowRef(null)

// 回调注册表（支持多个监听者）
const _iceCandidateCallbacks = new Set()
const _trackCallbacks = new Set()
const _dataChannelCallbacks = new Set()
const _connectionStateCallbacks = new Set()

/** 初始化 RTCPeerConnection（只创建一次） */
function ensurePC(config = {}) {
  if (pc) return pc

  const mergedConfig = {
    iceServers: _iceServers,
    ...config,
  }

  pc = new RTCPeerConnection(mergedConfig)
  console.log('[WebRTC] 创建 RTCPeerConnection (单例), ICE servers:', _iceServers.length)

  pc.onconnectionstatechange = () => {
    connectionState.value = pc.connectionState
    console.log('[WebRTC] 连接状态:', pc.connectionState)
    _connectionStateCallbacks.forEach((fn) => fn(pc.connectionState))
  }

  pc.oniceconnectionstatechange = () => {
    console.log('[WebRTC] ICE 状态:', pc.iceConnectionState)
  }

  pc.onicecandidate = (event) => {
    console.log('[WebRTC] ICE candidate:', event.candidate ? '已生成' : '完成')
    if (event.candidate) {
      _iceCandidateCallbacks.forEach((fn) => fn(event.candidate))
    }
  }

  pc.ontrack = (event) => {
    console.log('[WebRTC] 收到 track')
    if (event.streams && event.streams[0]) {
      remoteStream.value = event.streams[0]
    }
    _trackCallbacks.forEach((fn) => fn(event))
  }

  pc.ondatachannel = (event) => {
    console.log('[WebRTC] 收到远端 DataChannel:', event.channel.label)
    dataChannel.value = event.channel
    _dataChannelCallbacks.forEach((fn) => fn(event.channel))
  }

  return pc
}

/** 设置 H.264 视频解码偏好 */
function _setH264Preference() {
  if (!pc) return
  try {
    pc.getTransceivers().forEach((transceiver) => {
      if (transceiver.receiver?.track?.kind !== 'video') return
      const codecs = RTCRtpReceiver.getCapabilities?.('video')?.codecs || []
      if (codecs.length === 0) return
      // H.264 优先
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
        console.log('[WebRTC] H.264 解码偏好已设置')
      }
    })
  } catch (e) {
    console.warn('[WebRTC] H.264 preference set failed:', e)
  }
}

/** 重置 PC（关闭旧的，下次 ensurePC 会创建新的） */
function resetPC() {
  if (dataChannel.value) {
    try { dataChannel.value.close() } catch (_) {}
    dataChannel.value = null
  }
  if (pc) {
    try { pc.close() } catch (_) {}
    pc = null
  }
  remoteStream.value = null
  connectionState.value = 'new'
  console.log('[WebRTC] PC 已重置')
}

export function useWebRTC(config = {}) {
  /** 创建 Offer + setLocalDescription */
  async function createOffer(sdpCallback) {
    ensurePC(config)
    const offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    if (sdpCallback) sdpCallback(pc.localDescription)
    return pc.localDescription
  }

  /** 处理远端 Offer：setRemoteDescription + createAnswer */
  async function handleOffer(sdp, sdpCallback) {
    ensurePC(config)
    console.log('[WebRTC] 处理远端 Offer (SDP 长度:', sdp.length, ')')
    await pc.setRemoteDescription(new RTCSessionDescription({ type: 'offer', sdp }))
    // 设置 H.264 解码偏好（浏览器硬件解码性能更好）
    _setH264Preference()
    const answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    console.log('[WebRTC] 已创建 Answer')
    if (sdpCallback) sdpCallback({ signalType: 'answer', sdp: answer.sdp })
    return pc.localDescription
  }

  /** 处理远端 Answer：setRemoteDescription */
  async function handleAnswer(sdp) {
    if (!pc) {
      console.warn('[WebRTC] handleAnswer: pc 不存在')
      return
    }
    console.log('[WebRTC] 处理远端 Answer (SDP 长度:', sdp.length, ')')
    await pc.setRemoteDescription(new RTCSessionDescription({ type: 'answer', sdp }))
  }

  /** 添加 ICE 候选 */
  async function handleIceCandidate(candidate) {
    if (!pc) {
      console.warn('[WebRTC] handleIceCandidate: pc 不存在')
      return
    }
    try {
      await pc.addIceCandidate(new RTCIceCandidate(candidate))
    } catch (err) {
      console.warn('[WebRTC] ICE candidate add failed:', err)
    }
  }

  /** 创建 DataChannel */
  function createDataChannel(label) {
    ensurePC(config)
    const channel = pc.createDataChannel(label)
    dataChannel.value = channel
    console.log('[WebRTC] 创建 DataChannel:', label)
    return channel
  }

  /** 设置 ICE 候选回调 */
  function onIceCandidate(fn) {
    _iceCandidateCallbacks.add(fn)
  }

  /** 移除 ICE 候选回调 */
  function offIceCandidate(fn) {
    _iceCandidateCallbacks.delete(fn)
  }

  /** 设置 track 回调 */
  function onTrack(fn) {
    _trackCallbacks.add(fn)
  }

  /** 移除 track 回调 */
  function offTrack(fn) {
    _trackCallbacks.delete(fn)
  }

  /** 设置 DataChannel 回调 */
  function onDataChannel(fn) {
    _dataChannelCallbacks.add(fn)
  }

  /** 移除 DataChannel 回调 */
  function offDataChannel(fn) {
    _dataChannelCallbacks.delete(fn)
  }

  /** 更新 ICE 服务器配置（在创建 PC 之前调用） */
  function setIceServers(servers) {
    _iceServers = servers || [{ urls: 'stun:stun.l.google.com:19302' }]
    console.log('[WebRTC] ICE servers updated:', _iceServers.length)
  }

  /** 从服务器获取 ICE 配置（使用 Axios 确保认证头） */
  async function fetchIceServers() {
    try {
      const client = (await import('../api/client.js')).default
      const data = await client.get('/api/v1/webrtc/config')
      if (data?.iceServers) {
        setIceServers(data.iceServers)
        return
      }
    } catch (e) {
      console.warn('[WebRTC] 获取 ICE 配置失败，使用默认 STUN:', e)
    }
    setIceServers([{ urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] }])
  }

  /** 关闭连接（不影响其他监听者，只重置 PC） */
  function close() {
    resetPC()
  }

  return {
    connectionState,
    remoteStream,
    dataChannel,
    createOffer,
    handleOffer,
    handleAnswer,
    handleIceCandidate,
    createDataChannel,
    setIceServers,
    fetchIceServers,
    onIceCandidate,
    offIceCandidate,
    onTrack,
    offTrack,
    onDataChannel,
    offDataChannel,
    close,
  }
}
