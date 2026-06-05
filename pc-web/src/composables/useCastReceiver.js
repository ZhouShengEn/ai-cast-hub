import { ref } from 'vue'
import { useWebSocket } from './useWebSocket'
import { useWebRTC } from './useWebRTC'
import { useCastStore } from '../stores/cast'

/**
 * 投屏接收 Composable
 *
 * 组合 WebSocket 信令 + WebRTC，处理投屏房间的
 * offer/answer/ice 交换，最终绑定 remoteStream 到 video 元素。
 *
 * @returns {{ startReceiving, stopReceiving, videoRef, connectionState }}
 */
export function useCastReceiver() {
  const castStore = useCastStore()
  const videoRef = ref(null)
  const connectionState = ref('disconnected')

  const { send, onMessage, offMessage, connectionState: wsState, connect: wsConnect } = useWebSocket()
  const {
    connectionState: rtcState,
    remoteStream,
    createOffer,
    handleOffer,
    handleAnswer,
    handleIceCandidate,
    onIceCandidate,
    onTrack,
    close: rtcClose,
  } = useWebRTC()

  let _currentRoomId = null

  /** 开始接收投屏 */
  function startReceiving(roomId) {
    _currentRoomId = roomId
    connectionState.value = 'connecting'
    castStore.setConnectionState('connecting')

    // 确保 WebSocket 已连接
    wsConnect()

    // 监听 ICE 候选并发送
    onIceCandidate((candidate) => {
      send({
        type: 'signal',
        roomId: _currentRoomId,
        payload: {
          type: 'ice',
          candidate: candidate.toJSON(),
        },
      })
    })

    // 监听远程流
    onTrack(() => {
      if (remoteStream.value) {
        castStore.setRemoteStream(remoteStream.value)
        if (videoRef.value) {
          videoRef.value.srcObject = remoteStream.value
        }
        connectionState.value = 'connected'
        castStore.setConnectionState('connected')
      }
    })

    // 监听 WebSocket 信令消息
    onMessage('signal', async (msg) => {
      if (!msg.roomId || msg.roomId !== _currentRoomId) return

      const payload = msg.payload || {}
      try {
        if (payload.type === 'offer') {
          // 收到手机端 offer
          const answer = await handleOffer(payload.sdp, (localSdp) => {
            send({
              type: 'signal',
              roomId: _currentRoomId,
              payload: { type: 'answer', sdp: localSdp },
            })
          })
        } else if (payload.type === 'answer') {
          await handleAnswer(payload.sdp)
        } else if (payload.type === 'ice') {
          await handleIceCandidate(payload.candidate)
        }
      } catch (err) {
        console.error('投屏信令处理失败:', err)
        connectionState.value = 'error'
        castStore.setConnectionState('error')
        castStore.error = err.message
      }
    })
  }

  /** 停止接收 */
  function stopReceiving() {
    rtcClose()
    if (videoRef.value) {
      videoRef.value.srcObject = null
    }
    castStore.cleanup()
    connectionState.value = 'disconnected'
    _currentRoomId = null
  }

  return {
    startReceiving,
    stopReceiving,
    videoRef,
    connectionState,
  }
}
