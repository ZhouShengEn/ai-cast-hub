import { ref, shallowRef } from 'vue'

/**
 * WebRTC 封装 Composable
 *
 * 创建 RTCPeerConnection，处理 SDP 交换、ICE 候选、
 * 远程媒体流接收和 DataChannel。
 *
 * @returns {{ connectionState, remoteStream, dataChannel, createOffer, handleOffer, handleAnswer, handleIceCandidate, createDataChannel, close }}
 */
export function useWebRTC(config = {}) {
  const defaultConfig = {
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
    ...config,
  }

  const connectionState = ref('new')
  const remoteStream = shallowRef(null)
  const dataChannel = shallowRef(null)

  let pc = null
  let _onIceCandidate = null
  let _onTrack = null
  let _onDataChannel = null

  /** 初始化 RTCPeerConnection */
  function init() {
    if (pc) return
    pc = new RTCPeerConnection(defaultConfig)

    pc.onconnectionstatechange = () => {
      connectionState.value = pc.connectionState
    }

    pc.onicecandidate = (event) => {
      if (event.candidate && _onIceCandidate) {
        _onIceCandidate(event.candidate)
      }
    }

    pc.ontrack = (event) => {
      if (event.streams && event.streams[0]) {
        remoteStream.value = event.streams[0]
      }
      if (_onTrack) _onTrack(event)
    }

    pc.ondatachannel = (event) => {
      dataChannel.value = event.channel
      if (_onDataChannel) _onDataChannel(event.channel)
    }
  }

  /** 创建 Offer + setLocalDescription */
  async function createOffer(sdpCallback) {
    init()
    const offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    if (sdpCallback) sdpCallback(pc.localDescription)
    return pc.localDescription
  }

  /** 处理远端 Offer：setRemoteDescription + createAnswer */
  async function handleOffer(sdp, sdpCallback) {
    init()
    await pc.setRemoteDescription(new RTCSessionDescription(sdp))
    const answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    if (sdpCallback) sdpCallback(pc.localDescription)
    return pc.localDescription
  }

  /** 处理远端 Answer：setRemoteDescription */
  async function handleAnswer(sdp) {
    if (!pc) return
    await pc.setRemoteDescription(new RTCSessionDescription(sdp))
  }

  /** 添加 ICE 候选 */
  async function handleIceCandidate(candidate) {
    if (!pc) return
    try {
      await pc.addIceCandidate(new RTCIceCandidate(candidate))
    } catch (err) {
      console.warn('ICE candidate add failed:', err)
    }
  }

  /** 创建 DataChannel */
  function createDataChannel(label) {
    init()
    const channel = pc.createDataChannel(label)
    dataChannel.value = channel
    return channel
  }

  /** 设置 ICE 候选回调 */
  function onIceCandidate(fn) {
    _onIceCandidate = fn
  }

  /** 设置 track 回调 */
  function onTrack(fn) {
    _onTrack = fn
  }

  /** 设置 DataChannel 回调 */
  function onDataChannel(fn) {
    _onDataChannel = fn
  }

  /** 关闭连接 */
  function close() {
    if (dataChannel.value) {
      dataChannel.value.close()
      dataChannel.value = null
    }
    if (pc) {
      pc.close()
      pc = null
    }
    remoteStream.value = null
    connectionState.value = 'closed'
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
    onIceCandidate,
    onTrack,
    onDataChannel,
    close,
  }
}
