import { ref, shallowRef } from 'vue'
import { useWebSocket } from './useWebSocket'
import { useWebRTC } from './useWebRTC'
import { useMessageStore } from '../stores/message'
import { md5 } from '../utils/md5'

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

  // ---- 并行分片传输（新协议：file_meta / file_chunk / file_resume_request / file_complete）----
  /**
   * 分片大小 64KB。
   * 原来是 16KB 且每片强制 sleep(5ms)，吞吐被人为压到 ~3MB/s；
   * 64KB 兼顾「单条消息不超过各浏览器 256KB 上限」与「包数量减少 4 倍」。
   */
  const CHUNK_SIZE = 64 * 1024
  /** 并行 DataChannel 条数（只跑 file_chunk；控制消息仍走 message 通道，避免互相阻塞） */
  const FILE_CHANNEL_COUNT = 3
  const FILE_CHANNEL_LABELS = Array.from({ length: FILE_CHANNEL_COUNT }, (_, i) => `file-${i}`)
  /** 分片通道：label -> RTCDataChannel */
  const _fileChannels = {}
  /**
   * 新协议接收态
   * { [fileId]: { fileName, fileSize, fileMimeType, fileHash, chunkSize, totalChunks,
   *               buffer: Array<Uint8Array|undefined>, received: number } }
   */
  const _chunkRecv = {}
  /**
   * 新协议发送态（用于断点续传：重连后只补发对端缺失的分片）
   * { [fileId]: { fileName, fileSize, fileMimeType, fileHash, chunkSize, totalChunks, fullData: Uint8Array } }
   */
  const _chunkSends = {}

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
    _dataChannel = createDataChannel('message')
    _setupDataChannel(_dataChannel)

    // 并行分片通道：必须在 createOffer() 之前创建，
    // 否则 SDP 里不包含这些通道的 m=application，对端根本收不到。
    _createFileChannels()

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
      // 按 label 分流：file-N 是并行分片通道，不参与连接态判定
      if (FILE_CHANNEL_LABELS.includes(channel.label)) {
        _fileChannels[channel.label] = channel
        _setupFileChannel(channel)
        return
      }
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
    // 新协议：为未收完的文件向对端发 file_resume_request（内部为空时直接 no-op）
    _requestResumeForIncoming()
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
        // 新协议带 fileId/chunkIndex；老二进制协议走的是 id/seq，据此分流
        if (data.fileId !== undefined) _handleFileChunkNew(data)
        else _handleFileChunkData(data)
        break
      case 'file_meta':
        _handleFileMeta(data)
        break
      case 'file_resume_request':
        _handleFileResumeRequest(data)
        break
      case 'file_complete':
        // 对端已发完全部分片；若本地也已收满则收尾（正常路径已由收满触发，这里只兜底）
        if (_chunkRecv[data.fileId]) _finalizeIncomingFile(data.fileId)
        break
      case 'file_end':
        _handleFileEnd(data)
        break
      case 'cancel':
        _handleCancel(data)
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
    const received = buf.filter(Boolean).length
    const progress = received / total

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
    const chunkSize = 16384
    let sentCount = receivedChunks.length

    for (let i = 0; i < pending.totalChunks; i++) {
      if (receivedSet.has(i)) continue

      let retryCount = 0
      while (_dataChannel && _dataChannel.bufferedAmount > chunkSize * 8) {
        await new Promise(r => setTimeout(r, 10))
        retryCount++
        if (retryCount > 500 || !_dataChannel || _dataChannel.readyState !== 'open') {
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
      store.updateMessage(fileId, { progress: Math.min(1, sentCount / pending.totalChunks) })

      await new Promise(r => setTimeout(r, 5))
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
          _sendFileChunks(id, pending.fullData, pending.totalChunks, 16384, idEncoded)
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
    })

    console.log('[Message] 消息已更新为 received, blobUrl=', url ? '已创建' : '无')

    // 清理缓冲区和计时器
    _clearFileTransferTimer(fileId)
    delete _fileBuffers[fileId]
    delete _fileMetas[fileId]

    // 自动触发浏览器下载（与 Flutter 端行为保持一致）
    downloadFile(fileId)
  }

  function _handleCancel(data) {
    _clearFileTransferTimer(data.id)
    delete _pendingSends[data.id]
    delete _fileBuffers[data.id]
    delete _fileMetas[data.id]
    store.updateMessage(data.id, { status: 'cancelled' })
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

  // ==================== 并行分片传输（新协议）====================

  /**
   * 创建 3 条并行分片通道。
   *
   * 必须在 createOffer() 之前调用：DataChannel 建在 offer 之后，SDP 中不会包含
   * 对应的 m=application，对端就拿不到这些通道。
   */
  function _createFileChannels() {
    for (const label of FILE_CHANNEL_LABELS) {
      if (_fileChannels[label]) continue
      try {
        const ch = createDataChannel(label)
        _fileChannels[label] = ch
        _setupFileChannel(ch)
        console.log('[Message] 分片通道已创建:', label)
      } catch (e) {
        console.warn('[Message] 创建分片通道失败:', label, e)
      }
    }
  }

  /**
   * 分片通道只负责 file_chunk，不参与连接态判定。
   * 不能复用 _setupDataChannel —— 后者每条通道 open 都会触发 _onReconnected()，
   * 3 条通道会重复触发续传。
   */
  function _setupFileChannel(channel) {
    channel.onmessage = (event) => {
      if (typeof event.data !== 'string') return
      try {
        const data = JSON.parse(event.data)
        if (data.type === 'file_chunk') _handleFileChunkNew(data)
      } catch (e) {
        console.error('[Message] 分片通道消息解析失败:', e)
      }
    }
    // 分片通道打开后，若本地有未收完的文件，立即向对端请求续传
    channel.onopen = () => {
      console.log('[Message] 分片通道已打开:', channel.label)
      _requestResumeForIncoming()
    }
    channel.onerror = (e) => console.warn('[Message] 分片通道错误:', channel.label, e)
  }

  /** 关闭并清理所有并行分片通道（会话结束时必须调用，否则闭包引用泄漏） */
  function _closeFileChannels() {
    for (const label of Object.keys(_fileChannels)) {
      const ch = _fileChannels[label]
      try { if (ch && ch.readyState !== 'closed') ch.close() } catch (_) {}
      delete _fileChannels[label]
    }
  }

  /** 当前可用的分片通道（已 open 的 file-N） */
  function _openFileChannels() {
    return FILE_CHANNEL_LABELS
      .map((l) => _fileChannels[l])
      .filter((c) => c && c.readyState === 'open')
  }

  /** base64 编码一段字节（分片协议要求 JSON 可序列化） */
  function _toBase64(bytes) {
    let binary = ''
    const CH = 0x8000
    for (let i = 0; i < bytes.length; i += CH) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CH))
    }
    return btoa(binary)
  }

  /** base64 解码为 Uint8Array */
  function _fromBase64(b64) {
    const binary = atob(b64)
    const out = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i)
    return out
  }

  /** 等待某条通道的发送缓冲降到阈值以下（事件驱动 + 轮询兜底） */
  function _waitDrain(channel, limit) {
    return new Promise((resolve) => {
      if (!channel || channel.readyState !== 'open') return resolve(false)
      if ((channel.bufferedAmount || 0) <= limit) return resolve(true)

      const done = (ok) => {
        channel.onbufferedamountlow = null
        clearTimeout(timer)
        resolve(ok)
      }
      // 低水位阈值：降到 256KB 以下就继续发
      try {
        channel.bufferedAmountLowThreshold = Math.min(256 * 1024, limit)
        channel.onbufferedamountlow = () => done(true)
      } catch (_) { /* 部分浏览器不支持时走轮询兜底 */ }

      // 兜底：最多等 10 秒，避免永久挂起（这正是旧实现连接卡死的成因）
      const timer = setTimeout(() => done(channel.readyState === 'open'), 10000)
      const poll = setInterval(() => {
        if (!channel || channel.readyState !== 'open') { clearInterval(poll); done(false); return }
        if ((channel.bufferedAmount || 0) <= limit) { clearInterval(poll); done(true) }
      }, 20)
    })
  }

  /**
   * 把分片按「轮询」分摊到 3 条并行通道上发送。
   * 只发 skip（对端已收）之外的分片 —— 这就是断点续传的补发逻辑。
   */
  async function _sendChunksParallel(fileId, sendState, skipSet = new Set()) {
    const { fullData, chunkSize, totalChunks } = sendState
    const channels = _openFileChannels()
    if (channels.length === 0) {
      console.warn('[Message] 无可用分片通道，降级为控制通道发送')
      channels.push(_dataChannel)
    }

    let next = 0
    let sent = skipSet.size

    /** 单条通道的发送协程：不断从 next 取下一个待发分片 */
    async function worker(channel, lane) {
      for (;;) {
        const i = next++
        if (i >= totalChunks) return
        if (skipSet.has(i)) continue

        const ok = await _waitDrain(channel, 1024 * 1024)
        if (!ok) { next-- ; return }   // 通道已断，把序号还回去交给别的 worker 或下次续传

        const s = i * chunkSize
        const e = Math.min(s + chunkSize, fullData.length)
        const chunk = fullData.subarray(s, e)

        channel.send(JSON.stringify({
          type: 'file_chunk',
          fileId,
          chunkIndex: i,
          isLast: i === totalChunks - 1,
          data: _toBase64(chunk),
        }))

        sent++
        store.updateMessage(fileId, {
          progress: Math.min(1, sent / totalChunks),
          receivedChunks: sent,
        })
      }
    }

    await Promise.all(channels.map((c, lane) => worker(c, lane)))

    // 全部发完 → 通知对端可以校验了
    if (_dataChannel && _dataChannel.readyState === 'open') {
      _dataChannel.send(JSON.stringify({ type: 'file_complete', fileId }))
    }
    store.updateMessage(fileId, { status: 'sent', progress: 1 })
    delete _chunkSends[fileId]
    _clearFileTransferTimer(fileId)
    console.log('[Message] 文件发送完成:', sendState.fileName, '分片数:', totalChunks)
  }

  /** 处理对端的续传请求：只补发它缺失的分片 */
  function _handleFileResumeRequest(data) {
    const fileId = data.fileId
    const state = _chunkSends[fileId]
    if (!state) {
      console.warn('[Message] 收到续传请求但无待发数据: fileId=', fileId)
      return
    }
    const skip = new Set(Array.isArray(data.receivedChunks) ? data.receivedChunks : [])
    console.log('[Message] 断点续传：已收', skip.size, '/', state.totalChunks, '，补发剩余分片')
    store.updateMessage(fileId, {
      status: 'sending',
      progress: skip.size / state.totalChunks,
      receivedChunks: skip.size,
    })
    _sendChunksParallel(fileId, state, skip)
  }

  /** 收到 file_meta：建立接收缓冲 */
  function _handleFileMeta(data) {
    const { fileId, fileName, fileSize, fileHash, totalChunks, chunkSize, fileMimeType } = data
    if (!fileId || !totalChunks) return
    _chunkRecv[fileId] = {
      fileName: fileName || 'file',
      fileSize: fileSize || 0,
      fileMimeType: fileMimeType || 'application/octet-stream',
      fileHash: fileHash || '',
      chunkSize: chunkSize || CHUNK_SIZE,
      totalChunks,
      buffer: new Array(totalChunks),
      received: 0,
    }
    _resetFileTransferTimer(fileId)
    store.addMessage({
      id: fileId, type: 'file', status: 'receiving',
      fileName: fileName || 'file', fileSize: fileSize || 0,
      fileMimeType: fileMimeType || 'application/octet-stream',
      progress: 0, totalChunks, receivedChunks: 0,
      isFromMe: false,
      readStatus: store.isViewing ? 'read' : 'unread',
      timestamp: new Date().toLocaleTimeString(),
    })
    console.log('[Message] file_meta:', fileName, (fileSize / 1024).toFixed(1) + 'KB', '分片:', totalChunks)
  }

  /** 收到一个分片（可能来自任意一条并行通道） */
  function _handleFileChunkNew(data) {
    const rec = _chunkRecv[data.fileId]
    if (!rec) {
      console.warn('[Message] 收到未知名分片 fileId=', data.fileId)
      return
    }
    const idx = data.chunkIndex
    if (rec.buffer[idx]) return          // 去重
    rec.buffer[idx] = _fromBase64(data.data)
    rec.received++
    _resetFileTransferTimer(data.fileId)
    store.updateMessage(data.fileId, {
      receivedChunks: rec.received,
      progress: rec.received / rec.totalChunks,
    })
    // 收满即校验（不等 file_complete，避免对端丢包时卡住）
    if (rec.received >= rec.totalChunks) _finalizeIncomingFile(data.fileId)
  }

  /** 组装 + MD5 校验 + 触发浏览器下载 */
  function _finalizeIncomingFile(fileId) {
    const rec = _chunkRecv[fileId]
    if (!rec) return
    let total = 0
    for (const c of rec.buffer) if (c) total += c.length

    const merged = new Uint8Array(total)
    let off = 0
    for (const c of rec.buffer) { if (c) { merged.set(c, off); off += c.length } }

    // 完整性校验：长度不符或 MD5 不一致都判为损坏，绝不静默给出残缺文件
    const hash = md5(merged)
    const hashOk = !rec.fileHash || hash === rec.fileHash
    const sizeOk = rec.fileSize === 0 || merged.length === rec.fileSize

    if (!hashOk || !sizeOk) {
      console.error('[Message] ❌ 文件校验失败:', rec.fileName, { hashOk, sizeOk, got: hash, want: rec.fileHash })
      store.updateMessage(fileId, {
        status: 'failed',
        error: !sizeOk ? '文件大小不一致，传输可能损坏' : 'MD5 校验不一致，文件已损坏',
      })
      delete _chunkRecv[fileId]
      _clearFileTransferTimer(fileId)
      return
    }

    const blob = new Blob([merged], { type: rec.fileMimeType })
    const url = URL.createObjectURL(blob)
    store.updateMessage(fileId, { status: 'received', progress: 1, blob, blobUrl: url })
    delete _chunkRecv[fileId]
    _clearFileTransferTimer(fileId)
    console.log('[Message] ✅ 文件接收完成并通过 MD5 校验:', rec.fileName)
    downloadFile(fileId)   // Web 端无需目录保存，直接触发浏览器下载
  }

  /** 重连后：为所有未收完的文件向发送方请求续传 */
  function _requestResumeForIncoming() {
    for (const fileId of Object.keys(_chunkRecv)) {
      const rec = _chunkRecv[fileId]
      const received = []
      rec.buffer.forEach((c, i) => { if (c) received.push(i) })
      if (_dataChannel && _dataChannel.readyState === 'open') {
        console.log('[Message] 请求续传:', rec.fileName, received.length, '/', rec.totalChunks)
        _dataChannel.send(JSON.stringify({
          type: 'file_resume_request', fileId, receivedChunks: received,
        }))
        _resetFileTransferTimer(fileId)
      }
    }
  }

  /** 选择并发送文件（新协议：MD5 + 64KB 分片 + 3 通道并行） */
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
      const fileId = 'file_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8)
      const totalChunks = Math.max(1, Math.ceil(file.size / CHUNK_SIZE))

      // 整文件读入内存计算 MD5（后续可改为流式，当前优先保证校验正确）
      const fullData = new Uint8Array(await file.arrayBuffer())
      const fileHash = md5(fullData)

      const state = {
        fileName: file.name,
        fileSize: file.size,
        fileMimeType: file.type || 'application/octet-stream',
        fileHash,
        chunkSize: CHUNK_SIZE,
        totalChunks,
        fullData,
      }
      _chunkSends[fileId] = state
      _resetFileTransferTimer(fileId)

      // 先发元信息（走控制通道，保证顺序先于分片到达）
      _dataChannel.send(JSON.stringify({
        type: 'file_meta', fileId,
        fileName: file.name, fileSize: file.size,
        fileMimeType: state.fileMimeType,
        fileHash, chunkSize: CHUNK_SIZE, totalChunks,
      }))
      store.addMessage({
        id: fileId, type: 'file', status: 'sending',
        fileName: file.name, fileSize: file.size,
        fileMimeType: state.fileMimeType,
        progress: 0, totalChunks, receivedChunks: 0,
        isFromMe: true, readStatus: 'unread',
        timestamp: new Date().toLocaleTimeString(),
      })

      await _sendChunksParallel(fileId, state)
    }
    input.click()
  }

  /** 发送文件分片（支持全新发送和续传） */
  async function _sendFileChunks(msgId, fullData, totalChunks, chunkSize, idEncoded, receivedSet = new Set()) {
    for (let i = 0; i < totalChunks; i++) {
      if (receivedSet.has(i)) continue // 跳过已收到的

      // 动态等待缓冲区释放（防止溢出断开）
      let retryCount = 0
      while (_dataChannel && _dataChannel.bufferedAmount > chunkSize * 8) {
        await new Promise(r => setTimeout(r, 10))
        retryCount++
        if (retryCount > 500) {
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
      store.updateMessage(msgId, { progress: Math.min(1, (i + 1) / totalChunks) })

      await new Promise(r => setTimeout(r, 5))
    }

    if (_dataChannel && _dataChannel.readyState === 'open') {
      _dataChannel.send(JSON.stringify({ type: 'file_end', id: msgId }))
      store.updateMessage(msgId, { status: 'sent', progress: 1 })
      // 发送成功，清理待发送记录
      delete _pendingSends[msgId]
      _clearFileTransferTimer(msgId)
    }
  }

  /** 取消传输 */
  function cancelTransfer(id) {
    if (_dataChannel) {
      _dataChannel.send(JSON.stringify({ type: 'cancel', id }))
    }
    _clearFileTransferTimer(id)
    delete _pendingSends[id]
    delete _fileBuffers[id]
    delete _fileMetas[id]
    store.updateMessage(id, { status: 'cancelled' })
  }

  /** 断开当前会话（保持 invitation 监听，可接受新连接） */
  function disconnect() {
    console.log('[Message] 断开消息通道（保持文件状态以便续传）')
    _clearConnectionTimeout()
    // 先逐条关闭并行分片通道：useWebRTC 的 resetPC 只关它记录的最后一条，
    // 不主动关会留下 channel 闭包引用
    _closeFileChannels()
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
