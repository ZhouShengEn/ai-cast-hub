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
 * @param {import('vue').Ref<HTMLVideoElement|null>} [externalVideoRef] - 外部传入的 video 元素引用
 * @returns {{ startListening, stopReceiving, connectionState, setVideoRef }}
 */
export function useCastReceiver(externalVideoRef) {
  const castStore = useCastStore()
  const videoRef = externalVideoRef || ref(null)
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
    onConnectionStateChange,
    offConnectionStateChange,
    close: rtcClose,
  } = useWebRTC('cast')

  let _currentRoomId = null

  // 保存回调引用以便注销
  let _invitationHandler = null
  let _signalHandler = null
  let _roomClosedHandler = null
  let _iceCandidateCb = null
  let _trackCb = null
  let _connectionStateCb = null

  /**
   * 开始监听投屏邀请
   * PC 端页面加载后调用，等待手机端发起 create_room
   * 幂等：重复调用安全（先清理旧 handler）
   */
  function startListening() {
    // 先清理旧的 invitation handler 避免重复注册
    if (_invitationHandler) {
      offMessage('room_invitation', _invitationHandler)
      _invitationHandler = null
    }
    if (_roomClosedHandler) {
      offMessage('room_closed', _roomClosedHandler)
      _roomClosedHandler = null
    }

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
    console.log('[CastReceiver] 收到room_invitation, roomId:', roomId)
    if (!roomId) return

    // 先清理之前的连接状态（确保每次投屏使用全新的 PC，避免 SDP m-line 顺序错误）
    _cleanupCallbacks()
    rtcClose()

    _currentRoomId = roomId
    castStore.roomId = roomId
    connectionState.value = 'connecting'
    castStore.setConnectionState('connecting')

    // 加入房间
    console.log('[CastReceiver] 发送join_room, roomId:', roomId)
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

      console.log('[CastReceiver] 收到signal:', signalType, 'roomId:', signalMsg.roomId)
      try {
        if (signalType === 'offer') {
          console.log('[CastReceiver] 收到offer, SDP长度:', payload.sdp?.length)
          // 收到手机端 offer → 创建 answer 并回复
          await handleOffer(payload.sdp, (answerPayload) => {
            console.log('[CastReceiver] 发送answer, SDP长度:', answerPayload.sdp?.length)
            send({
              type: 'signal',
              roomId: _currentRoomId,
              payload: answerPayload,
            })
          })
          console.log('[CastReceiver] answer已发送')
        } else if (signalType === 'answer') {
          console.log('[CastReceiver] 收到answer, SDP长度:', payload.sdp?.length)
          await handleAnswer(payload.sdp)
        } else if (signalType === 'ice_candidate') {
          console.log('[CastReceiver] 收到ice_candidate')
          await handleIceCandidate(payload.candidate)
        }
      } catch (err) {
        console.error('[CastReceiver] 投屏信令处理失败:', err)
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
      console.log('[CastReceiver] ICE候选已生成，发送给手机端')
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
      console.log('[CastReceiver] 🔔 track回调触发')
      console.log('[CastReceiver]   remoteStream:', remoteStream.value ? `存在(stream id: ${remoteStream.value.id})` : 'null')
      console.log('[CastReceiver]   videoRef:', videoRef.value ? '存在' : 'null')
      if (remoteStream.value) {
        castStore.setRemoteStream(remoteStream.value)
        if (videoRef.value) {
          videoRef.value.srcObject = remoteStream.value
          console.log('[CastReceiver] ✅ video.srcObject已绑定远程流')
        } else {
          console.log('[CastReceiver] ⚠️ videoRef不存在，无法绑定流')
        }
        connectionState.value = 'connected'
        castStore.setConnectionState('connected')
        console.log('[CastReceiver] ✅ 投屏连接已建立')
      } else {
        console.log('[CastReceiver] ⚠️ remoteStream为空，无法绑定')
      }
    }
    onTrack(_trackCb)

    // 监听 WebRTC 连接状态变化：连接断开时自动清理
    _connectionStateCb = (state) => {
      console.log('[CastReceiver] WebRTC连接状态变化:', state)
      if (state === 'failed' || state === 'disconnected' || state === 'closed') {
        console.log('[CastReceiver] WebRTC 连接断开 (state=%s)，清理投屏状态', state)
        stopReceiving()
      }
    }
    onConnectionStateChange(_connectionStateCb)
  }

  /** 清理 WebRTC 回调注册（不清除 WS 消息监听） */
  function _cleanupCallbacks() {
    if (_iceCandidateCb) {
      offIceCandidate(_iceCandidateCb)
      _iceCandidateCb = null
    }
    if (_trackCb) {
      offTrack(_trackCb)
      _trackCb = null
    }
    if (_connectionStateCb) {
      offConnectionStateChange(_connectionStateCb)
      _connectionStateCb = null
    }
  }

  /** 停止接收当前会话（保持 invitation 监听，可接受下次投屏） */
  function stopReceiving() {
    if (_currentRoomId) {
      send({ type: 'close_room', roomId: _currentRoomId })
    }
    // 只清理当前会话的 handlers，不清理 invitation/room_closed（保持可接受新投屏）
    if (_signalHandler) {
      offMessage('signal', _signalHandler)
      _signalHandler = null
    }
    _cleanupCallbacks()
    rtcClose()
    if (videoRef.value) {
      videoRef.value.srcObject = null
    }
    castStore.cleanup()
    connectionState.value = 'disconnected'
    _currentRoomId = null
  }

  /** 允许外部更新 videoRef */
  function setVideoRef(ref) {
    videoRef.value = ref?.value || ref
    console.log('[CastReceiver] setVideoRef: videoEl=', videoRef.value ? '存在' : 'null')
    // 如果视频元素已可用且远程流已存在，立即绑定
    if (videoRef.value && remoteStream.value) {
      videoRef.value.srcObject = remoteStream.value
      console.log('[CastReceiver] ✅ setVideoRef时重新绑定了远程流')
    } else if (videoRef.value && !remoteStream.value) {
      console.log('[CastReceiver] ⚠️ videoEl已就绪，但remoteStream尚未到达')
    }
  }

  return {
    startListening,
    stopReceiving,
    setVideoRef,
    connectionState,
  }
}
