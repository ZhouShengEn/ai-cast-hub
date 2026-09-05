import { ref, computed } from 'vue'
import { useWebSocket } from './useWebSocket'
import { useWebRTC } from './useWebRTC'
import { useCastStore } from '../stores/cast'
import { usePcmPlayer } from './usePcmPlayer'
import { QUALITY_PROFILES, QUALITY_ORDER, DEFAULT_QUALITY } from './castQuality'

/**
 * 投屏接收 Composable
 *
 * 监听 room_invitation → 发送 join_room → 接收 offer/answer/ICE
 * 最终绑定 remoteStream 到 video 元素。
 * 同时创建 DataChannel 用于远程控制指令传输。
 *
 * @param {import('vue').Ref<HTMLVideoElement|null>} [externalVideoRef] - 外部传入的 video 元素引用
 * @param {object} [options] - { showToast } 用于弱网自动降级的提示
 * @returns {{ startListening, stopReceiving, connectionState, setVideoRef, sendControl }}
 */
export function useCastReceiver(externalVideoRef, options = {}) {
  const castStore = useCastStore()
  const videoRef = externalVideoRef || ref(null)

  /**
   * 连接状态的唯一来源是 Pinia store。
   * 这里只做只读映射，禁止再写 connectionState.value，
   * 否则就会出现「store 已恢复、组件还停在失败态」的不一致。
   */
  const connectionState = computed(() => castStore.connectionState)

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
    onDataChannel,
    offDataChannel,
    onConnectionStateChange,
    offConnectionStateChange,
    close: rtcClose,
  } = useWebRTC('cast')

  let _controlChannel = null

  /** 手机端上报的远程控制状态，形如 { accessibilityEnabled, platform } */
  const remoteStatus = ref(null)

  // ---- 系统内录音频 ----
  const {
    isPlaying: isAudioPlaying,
    configure: configureAudio,
    enqueue: enqueuePcm,
    unlock: unlockAudio,
    setMuted: setAudioMuted,
    stop: stopAudio,
  } = usePcmPlayer()

  /** 手机端是否支持系统内录（Android 10+） */
  const systemAudioSupported = ref(false)
  /** 系统内录是否已开启 */
  const systemAudioActive = ref(false)
  /** 音频 DataChannel 是否就绪 */
  const audioChannelReady = ref(false)

  let _audioChannel = null

  // ---- 投屏画质 ----
  /** 当前生效画质档位（持久化到 localStorage，新会话自动恢复） */
  const currentQuality = ref(
    (() => {
      try {
        return localStorage.getItem('castQuality') || DEFAULT_QUALITY
      } catch (_) {
        return DEFAULT_QUALITY
      }
    })(),
  )
  /** 弱网自动降级计数器：短时间内多次 disconnected 触发降一档 */
  let _disconnectCount = 0

  let _currentRoomId = null

  // 保存回调引用以便注销
  let _invitationHandler = null
  let _signalHandler = null
  let _roomClosedHandler = null
  let _iceCandidateCb = null
  let _trackCb = null
  let _dataChannelCb = null
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

    // 重置全部状态（含历史错误标记），保证每次进入页面都是干净的起点
    castStore.resetForReconnect()

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

    // 防止重复处理同一个房间（服务器可能因重连等原因重复发送邀请）
    if (_currentRoomId === roomId && connectionState.value !== 'disconnected') {
      console.log('[CastReceiver] 已在处理同一房间，跳过重复邀请')
      return
    }

    // 先清理旧的信令处理器（避免累积重复handler导致同一条offer被处理两次）
    if (_signalHandler) {
      offMessage('signal', _signalHandler)
      _signalHandler = null
    }

    // 先清理之前的连接状态（确保每次投屏使用全新的 PC，避免 SDP m-line 顺序错误）
    _cleanupCallbacks()
    rtcClose()

    _currentRoomId = roomId
    castStore.setRoomId(roomId)
    castStore.setConnectionState('pairing', `收到房间邀请 ${roomId}`)

    // 加入房间
    console.log('[CastReceiver] 发送join_room, roomId:', roomId)
    send({
      type: 'join_room',
      roomId,
    })

    // 房间已建立 = 信令链路就绪
    castStore.setSignalingConnected(true)
    castStore.setConnectionState('signaling', '已加入房间，等待手机端 offer')

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
          castStore.setConnectionState('connecting', '收到 offer，开始 ICE 协商')
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
          // ICE 候选失败不影响已有连接（视频可能已经在播放）
          try {
            await handleIceCandidate(payload.candidate)
          } catch (iceErr) {
            console.warn('[CastReceiver] ICE候选添加失败（非致命）:', iceErr.message)
          }
        }
      } catch (err) {
        // offer/answer 处理失败才是致命错误
        console.error('[CastReceiver] 投屏信令处理失败:', err)
        castStore.setError(err.message || '投屏信令处理失败')
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

    // 手机端是 offer 发起方，必须由手机端在 createOffer() 前创建通道，
    // 才会在 SDP 中包含 m=application；Web 应答端仅接收该通道。
    _dataChannelCb = (channel) => {
      if (channel.label === 'control') {
        _bindControlChannel(channel)
      } else if (channel.label === 'audio') {
        _bindAudioChannel(channel)
      }
    }
    onDataChannel(_dataChannelCb)

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
        castStore.setConnectionState('connected', '已收到媒体轨道')
        console.log('[CastReceiver] ✅ 投屏连接已建立')
      } else {
        console.log('[CastReceiver] ⚠️ remoteStream为空，无法绑定')
      }
    }
    onTrack(_trackCb)

    // 监听 WebRTC 连接状态变化：仅在连接彻底失败或关闭时自动清理
    // 注意: 'disconnected' 在 WebRTC 中是可恢复状态（ICE consent 短暂失败），不应销毁连接
    // 统一交给 store 判定：store 会在 connected 时自动清除失败态，
    // 这里不再单独维护一份判断逻辑，避免两处状态打架
    _connectionStateCb = (state) => {
      console.log('[CastReceiver] WebRTC连接状态变化:', state)
      castStore.setPeerState(state)
      if (state === 'connected') {
        // 重连恢复：重新查询手机端状态，避免音频开关 / 无障碍提示卡在旧态
        sendControl({ type: 'query_status' })
        _disconnectCount = 0
      } else if (state === 'disconnected') {
        // 弱网自动降级：短时间内多次抖动 → 自动降一档画质以保流畅
        _disconnectCount++
        if (_disconnectCount >= 2) {
          const idx = QUALITY_ORDER.indexOf(currentQuality.value)
          if (idx >= 0 && idx < QUALITY_ORDER.length - 1) {
            const lower = QUALITY_ORDER[idx + 1]
            setQuality(lower)
            options.showToast?.(
              '检测到网络抖动，已自动降低画质以保流畅',
              'warn',
            )
          }
          _disconnectCount = 0
        }
      } else if (state === 'failed' || state === 'closed') {
        console.log('[CastReceiver] WebRTC 连接不可恢复 (state=%s)，清理投屏状态', state)
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
    if (_dataChannelCb) {
      offDataChannel(_dataChannelCb)
      _dataChannelCb = null
    }
    if (_connectionStateCb) {
      offConnectionStateChange(_connectionStateCb)
      _connectionStateCb = null
    }
    _controlChannel = null
    _audioChannel = null
    remoteStatus.value = null
    systemAudioSupported.value = false
    systemAudioActive.value = false
    audioChannelReady.value = false
    stopAudio()
  }

  function _bindControlChannel(channel) {
    _controlChannel = channel
    channel.onopen = () => {
      console.log('[CastReceiver] ✅ 远程控制 DataChannel 已打开')
      castStore.setControlChannelOpen(true)
      // 通道就绪后立即查询一次无障碍服务状态，用于 Web 端提示用户
      sendControl({ type: 'query_status' })
      // 用户已选定非默认画质时，连接建立即下发（重连/新会话都会走到这里，
      // 保证上次的选择在新会话生效，无需手动再切一次）
      if (currentQuality.value !== DEFAULT_QUALITY) {
        setQuality(currentQuality.value)
      }
    }
    channel.onclose = () => {
      console.log('[CastReceiver] 🔌 远程控制 DataChannel 已关闭')
      castStore.setControlChannelOpen(false)
      if (_controlChannel === channel) _controlChannel = null
      remoteStatus.value = null
    }
    channel.onerror = (err) => {
      console.error('[CastReceiver] ❌ 远程控制 DataChannel 错误:', err)
    }
    channel.onmessage = (event) => {
      // 控制通道只走 JSON 文本；二进制音频帧走独立的 audio 通道，不会进这里
      if (typeof event.data !== 'string') return
      try {
        const msg = JSON.parse(event.data)
        if (msg.type === 'status') {
          remoteStatus.value = msg.payload || null
          systemAudioSupported.value = msg.payload?.systemAudioSupported === true
          systemAudioActive.value = msg.payload?.systemAudioActive === true
          if (msg.payload?.audioFormat) {
            configureAudio(msg.payload.audioFormat)
          }
          console.log('[CastReceiver] 收到手机端状态上报:', msg.payload)
        } else if (msg.type === 'system_audio_state') {
          systemAudioActive.value = msg.payload?.enabled === true
          if (msg.payload?.error) {
            console.warn('[CastReceiver] 系统内录异常:', msg.payload.error)
          }
          console.log('[CastReceiver] 系统内录状态:', msg.payload)
        } else if (msg.type === 'quality_state') {
          if (msg.payload?.profile) {
            currentQuality.value = msg.payload.profile
          }
          console.log('[CastReceiver] 画质已生效:', msg.payload)
        }
      } catch (err) {
        console.warn('[CastReceiver] 控制通道收到无法解析的消息:', err)
      }
    }
  }

  /** 绑定音频旁路通道（接收手机端系统内录的 PCM 二进制帧） */
  function _bindAudioChannel(channel) {
    _audioChannel = channel
    // 音频帧是二进制，必须显式声明 arraybuffer，否则收到的是 Blob
    channel.binaryType = 'arraybuffer'
    channel.onopen = () => {
      audioChannelReady.value = true
      console.log('[CastReceiver] ✅ 音频 DataChannel 已打开')
    }
    channel.onclose = () => {
      audioChannelReady.value = false
      if (_audioChannel === channel) _audioChannel = null
      stopAudio()
      console.log('[CastReceiver] 🔌 音频 DataChannel 已关闭')
    }
    channel.onerror = (err) => {
      console.error('[CastReceiver] ❌ 音频 DataChannel 错误:', err)
    }
    channel.onmessage = (event) => {
      // 音频通道只走二进制；文本帧（若有）直接忽略
      if (event.data instanceof ArrayBuffer) {
        enqueuePcm(event.data)
      } else if (event.data && typeof event.data.byteLength === 'number') {
        enqueuePcm(event.data)
      }
    }
  }

  /**
   * 系统音频「播放/静音」开关。
   *
   * 注意：投屏建立后系统音频采集已由 Flutter 端自动开启（用户只需在手机上确认一次授权弹窗），
   * 因此 Web 端不再触发权限申请，只负责本地 PCM 播放的启用/禁用（静音）。
   * 必须在用户手势（点击）中调用，否则 AudioContext 无法 resume。
   */
  const systemAudioMuted = ref(false)
  async function toggleSystemAudioPlayback() {
    // 先在当前用户手势里 resume AudioContext，兼容浏览器自动播放策略
    const unlocked = await unlockAudio()
    if (!unlocked) {
      console.warn('[CastReceiver] AudioContext 未能启动，系统音频可能无声')
    }
    systemAudioMuted.value = !systemAudioMuted.value
    setAudioMuted(systemAudioMuted.value)
    return systemAudioMuted.value
  }

  /**
   * 应用画质档位：更新本地状态 + 持久化 + 下发到手机端。
   * 手机端经 RTCRtpSender.setParameters 实时生效，不打断投屏。
   * @returns {boolean} 控制通道是否成功发出
   */
  function setQuality(profile) {
    const p = QUALITY_PROFILES[profile]
    if (!p) return false
    currentQuality.value = profile
    try {
      localStorage.setItem('castQuality', profile)
    } catch (_) {
      // localStorage 不可用时忽略，仅内存态生效
    }
    const ok = sendControl({
      type: 'set_quality',
      payload: {
        profile,
        width: p.width,
        height: p.height,
        fps: p.fps,
        bitrate: p.bitrate,
      },
    })
    if (!ok) {
      console.warn('[CastReceiver] 控制通道未就绪，画质将在连接恢复后下发')
    }
    return ok
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

  /** 发送远程控制指令 */
  function sendControl(command) {
    if (!_controlChannel || _controlChannel.readyState !== 'open') {
      console.warn('[CastReceiver] ⚠️ DataChannel 未就绪，无法发送控制指令')
      return false
    }
    try {
      const cmd = {
        id: 'ctrl_' + Date.now(),
        timestamp: Date.now(),
        ...command,
      }
      _controlChannel.send(JSON.stringify(cmd))
      console.log('[CastReceiver] 📡 发送控制指令:', command)
      return true
    } catch (err) {
      console.error('[CastReceiver] ❌ 发送控制指令失败:', err)
      return false
    }
  }

  return {
    startListening,
    stopReceiving,
    setVideoRef,
    connectionState,
    sendControl,
    remoteStatus,
    /** 重新查询手机端远程控制状态（用户在手机上开启无障碍后点「重新检测」） */
    refreshRemoteStatus() {
      return sendControl({ type: 'query_status' })
    },
    // 系统内录音频
    systemAudioSupported,
    systemAudioActive,
    systemAudioMuted,
    audioChannelReady,
    isAudioPlaying,
    unlockAudio,
    toggleSystemAudioPlayback,
    // 投屏画质
    currentQuality,
    qualityProfiles: QUALITY_PROFILES,
    qualityOrder: QUALITY_ORDER,
    setQuality,
  }
}
