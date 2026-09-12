import { ref, shallowRef } from 'vue'
import { useWebSocket } from './useWebSocket'
import { useWebRTC } from './useWebRTC'
import { useMessageStore } from '../stores/message'

/**
 * 消息传输 Composable（单例）
 * 
 * 通过 WebRTC DataChannel 实现 P2P 文本+文件传输
 * PC 端作为接收方，监听 room_invitation 自动建立连接
 */

// ---- 模块级单例状态（避免多个组件实例创建多份） ----
let _instance = null

export function useMessageTransfer() {
  // 如果已创建过实例，直接返回（保证全局只有一个监听者）
  if (_instance) return _instance

  const store = useMessageStore()
  const { send, onMessage, offMessage } = useWebSocket()
  const {
    handleOffer, handleAnswer, handleIceCandidate,
    onIceCandidate, offIceCandidate, onDataChannel, offDataChannel, close: rtcClose,
    createOffer, createDataChannel, dataChannel,
  } = useWebRTC('message')

  let _currentRoomId = null
  let _currentRoomType = null
  let _dataChannel = null
  let _fileBuffers = {}
  let _fileMetas = {}
  let _connectionTimeout = null

  // 断点续传：待发送文件缓存（中断后保留）
  const _pendingSends = {}  // { [fileId]: { id, fileName, fileSize, fileMimeType, totalChunks, fullData: Uint8Array } }
  const _fileTransferTimers = {}  // { [fileId]: setTimeout }
  const TRANSFER_TIMEOUT_MS = 30 * 60 * 1000  // 30 分钟
  const RESUME_STATE_TIMEOUT_MS = 10000  // 10 秒等待 resume_state
  /** 暂存早到的 chunk（file_start 尚未到达时） */
  let _pendingChunks = {}

  // ---- 文件分片参数（必须与 Flutter 端完全一致，否则分片会错位）----
  /**
   * 分片大小 64KB。
   *
   * 原来是 16KB 且每片强制 sleep(5ms) —— 16KB/5ms 把吞吐硬锁在 ~3.2MB/s。
   * 这里保留旧的「二进制包 + file_start/file_end」协议（无 base64 开销），
   * 只把分片放大到 64KB 并去掉固定 sleep，速度可提升一个数量级。
   */
  const CHUNK_SIZE = 64 * 1024
  /** 发送缓冲水位上限（2MB）：只有超过才等待，不再每片固定休眠 */
  const CHUNK_BACKLOG_LIMIT = 2 * 1024 * 1024
  /** 速率采样间隔：太频繁会淹没 UI 更新 */
  const SPEED_SAMPLE_MS = 300
  /**
   * 已接收分片计数：{ [fileId]: number }
   * 避免在 _handleFileChunkData 里对缓冲区做 filter(Boolean) 造成 O(n²)。
   */
  const _fileReceivedCount = {}
  /** 接收速率采样：{ [fileId]: { at, bytes } } */
  const _fileSpeedSample = {}
  /** 已接收字节数：{ [fileId]: number } */
  const _fileReceivedBytes = {}
  /** 速率滑动窗口：{ [fileId]: [{ t, bytes }] }（保留最近 1 秒） */
  const _fileRateWindow = {}

  // 回调引用
  let _invitationHandler = null
  let _signalHandler = null
  let _roomClosedHandler = null
  let _iceCandidateCb = null
  let _dataChannelCb = null
  let _peerJoinedHandler = null

  /** 开始监听消息房间邀请（幂等：重复调用安全） */
  function startListening() {
    console.log('[Message] 启动全局消息通道监听')

    // 先清理旧的 handler 避免重复注册
    if (_invitationHandler) {
      offMessage('room_invitation', _invitationHandler)
      _invitationHandler = null
    }
    if (_roomClosedHandler) {
      offMessage('room_closed', _roomClosedHandler)
      _roomClosedHandler = null
    }

    // 注册标记已读回调：进入消息页面时通过 DC 通知 App
    store.onMarkAllRead(() => {
      if (_dataChannel && _dataChannel.readyState === 'open') {
        console.log('[Message] 发送 read_all 给 App')
        _dataChannel.send(JSON.stringify({ type: 'read_all', timestamp: Date.now() }))
      }
    })

    _invitationHandler = (msg) => {
      console.log('[Message] 收到 room_invitation:', JSON.stringify(msg.payload))
      // 只处理消息类型的房间邀请，避免与投屏的 cast 类型冲突
      if (msg.payload?.type !== 'message') {
        console.log('[Message] 跳过非 message 类型:', msg.payload?.type)
        return
      }
      _currentRoomType = 'message'
      _handleInvitation(msg)
    }
    onMessage('room_invitation', _invitationHandler)

    _roomClosedHandler = (msg) => {
      console.log('[Message] 收到 room_closed:', msg.roomId)
      // 只处理消息类型房间的关闭，避免误关闭投屏连接
      if (_currentRoomId && _currentRoomType === 'message' && msg.roomId === _currentRoomId) {
        console.log('[Message] 房间关闭，断开消息通道')
        disconnect()
      } else if (_currentRoomId && _currentRoomType !== 'message') {
        console.log('[Message] 跳过非 message 类型房间的关闭:', _currentRoomType)
      }
    }
    onMessage('room_closed', _roomClosedHandler)
  }

  /** PC端主动创建消息房间并邀请App端 */
  async function createRoom(targetDeviceUuid) {
    console.log('[Message] PC端主动创建房间，目标设备:', targetDeviceUuid)

    if (!targetDeviceUuid) {
      console.warn('[Message] 缺少目标设备 UUID')
      throw new Error('缺少目标设备 UUID')
    }

    if (_currentRoomId) {
      console.warn('[Message] 已有活跃房间，先断开')
      disconnect()
    }

    store.isConnecting = true

    // 注册 ICE 候选回调
    _iceCandidateCb = (candidate) => {
      console.log('[Message] 生成 ICE candidate，转发给 App')
      send({ type: 'signal', roomId: _currentRoomId, payload: {
        signalType: 'ice_candidate',
        candidate: candidate.toJSON(),
      }})
    }
    onIceCandidate(_iceCandidateCb)

    // 创建 DataChannel（PC 作为主动方创建）
    // 注意 createDataChannel 已改为 async（内部 await ensurePC 等待 ICE 配置），
    // 故用 .then 接收返回的通道实例。
    createDataChannel('message').then((ch) => {
      _dataChannel = ch
      if (ch) _setupDataChannel(ch)
    })

    // 监听信令
    _signalHandler = async (signalMsg) => {
      if (!signalMsg.roomId || signalMsg.roomId !== _currentRoomId) {
        return
      }
      const payload = signalMsg.payload || {}
      const st = payload.signalType || payload.type
      console.log('[Message] 收到信令:', st)
      try {
        if (st === 'offer') {
          console.log('[Message] 处理 offer，创建 answer...')
          await handleOffer(payload.sdp, (answerPayload) => {
            console.log('[Message] 发送 answer 给 App')
            send({ type: 'signal', roomId: _currentRoomId, payload: answerPayload })
          })
          console.log('[Message] answer 已发送')
        } else if (st === 'answer') {
          await handleAnswer(payload.sdp)
        } else if (st === 'ice_candidate') {
          await handleIceCandidate(payload.candidate)
        }
      } catch (err) {
        console.error('[Message] signal error:', err)
      }
    }
    onMessage('signal', _signalHandler)

    // 创建房间
    const roomCreatedCompleter = new Promise((resolve, reject) => {
      // 同样必须超时：信令服务不可达时这里会永久挂起，
      // 导致 isConnecting 卡死、连接按钮消失。
      const timer = setTimeout(() => {
        offMessage('room_created', handler)
        offMessage('error', handler)
        reject(new Error('创建房间超时（15 秒），信令服务未响应'))
      }, 15000)
      const handler = (msg) => {
        if (msg.type === 'room_created') {
          clearTimeout(timer)
          offMessage('room_created', handler)
          offMessage('error', handler)
          resolve(msg.roomId)
        } else if (msg.type === 'error') {
          clearTimeout(timer)
          offMessage('room_created', handler)
          offMessage('error', handler)
          reject(new Error(msg.payload?.message || '创建房间失败'))
        }
      }
      onMessage('room_created', handler)
      onMessage('error', handler)

      send({
        type: 'create_room',
        payload: { targetDeviceUuid, type: 'message' },
      })
    })

    try {
      _currentRoomId = await roomCreatedCompleter
      store.roomId = _currentRoomId
      console.log('[Message] 房间创建成功:', _currentRoomId)
    } catch (e) {
      console.error('[Message] 创建房间失败:', e)
      store.isConnecting = false
      throw e
    }

    // 等待 App 加入房间
    //
    // 关键：必须有超时。此前这个 Promise 会永久挂起，只要 App 端没响应，
    // store.isConnecting 就永远卡在 true —— 连接按钮被 v-if 直接隐藏，
    // 用户看到的现象就是「点了完全没反应」，且再也无法重试。
    const peerJoinedCompleter = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        offMessage('peer_joined', handler)
        offMessage('room_closed', handler)
        reject(new Error('等待 App 端加入房间超时（30 秒）'))
      }, 30000)
      const handler = (msg) => {
        if (msg.type === 'peer_joined' && msg.roomId === _currentRoomId) {
          clearTimeout(timer)
          offMessage('peer_joined', handler)
          offMessage('room_closed', handler)
          console.log('[Message] App 已加入房间')
          resolve()
        } else if (msg.type === 'room_closed' && msg.roomId === _currentRoomId) {
          clearTimeout(timer)
          offMessage('peer_joined', handler)
          offMessage('room_closed', handler)
          reject(new Error('房间已关闭'))
        }
      }
      onMessage('peer_joined', handler)
      onMessage('room_closed', handler)
    })

    try {
      await peerJoinedCompleter
    } catch (e) {
      console.error('[Message] App 未加入房间:', e)
      store.isConnecting = false
      throw e
    }

    // 创建并发送 Offer
    console.log('[Message] 创建并发送 Offer...')
    await createOffer((offer) => {
      console.log('[Message] 发送 Offer 给 App')
      send({ type: 'signal', roomId: _currentRoomId, payload: {
        signalType: 'offer',
        sdp: offer.sdp,
      }})
    })

    // 设置连接超时（30 秒后若 DC 仍未打开则标记失败）
    _clearConnectionTimeout()
    _connectionTimeout = setTimeout(() => {
      if (store.isConnecting && !store.isConnected) {
        console.error('[Message] 连接超时（30 秒），App 端未响应')
        store.isConnecting = false
        store.error = '连接超时，请确认 App 端已打开消息页面后重试'
        disconnect()
      }
    }, 30000)

    console.log('[Message] PC端主动连接流程已启动')
  }

  async function _handleInvitation(msg) {
    const roomId = msg.roomId
    if (!roomId) {
      console.warn('[Message] room_invitation 缺少 roomId')
      return
    }

    // 防止重复处理同一个房间
    if (_currentRoomId === roomId && store.isConnecting) {
      console.log('[Message] 已在处理同一房间，跳过重复邀请')
      return
    }

    console.log('[Message] 处理房间邀请 roomId=', roomId)
    _currentRoomId = roomId
    store.roomId = roomId
    store.isConnecting = true

    // 先清理旧的 signal handler，避免累积重复处理
    if (_signalHandler) {
      offMessage('signal', _signalHandler)
      _signalHandler = null
    }

    // 加入房间
    console.log('[Message] 发送 join_room')
    send({ type: 'join_room', roomId })

    // WebRTC 回调
    _iceCandidateCb = (candidate) => {
      console.log('[Message] 生成 ICE candidate，转发给 App')
      send({ type: 'signal', roomId: _currentRoomId, payload: {
        signalType: 'ice_candidate',
        candidate: candidate.toJSON(),
      }})
    }
    onIceCandidate(_iceCandidateCb)

    // 监听远端 DataChannel（消息通道）
    _dataChannelCb = (channel) => {
      console.log('[Message] 收到远端 DataChannel:', channel.label, 'readyState=', channel.readyState)
      _dataChannel = channel
      _setupDataChannel(channel)
      store.setConnected(true)
      console.log('[Message] ✅ 消息通道已建立')
    }
    onDataChannel(_dataChannelCb)

    // 监听信令
    _signalHandler = async (signalMsg) => {
      if (!signalMsg.roomId || signalMsg.roomId !== _currentRoomId) {
        return
      }
      const payload = signalMsg.payload || {}
      const st = payload.signalType || payload.type
      console.log('[Message] 收到信令:', st)
      try {
        if (st === 'offer') {
          console.log('[Message] 处理 offer，创建 answer...')
          await handleOffer(payload.sdp, (answerPayload) => {
            console.log('[Message] 发送 answer 给 App')
            send({ type: 'signal', roomId: _currentRoomId, payload: answerPayload })
          })
          console.log('[Message] answer 已发送')
        } else if (st === 'answer') {
          await handleAnswer(payload.sdp)
        } else if (st === 'ice_candidate') {
          await handleIceCandidate(payload.candidate)
        }
      } catch (err) {
        console.error('[Message] signal error:', err)
      }
    }
    onMessage('signal', _signalHandler)
  }

  function _setupDataChannel(channel) {
    // 设置 binaryType 为 arraybuffer，确保二进制数据以 ArrayBuffer 形式接收
    if (channel.binaryType !== 'arraybuffer') {
      channel.binaryType = 'arraybuffer'
    }
    channel.onopen = () => {
      console.log('[Message] DataChannel 已打开 (onopen)')
      _clearConnectionTimeout()
      store.setConnected(true)
      store.error = null
      // 重连后恢复中断的传输
      if (Object.keys(_pendingSends).length > 0 || Object.keys(_fileMetas).length > 0) {
        _onReconnected()
      }
    }
    channel.onmessage = (event) => {
      if (typeof event.data === 'string') {
        try {
          const data = JSON.parse(event.data)
          _handleMessage(data)
        } catch (e) {
          console.error('[Message] 解析消息失败:', e)
        }
      } else if (event.data instanceof ArrayBuffer) {
        // 二进制 chunk: [1b idLen][idLen b fileId][4b seq BE][4b total BE][data]
        _handleBinaryChunk(event.data)
      } else if (event.data instanceof Blob) {
        // Blob → 读取后按二进制处理
        const reader = new FileReader()
        reader.onload = () => {
          _handleBinaryChunk(reader.result)
        }
        reader.readAsArrayBuffer(event.data)
      }
    }
    channel.onclose = () => {
      console.log('[Message] DataChannel 已关闭')
      store.setConnected(false)
    }
    channel.onerror = (err) => {
      console.error('[Message] DataChannel 错误:', err)
    }
  }

  function _handleMessage(data) {
    console.log('[Message] PC 收到消息类型:', data.type)
    switch (data.type) {
      case 'text':
        console.log('[Message] 收到文本:', data.text, '| isViewing:', store.isViewing)
        store.addMessage({
          id: data.id,
          type: 'text',
          status: 'received',
          text: data.text,
          isFromMe: false,
          // 如果正在查看消息页，直接标记已读；否则标记未读（红点）
          readStatus: store.isViewing ? 'read' : 'unread',
          timestamp: new Date(data.timestamp).toLocaleTimeString(),
        })
        // 如果在消息页面，立即通知 App 已读
        if (store.isViewing) {
          _sendReadAll()
        }
        break
      case 'file_start':
        _handleFileStart(data)
        break
      case 'file_chunk':
        _handleFileChunkData(data)
        break
      case 'file_end':
        _handleFileEnd(data)
        break
      case 'cancel':
        _handleCancel(data)
        break
      case 'cancel_ack':
        // App 端已确认取消并完成清理（含删除不完整文件），两端状态对齐
        _handleCancelAck(data)
        break
      case 'resume_state':
        _handleResumeState(data)
        break
      case 'read_all':
        // App 端已读 PC 发出的所有消息，标记 PC 的 outgoing 消息为已读
        console.log('[Message] App 端全部已读')
        store.markAllAsRead('outgoing')
        break
    }
  }

  /** 通知 App 所有消息已读 */
  function _sendReadAll() {
    if (!_dataChannel || _dataChannel.readyState !== 'open') return
    _dataChannel.send(JSON.stringify({
      type: 'read_all',
      timestamp: Date.now(),
    }))
  }

  function _handleFileStart(data) {
    const isResume = data.resume === true

    // 如果是续传且已有缓冲，复用现有缓冲
    if (isResume && _fileBuffers[data.id]) {
      const existingBuf = _fileBuffers[data.id]
      if (existingBuf.length < data.totalChunks) {
        const newBuf = new Array(data.totalChunks)
        for (let i = 0; i < existingBuf.length; i++) newBuf[i] = existingBuf[i]
        _fileBuffers[data.id] = newBuf
      }
      _fileMetas[data.id] = data
      _resetFileTransferTimer(data.id)
      console.log('[Message] 续传 file_start: id=', data.id, '已有', existingBuf.filter(Boolean).length, '个分片')
      store.updateMessage(data.id, {
        status: 'receiving',
        receivedChunks: existingBuf.filter(Boolean).length,
        progress: existingBuf.filter(Boolean).length / data.totalChunks,
      })
      return
    }

    // 缓冲区总是创建（chunk 会通过 DC 持续到达）
    _fileMetas[data.id] = data
    _fileBuffers[data.id] = new Array(data.totalChunks)
    // 已收分片计数与速率采样初始化
    _fileReceivedCount[data.id] = 0
    _fileSpeedSample[data.id] = { at: performance.now(), bytes: 0 }
    _resetFileTransferTimer(data.id)

    console.log('[Message] file_start: id=', data.id, 'fileName=', data.fileName, 'totalChunks=', data.totalChunks)

    // 直接添加消息到列表，自动接收文件（无需用户确认）
    store.addMessage({
      id: data.id,
      type: 'file',
      status: 'receiving',
      fileName: data.fileName,
      fileSize: data.fileSize,
      fileMimeType: data.fileMimeType,
      progress: 0,
      totalChunks: data.totalChunks,
      receivedChunks: 0,
      isFromMe: false,
      readStatus: store.isViewing ? 'read' : 'unread',
      timestamp: new Date().toLocaleTimeString(),
    })

    // 处理早到的 pending chunks
    if (_pendingChunks[data.id]) {
      console.log('[Message] 处理暂存的 chunks:', _pendingChunks[data.id].length, '个')
      const pending = _pendingChunks[data.id]
      delete _pendingChunks[data.id]
      pending.forEach(c => _handleFileChunkData(c))
    }
  }

  /** 解析二进制 chunk: [1b idLen][idLen b fileId][4b seq BE][4b total BE][data] */
  function _handleBinaryChunk(arrayBuffer) {
    const bytes = new Uint8Array(arrayBuffer)
    if (bytes.length < 9) {
      console.warn('[Message] 二进制包太小:', bytes.length)
      return
    }

    const idLen = bytes[0]
    const headerSize = 1 + idLen + 4 + 4
    if (bytes.length < headerSize) {
      console.warn('[Message] 二进制包头不完整: packet=', bytes.length, 'header=', headerSize, 'idLen=', idLen)
      return
    }

    // 读取 file_id
    let id = ''
    for (let i = 0; i < idLen; i++) id += String.fromCharCode(bytes[1 + i])

    // 读取 seq 和 total（big-endian uint32）
    const view = new DataView(arrayBuffer)
    const seq = view.getUint32(1 + idLen, false)
    const total = view.getUint32(1 + idLen + 4, false)

    // 提取 chunk 数据并转为 base64
    const chunkData = bytes.slice(headerSize)
    let binary = ''
    for (let i = 0; i < chunkData.length; i++) binary += String.fromCharCode(chunkData[i])
    const base64 = btoa(binary)

    // 安全网：如果 file_start 还没到，暂存 chunk
    if (!_fileBuffers[id]) {
      if (!_pendingChunks[id]) _pendingChunks[id] = []
      _pendingChunks[id].push({ id, seq, total, data: base64 })
      console.warn('[Message] chunk 早于 file_start 到达, 暂存: id=', id, 'seq=', seq, '/', total)
      return
    }

    // 每 10 个 chunk 或首尾打日志
    if (seq === 0 || seq === total - 1 || seq % 10 === 0) {
      console.log('[Message] chunk', seq, '/', total, 'size=', chunkData.length)
    }

    _handleFileChunkData({ id, seq, total, data: base64 })
  }

  function _handleFileChunkData(data) {
    const buf = _fileBuffers[data.id]
    if (!buf) {
      console.warn('[Message] ⚠ 收到未知文件 chunk: id=', data.id, 'seq=', data.seq, '/', data.total)
      return
    }
    // 跳过已接收的分片（断点续传去重）
    if (buf[data.seq]) return
    try {
      const binary = atob(data.data)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
      buf[data.seq] = bytes
    } catch (e) {
      console.error('[Message] base64 解码失败, seq:', data.seq, e)
      return
    }

    // 活动重置超时
    _resetFileTransferTimer(data.id)

    const total = data.total
    // 用计数器维护已收片数。
    // 原实现用 buf.filter(Boolean).length —— 每收一片就要遍历整个缓冲区，
    // 是 O(n²)：2GB 文件(3 万+ 片)时仅统计进度就要上亿次遍历，接收被拖到极慢。
    _fileReceivedCount[data.id] = (_fileReceivedCount[data.id] || 0) + 1
    const received = _fileReceivedCount[data.id]
    const progress = total > 0 ? received / total : 0

    // 速率采样：基于最近 1 秒接收字节数的滑动窗口，
    // 避免按「相邻两次采样」计算时数值大幅跳动。
    const now = performance.now()
    _fileReceivedBytes[data.id] = (_fileReceivedBytes[data.id] || 0) + bytes.length
    const win = _fileRateWindow[data.id] || []
    win.push({ t: now, bytes: _fileReceivedBytes[data.id] })
    while (win.length > 2 && now - win[0].t > 1000) win.shift()
    _fileRateWindow[data.id] = win

    const sample = _fileSpeedSample[data.id] || { at: 0 }
    if (now - sample.at >= SPEED_SAMPLE_MS && win.length >= 2) {
      const dtSec = (win[win.length - 1].t - win[0].t) / 1000
      const speed = dtSec > 0 ? (win[win.length - 1].bytes - win[0].bytes) / dtSec : 0
      sample.at = now
      _fileSpeedSample[data.id] = sample
      const fileSize = Number(_fileMetas[data.id]?.fileSize) || 0
      const remaining = Math.max(0, fileSize - _fileReceivedBytes[data.id])
      store.updateMessage(data.id, {
        speed,
        transferredBytes: _fileReceivedBytes[data.id],
        etaSeconds: speed > 0 ? remaining / speed : 0,
      })
    } else {
      _fileSpeedSample[data.id] = sample
    }

    // 每 10 个 chunk 或接近完成时打日志
    if (data.seq % 10 === 0 || received >= total - 1) {
      console.log('[Message] 接收进度:', received, '/', total, '=', Math.round(progress * 100), '%')
    }

    // 更新消息进度
    store.updateMessage(data.id, { receivedChunks: received, progress })

    // 全部 chunk 接收完毕 → 组装并存入 blob，显示下载按钮
    if (received >= total) {
      console.log('[Message] ✅ 所有chunk接收完毕，开始组装文件 id=', data.id)
      _assembleAndStore(data.id)
    }
  }

  function _handleFileEnd(data) {
    console.log('[Message] file_end 收到: id=', data.id)
    const buf = _fileBuffers[data.id]
    if (!buf) {
      console.warn('[Message] file_end 但无缓冲区: id=', data.id)
      return
    }
    const received = buf.filter(Boolean).length
    console.log('[Message] file_end: 已收到', received, '个chunk')
    _assembleAndStore(data.id)
  }

  // ---- 断点续传：resume_state 协议 ----

  /** 发送 resume_state：告知发送方我已收到哪些分片 */
  function _sendResumeState(fileId) {
    const buf = _fileBuffers[fileId]
    if (!buf || !_dataChannel || _dataChannel.readyState !== 'open') return
    const receivedChunks = []
    buf.forEach((chunk, idx) => { if (chunk) receivedChunks.push(idx) })
    console.log('[Message] 发送 resume_state: id=', fileId, 'received=', receivedChunks.length, '/', buf.length)
    _dataChannel.send(JSON.stringify({ type: 'resume_state', id: fileId, receivedChunks }))
  }

  /** 处理 resume_state：接收方告知我已收到哪些分片 */
  function _handleResumeState(data) {
    const id = data.id
    const receivedChunks = data.receivedChunks || []
    console.log('[Message] 收到 resume_state: id=', id, 'received=', receivedChunks.length)
    _clearFileTransferTimer(id)
    _resumeSendFile(id, receivedChunks)
  }

  /** 按已接收列表续传文件 */
  async function _resumeSendFile(fileId, receivedChunks) {
    const pending = _pendingSends[fileId]
    if (!pending) {
      console.warn('[Message] 续传请求但无待发送数据: id=', fileId)
      return
    }
    if (!_dataChannel || _dataChannel.readyState !== 'open') {
      console.warn('[Message] 续传失败：DC 未就绪')
      return
    }

    const receivedSet = new Set(receivedChunks)
    console.log('[Message] 续传文件:', pending.fileName, '已收', receivedChunks.length, '/', pending.totalChunks)

    store.updateMessage(fileId, { status: 'sending', progress: receivedChunks.length / pending.totalChunks })

    // 发送 file_start（带 resume 标记）
    _dataChannel.send(JSON.stringify({
      type: 'file_start', id: fileId, fileName: pending.fileName,
      fileSize: pending.fileSize, fileMimeType: pending.fileMimeType,
      totalChunks: pending.totalChunks, resume: true,
    }))

    const idEncoded = new TextEncoder().encode(fileId)
    const chunkSize = CHUNK_SIZE
    let sentCount = receivedChunks.length
    // 速率统计
    const startedAt = performance.now()
    let lastSampleAt = startedAt
    let lastSampleBytes = receivedChunks.length * chunkSize

    for (let i = 0; i < pending.totalChunks; i++) {
      if (receivedSet.has(i)) continue

      // 只在缓冲区水位过高时才等待（原实现每片固定 sleep 5ms，速度被锁死）
      let retryCount = 0
      while (_dataChannel && _dataChannel.bufferedAmount > CHUNK_BACKLOG_LIMIT) {
        await new Promise(r => setTimeout(r, 2))
        retryCount++
        if (retryCount > 1500 || !_dataChannel || _dataChannel.readyState !== 'open') {
          console.warn('[Message] 续传中断 at chunk', i)
          store.updateMessage(fileId, { status: 'interrupted', progress: sentCount / pending.totalChunks })
          return
        }
      }

      const s = i * chunkSize
      const e = Math.min(s + chunkSize, pending.fullData.length)
      const chunk = pending.fullData.slice(s, e)

      const headerSize = 1 + idEncoded.length + 4 + 4
      const packet = new Uint8Array(headerSize + chunk.length)
      const view = new DataView(packet.buffer)
      packet[0] = idEncoded.length
      packet.set(idEncoded, 1)
      view.setUint32(1 + idEncoded.length, i, false)
      view.setUint32(1 + idEncoded.length + 4, pending.totalChunks, false)
      packet.set(chunk, headerSize)

      _dataChannel.send(packet.buffer)
      sentCount++

      const now = performance.now()
      if (now - lastSampleAt >= SPEED_SAMPLE_MS) {
        const speed = ((sentCount * chunkSize) - lastSampleBytes) / ((now - lastSampleAt) / 1000)
        lastSampleAt = now
        lastSampleBytes = sentCount * chunkSize
        const remaining = Math.max(0, pending.fullData.length - sentCount * chunkSize)
        store.updateMessage(fileId, {
          speed,
          transferredBytes: Math.min(sentCount * chunkSize, pending.fullData.length),
          etaSeconds: speed > 0 ? remaining / speed : 0,
        })
      }
      store.updateMessage(fileId, { progress: Math.min(1, sentCount / pending.totalChunks) })
    }

    if (_cancelledSends.has(fileId)) {
      // 续传过程中被取消，保持 cancelled，不覆盖为 sent
      console.log('[Message] 续传结束但已被取消，保持 cancelled 态:', fileId)
      _cancelledSends.delete(fileId)
      return
    }
    if (_dataChannel && _dataChannel.readyState === 'open') {
      _dataChannel.send(JSON.stringify({ type: 'file_end', id: fileId }))
      store.updateMessage(fileId, { status: 'sent', progress: 1 })
    }
    delete _pendingSends[fileId]
    _clearFileTransferTimer(fileId)
  }

  /** 重连后恢复所有中断的传输 */
  function _onReconnected() {
    console.log('[Message] 重连后检查中断的传输...')
    let resumed = 0

    // 对于接收中的文件：发送 resume_state 请求续传
    for (const id of Object.keys(_fileMetas)) {
      _sendResumeState(id)
      _resetFileTransferTimer(id)
      resumed++
    }

    // 对于发送中的文件：等待接收方发来 resume_state
    for (const id of Object.keys(_pendingSends)) {
      _resetFileTransferTimer(id)
      // 设置 10 秒超时：如果收不到 resume_state，从头发送
      setTimeout(() => {
        if (_pendingSends[id] && _dataChannel && _dataChannel.readyState === 'open') {
          console.log('[Message] resume_state 响应超时，从头发送: id=', id)
          const pending = _pendingSends[id]
          const idEncoded = new TextEncoder().encode(id)
          // 注意：必须与首次发送使用一致的 CHUNK_SIZE（64KB），否则分片偏移错位导致文件损坏（P1-14）
          _sendFileChunks(id, pending.fullData, pending.totalChunks, CHUNK_SIZE, idEncoded)
        }
      }, RESUME_STATE_TIMEOUT_MS)
      resumed++
    }

    console.log('[Message] 重连检查完成:', resumed, '个传输待恢复')
  }

  // ---- 超时管理 ----

  function _resetFileTransferTimer(fileId) {
    _clearFileTransferTimer(fileId)
    _fileTransferTimers[fileId] = setTimeout(() => {
      console.warn('[Message] 传输超时:', fileId)
      delete _pendingSends[fileId]
      delete _fileBuffers[fileId]
      delete _fileMetas[fileId]
      delete _fileTransferTimers[fileId]
      store.updateMessage(fileId, { status: 'failed' })
    }, TRANSFER_TIMEOUT_MS)
  }

  function _clearFileTransferTimer(fileId) {
    if (_fileTransferTimers[fileId]) {
      clearTimeout(_fileTransferTimers[fileId])
      delete _fileTransferTimers[fileId]
    }
  }

  /** 组装 chunks 并将 blob 存入消息，自动触发浏览器下载 */
  function _assembleAndStore(fileId) {
    const buf = _fileBuffers[fileId]
    if (!buf) {
      console.warn('[Message] _assembleAndStore: 无缓冲区 id=', fileId)
      return
    }
    const meta = _fileMetas[fileId] || {}

    let total = 0
    let missing = 0
    buf.forEach(c => { if (c) total += c.length; else missing++ })
    if (total === 0) {
      console.warn('[Message] _assembleAndStore: 没有数据 id=', fileId, 'missing=', missing)
      return
    }
    if (missing > 0) {
      console.warn('[Message] _assembleAndStore: 有', missing, '个chunk缺失 id=', fileId)
    }

    const merged = new Uint8Array(total)
    let off = 0
    buf.forEach(c => {
      if (c) { merged.set(c, off); off += c.length }
    })

    console.log('[Message] 文件接收完成，存储 blob:', meta.fileName, 'size:', total)
    const blob = new Blob([merged], { type: meta.fileMimeType || 'application/octet-stream' })
    const url = URL.createObjectURL(blob)

    store.updateMessage(fileId, {
      status: 'received',
      progress: 1,
      blob,
      blobUrl: url,
      speed: 0,
      etaSeconds: 0,
    })

    console.log('[Message] 消息已更新为 received, blobUrl=', url ? '已创建' : '无')

    // 清理缓冲区和计时器
    _clearFileTransferTimer(fileId)
    delete _fileBuffers[fileId]
    delete _fileMetas[fileId]
    delete _fileSpeedSample[fileId]
    delete _fileReceivedBytes[fileId]
    delete _fileRateWindow[fileId]

    // 自动触发浏览器下载（与 Flutter 端行为保持一致）
    downloadFile(fileId)
  }

  function _handleCancel(data) {
    _clearFileTransferTimer(data.id)
    delete _pendingSends[data.id]
    delete _fileBuffers[data.id]
    delete _fileMetas[data.id]
    delete _fileReceivedCount[data.id]
    delete _fileSpeedSample[data.id]
    delete _fileReceivedBytes[data.id]
    delete _fileRateWindow[data.id]
    delete _pendingChunks[data.id]
    store.updateMessage(data.id, { status: 'cancelled', speed: 0, etaSeconds: 0 })
  }

  /** 对端（App）已确认取消：清理本端残留并同步 UI 状态 */
  function _handleCancelAck(data) {
    if (!data?.id) return
    console.log('[Message] 收到 cancel_ack: id=', data.id)
    _clearFileTransferTimer(data.id)
    delete _pendingSends[data.id]
    delete _fileBuffers[data.id]
    delete _fileMetas[data.id]
    delete _fileReceivedCount[data.id]
    delete _fileSpeedSample[data.id]
    delete _fileReceivedBytes[data.id]
    delete _fileRateWindow[data.id]
    delete _pendingChunks[data.id]
    store.updateMessage(data.id, { status: 'cancelled', speed: 0, etaSeconds: 0 })
  }

  /** 发送文本 */
  function sendText(text) {
    console.log('[Message] 尝试发送文本:', text, 'DC readyState=', _dataChannel?.readyState)
    if (!_dataChannel || _dataChannel.readyState !== 'open') {
      console.warn('[Message] DataChannel 未就绪，无法发送')
      return false
    }
    const msg = {
      id: 'msg_' + Date.now(),
      type: 'text',
      text,
      timestamp: Date.now(),
    }
    _dataChannel.send(JSON.stringify(msg))
    store.addMessage({
      id: msg.id,
      type: 'text',
      status: 'sending',
      text,
      isFromMe: true,
      readStatus: 'unread',
      timestamp: new Date().toLocaleTimeString(),
    })
    setTimeout(() => {
      store.updateMessage(msg.id, { status: 'sent' })
    }, 100)
    return true
  }

  /** 选择并发送文件（带流控） */
  function pickAndSendFile() {
    if (!_dataChannel || _dataChannel.readyState !== 'open') {
      console.warn('[Message] DataChannel 未就绪，无法发送文件')
      return
    }
    const input = document.createElement('input')
    input.type = 'file'
    input.onchange = async () => {
      const file = input.files[0]
      if (!file || !_dataChannel) return
      const msgId = 'file_' + Date.now()
      const chunkSize = CHUNK_SIZE
      const totalChunks = Math.ceil(file.size / chunkSize)

      // 发送 file_start
      _dataChannel.send(JSON.stringify({
        type: 'file_start', id: msgId, fileName: file.name,
        fileSize: file.size, fileMimeType: file.type,
        totalChunks,
      }))
      store.addMessage({
        id: msgId, type: 'file', status: 'sending',
        fileName: file.name, fileSize: file.size, progress: 0,
        isFromMe: true, readStatus: 'unread',
        timestamp: new Date().toLocaleTimeString(),
      })

      // 流控发送每个 chunk（二进制格式）
      const arrayBuffer = await file.arrayBuffer()
      const fullData = new Uint8Array(arrayBuffer)

      // 保存待发送数据（用于断点续传）
      _pendingSends[msgId] = {
        id: msgId, fileName: file.name, fileSize: file.size,
        fileMimeType: file.type, totalChunks, fullData,
      }
      _resetFileTransferTimer(msgId)

      // 预先编码 file_id
      const idEncoded = new TextEncoder().encode(msgId)

      await _sendFileChunks(msgId, fullData, totalChunks, chunkSize, idEncoded)
    }
    input.click()
  }

  /** 发送文件分片（支持全新发送和续传） */
  async function _sendFileChunks(msgId, fullData, totalChunks, chunkSize, idEncoded, receivedSet = new Set()) {
    // 速率统计：只按采样间隔回写 UI，避免每片更新把主线程打满
    const startedAt = performance.now()
    let lastSampleAt = startedAt
    let lastSampleBytes = 0

    for (let i = 0; i < totalChunks; i++) {
      if (_cancelledSends.has(msgId)) {
        // 已被取消：立即中断发送，绝不写 file_end / sent，保留 cancelled 态
        console.log('[Message] 发送被取消，中断分片循环:', msgId)
        return
      }
      if (receivedSet.has(i)) continue // 跳过已收到的

      // 动态等待缓冲区释放（防止溢出断开）。
      // 注意：这里绝不能再「每片固定 sleep」—— 那正是旧实现吞吐只有 ~3MB/s 的原因。
      let retryCount = 0
      while (_dataChannel && _dataChannel.bufferedAmount > CHUNK_BACKLOG_LIMIT) {
        await new Promise(r => setTimeout(r, 2))
        retryCount++
        if (retryCount > 1500) {
          console.error('[Message] 文件传输超时：DC 缓冲区持续满载')
          store.updateMessage(msgId, { status: 'interrupted' })
          return
        }
        if (!_dataChannel || _dataChannel.readyState !== 'open') {
          console.error('[Message] 文件传输中断：DC 已关闭')
          store.updateMessage(msgId, { status: 'interrupted' })
          return
        }
      }

      const s = i * chunkSize
      if (s >= fullData.length) break
      const e = Math.min(s + chunkSize, fullData.length)
      const chunk = fullData.slice(s, e)

      const headerSize = 1 + idEncoded.length + 4 + 4
      const packet = new Uint8Array(headerSize + chunk.length)
      const view = new DataView(packet.buffer)
      packet[0] = idEncoded.length
      packet.set(idEncoded, 1)
      view.setUint32(1 + idEncoded.length, i, false)
      view.setUint32(1 + idEncoded.length + 4, totalChunks, false)
      packet.set(chunk, headerSize)

      _dataChannel.send(packet.buffer)

      const now = performance.now()
      if (now - lastSampleAt >= SPEED_SAMPLE_MS) {
        const speed = ((i + 1) * chunkSize - lastSampleBytes) / ((now - lastSampleAt) / 1000)
        lastSampleAt = now
        lastSampleBytes = (i + 1) * chunkSize
        const remaining = Math.max(0, fullData.length - (i + 1) * chunkSize)
        store.updateMessage(msgId, {
          speed,
          transferredBytes: Math.min((i + 1) * chunkSize, fullData.length),
          etaSeconds: speed > 0 ? remaining / speed : 0,
        })
      }
      store.updateMessage(msgId, { progress: Math.min(1, (i + 1) / totalChunks) })
    }

    if (_cancelledSends.has(msgId)) {
      // 发送过程中被取消，不要下发 file_end，也不要把状态改回 sent（保留 cancelled）
      console.log('[Message] 发送循环结束但已被取消，保持 cancelled 态:', msgId)
      _cancelledSends.delete(msgId)
      return
    }
    if (_dataChannel && _dataChannel.readyState === 'open') {
      _dataChannel.send(JSON.stringify({ type: 'file_end', id: msgId }))
      store.updateMessage(msgId, { status: 'sent', progress: 1 })
      // 发送成功，清理待发送记录
      delete _pendingSends[msgId]
      _clearFileTransferTimer(msgId)
    }
  }

  /** 已在发送中被取消的文件 id（防止发送循环结束后把状态覆盖回 sent） */
  const _cancelledSends = new Set()

  /** 取消传输 */
  function cancelTransfer(id) {
    _cancelledSends.add(id)
    if (_dataChannel && _dataChannel.readyState === 'open') {
      _dataChannel.send(JSON.stringify({ type: 'cancel', id }))
    }
    _clearFileTransferTimer(id)
    delete _pendingSends[id]
    delete _fileBuffers[id]
    delete _fileMetas[id]
    delete _fileReceivedCount[id]
    delete _fileSpeedSample[id]
    delete _pendingChunks[id]
    store.updateMessage(id, { status: 'cancelled', speed: 0 })
  }

  /** 断开当前会话（保持 invitation 监听，可接受新连接） */
  function disconnect() {
    console.log('[Message] 断开消息通道（保持文件状态以便续传）')
    _clearConnectionTimeout()
    if (_currentRoomId) send({ type: 'close_room', roomId: _currentRoomId })
    // 只清理当前会话的 handlers，不清理 invitation/room_closed（保持可重连）
    if (_signalHandler) {
      offMessage('signal', _signalHandler)
      _signalHandler = null
    }
    if (_iceCandidateCb) {
      offIceCandidate(_iceCandidateCb)
      _iceCandidateCb = null
    }
    if (_dataChannelCb) {
      offDataChannel(_dataChannelCb)
      _dataChannelCb = null
    }
    rtcClose()
    store.setConnected(false)
    store.isConnecting = false
    store.roomId = null
    _currentRoomId = null
    _currentRoomType = null
    _dataChannel = null
    // 注意：不清理 _fileBuffers、_fileMetas、_pendingSends、_fileTransferTimers
    // 这些数据保留以便重连后断点续传
    // 标记进行中的消息为 interrupted
    store.messages.forEach(m => {
      if (m.status === 'sending' || m.status === 'receiving') {
        store.updateMessage(m.id, { status: 'interrupted' })
      }
    })
  }

  function _clearConnectionTimeout() {
    if (_connectionTimeout) {
      clearTimeout(_connectionTimeout)
      _connectionTimeout = null
    }
  }

  /** 触发浏览器下载文件（由消息页面的下载按钮调用） */
  function downloadFile(fileId) {
    const msg = store.messages.find(m => m.id === fileId)
    if (!msg || !msg.blobUrl) return
    const a = document.createElement('a')
    a.href = msg.blobUrl
    a.download = msg.fileName || 'file'
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
  }

  _instance = {
    startListening,
    createRoom,
    sendText,
    pickAndSendFile,
    cancelTransfer,
    disconnect,
    downloadFile,
  }
  return _instance
}
