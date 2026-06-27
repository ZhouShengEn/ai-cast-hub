import { ref } from 'vue'
import { useWebSocket } from './useWebSocket'
import { useWebRTC } from './useWebRTC'
import { useCastStore } from '../stores/cast'

/**
 * 投屏接收 Composable
 *
 * 监听 room_invitation → 发送 join_room → 接收 offer/answer/ICE
 * 最终绑定 remoteStream 到 video 元素。
 *
 * @returns {{ startListening, stopReceiving, videoRef, connectionState }}
 */
export function useCastReceiver() {
  const castStore = useCastStore()
  const videoRef = ref(null)
  const connectionState = ref('disconnected')

  const { send, onMessage, offMessage } = useWebSocket()
  const {
    remoteStream,
    handleOffer,
    handleAnswer,
    handleIceCandidate,
    fetchIceServers,
    onIceCandidate,
    offIceCandidate,
    onTrack,
    offTrack,
    close: rtcClose,
  } = useWebRTC()

  let _currentRoomId = null

  // 保存回调引用以便注销
  let _invitationHandler = null
  let _signalHandler = null
  let _roomClosedHandler = null
  let _iceCandidateCb = null
  let _trackCb = null

  /**
   * 开始监听投屏邀请
   * PC 端页面加载后调用，等待手机端发起 create_room
   */
  function startListening() {
    connectionState.value = 'disconnected'
    castStore.setConnectionState('disconnected')

    // 从服务器获取 ICE 配置（STUN/TURN）
    fetchIceServers()

    // 监听房间邀请
    _invitationHandler = (msg) => {
      // 只处理 cast 类型的房间邀请，避免与消息的 message 类型冲突
      const roomType = msg.payload?.type
      if (roomType && roomType !== 'cast') return
      _handleInvitation(msg)
    }
    onMessage('room_invitation', _invitationHandler)

    // 监听房间关闭/对端断开
    _roomClosedHandler = (msg) => {
      if (_currentRoomId && msg.roomId === _currentRoomId) {
        stopReceiving()
      }
    }
    onMessage('room_closed', _roomClosedHandler)
    // 也监听对端主动断开消息
    onMessage('peer_disconnected', (msg) => {
      if (_currentRoomId && msg.roomId === _currentRoomId) {
        stopReceiving()
      }
    })
  }

  /** 处理房间邀请 */
  function _handleInvitation(msg) {
    const roomId = msg.roomId
    if (!roomId) return

    _currentRoomId = roomId
    castStore.roomId = roomId
    connectionState.value = 'connecting'
    castStore.setConnectionState('connecting')

    // 加入房间
    send({
      type: 'join_room',
      roomId,
    })

    // 设置 WebRTC 回调
    _setupWebRTCCallbacks()

    // 监听信令消息
    _signalHandler = async (signalMsg) => {
      if (!signalMsg.roomId || signalMsg.roomId !== _currentRoomId) return

      const payload = signalMsg.payload || {}
      // 服务器转发时使用 signalType 字段
      const signalType = payload.signalType || payload.type

      try {
        if (signalType === 'offer') {
          // 收到手机端 offer → 创建 answer 并回复
          await handleOffer(payload.sdp, (answerPayload) => {
            send({
              type: 'signal',
              roomId: _currentRoomId,
              payload: answerPayload,
            })
          })
        } else if (signalType === 'answer') {
          await handleAnswer(payload.sdp)
        } else if (signalType === 'ice_candidate') {
          await handleIceCandidate(payload.candidate)
        }
      } catch (err) {
        console.error('投屏信令处理失败:', err)
        connectionState.value = 'error'
        castStore.setConnectionState('error')
        castStore.error = err.message
      }
    }
    onMessage('signal', _signalHandler)
  }

  /** 设置 WebRTC 回调 */
  function _setupWebRTCCallbacks() {
    // 监听 ICE 候选并发送给手机端
    _iceCandidateCb = (candidate) => {
      send({
        type: 'signal',
        roomId: _currentRoomId,
        payload: {
          signalType: 'ice_candidate',
          candidate: candidate.toJSON(),
        },
      })
    }
    onIceCandidate(_iceCandidateCb)

    // 监听远程媒体流
    _trackCb = () => {
      if (remoteStream.value) {
        castStore.setRemoteStream(remoteStream.value)
        if (videoRef.value) {
          videoRef.value.srcObject = remoteStream.value
        }
        connectionState.value = 'connected'
        castStore.setConnectionState('connected')
      }
    }
    onTrack(_trackCb)
  }

  /** 停止接收 */
  function stopReceiving() {
    if (_currentRoomId) {
      send({ type: 'close_room', roomId: _currentRoomId })
    }
    if (_invitationHandler) {
      offMessage('room_invitation', _invitationHandler)
      _invitationHandler = null
    }
    if (_signalHandler) {
      offMessage('signal', _signalHandler)
      _signalHandler = null
    }
    if (_roomClosedHandler) {
      offMessage('room_closed', _roomClosedHandler)
      _roomClosedHandler = null
    }
    if (_iceCandidateCb) {
      offIceCandidate(_iceCandidateCb)
      _iceCandidateCb = null
    }
    if (_trackCb) {
      offTrack(_trackCb)
      _trackCb = null
    }
    rtcClose()
    if (videoRef.value) {
      videoRef.value.srcObject = null
    }
    castStore.cleanup()
    connectionState.value = 'disconnected'
    _currentRoomId = null
  }

  return {
    startListening,
    stopReceiving,
    videoRef,
    connectionState,
  }
}
