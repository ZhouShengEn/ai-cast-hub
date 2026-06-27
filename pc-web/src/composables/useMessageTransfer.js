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
  } = useWebRTC()

  let _currentRoomId = null
  let _dataChannel = null
  let _fileBuffers = {}
  let _fileMetas = {}

  /** 待确认的文件列表（file_start 后、用户确认前） */
  const pendingFile = shallowRef(null)

  // 回调引用
  let _invitationHandler = null
  let _signalHandler = null
  let _roomClosedHandler = null
  let _iceCandidateCb = null
  let _dataChannelCb = null

  /** 开始监听消息房间邀请 */
  function startListening() {
    console.log('[Message] 启动全局消息通道监听')

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
      _handleInvitation(msg)
    }
    onMessage('room_invitation', _invitationHandler)

    _roomClosedHandler = (msg) => {
      console.log('[Message] 收到 room_closed:', msg.roomId)
      if (_currentRoomId && msg.roomId === _currentRoomId) {
        console.log('[Message] 房间关闭，断开消息通道')
        disconnect()
      }
    }
    onMessage('room_closed', _roomClosedHandler)
  }

  async function _handleInvitation(msg) {
    const roomId = msg.roomId
    if (!roomId) {
      console.warn('[Message] room_invitation 缺少 roomId')
      return
    }
    console.log('[Message] 处理房间邀请 roomId=', roomId)
    _currentRoomId = roomId
    store.roomId = roomId
    store.isConnecting = true

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
      store.setConnected(true)
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
        // 二进制数据 → 转 base64 后按 chunk 协议解析（兼容性路径）
        const bytes = new Uint8Array(event.data)
        let binary = ''
        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
        const base64 = btoa(binary)
        // 构造与 JSON file_chunk 相同的结构
        console.warn('[Message] 收到二进制数据，大小:', bytes.length, '转为 base64 处理')
        _handleMessage({ type: 'file_chunk', id: 'bin_' + Date.now(), seq: 0, total: 1, data: base64 })
      } else if (event.data instanceof Blob) {
        // Blob → 读取后按二进制处理
        const reader = new FileReader()
        reader.onload = () => {
          const bytes = new Uint8Array(reader.result)
          let binary = ''
          for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
          const base64 = btoa(binary)
          console.warn('[Message] 收到 Blob 数据，大小:', bytes.length, '转为 base64 处理')
          _handleMessage({ type: 'file_chunk', id: 'blob_' + Date.now(), seq: 0, total: 1, data: base64 })
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
      case 'read_all':
        // App 端进入消息页面，已读 PC 发过去的所有消息
        console.log('[Message] App 端全部已读')
        store.markAllAsRead()
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
    // 缓冲区总是创建（chunk 会通过 DC 持续到达）
    _fileMetas[data.id] = data
    _fileBuffers[data.id] = new Array(data.totalChunks)

    // 将文件设为待确认状态，弹出确认弹窗
    const fileInfo = {
      id: data.id,
      type: 'file',
      status: 'pending_confirm',
      fileName: data.fileName,
      fileSize: data.fileSize,
      fileMimeType: data.fileMimeType,
      progress: 0,
      totalChunks: data.totalChunks,
      receivedChunks: 0,
      isFromMe: false,
      readStatus: store.isViewing ? 'read' : 'unread',
      timestamp: new Date().toLocaleTimeString(),
    }
    pendingFile.value = fileInfo
  }

  /** 用户确认接收文件 */
  function confirmFile(fileId) {
    const meta = _fileMetas[fileId]
    if (!meta) return
    const existing = pendingFile.value
    if (!existing || existing.id !== fileId) return

    // 计算已收到的 chunk 进度
    const buf = _fileBuffers[fileId]
    const received = buf ? buf.filter(Boolean).length : 0
    const progress = meta.totalChunks > 0 ? received / meta.totalChunks : 0

    store.addMessage({
      id: fileId,
      type: 'file',
      status: progress >= 1 ? 'received' : 'receiving',
      fileName: meta.fileName,
      fileSize: meta.fileSize,
      fileMimeType: meta.fileMimeType,
      progress,
      totalChunks: meta.totalChunks,
      receivedChunks: received,
      isFromMe: false,
      readStatus: store.isViewing ? 'read' : 'unread',
      timestamp: new Date().toLocaleTimeString(),
    })

    // 如果所有 chunk 已经在确认前到达，立即组装并显示下载按钮
    if (progress >= 1) {
      _assembleAndStore(fileId)
    }

    pendingFile.value = null
  }

  /** 用户拒绝接收文件 */
  function rejectFile(fileId) {
    delete _fileBuffers[fileId]
    delete _fileMetas[fileId]
    if (_dataChannel && _dataChannel.readyState === 'open') {
      _dataChannel.send(JSON.stringify({ type: 'cancel', id: fileId }))
    }
    pendingFile.value = null
  }

  function _handleFileChunkData(data) {
    const buf = _fileBuffers[data.id]
    if (!buf) return
    try {
      const binary = atob(data.data)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
      buf[data.seq] = bytes
    } catch (e) {
      console.error('[Message] base64 解码失败, seq:', data.seq, e)
      return
    }

    const total = data.total
    const received = buf.filter(Boolean).length
    const progress = received / total

    // 如果文件已确认（在消息列表中），更新消息进度
    const existingMsg = store.messages.find(m => m.id === data.id)
    if (existingMsg) {
      store.updateMessage(data.id, { receivedChunks: received, progress })
    }

    // 更新待确认文件的进度
    if (pendingFile.value && pendingFile.value.id === data.id) {
      pendingFile.value = { ...pendingFile.value, receivedChunks: received, progress }
    }

    // 全部 chunk 接收完毕
    if (received >= total) {
      if (existingMsg) {
        // 已确认 → 组装并存入 blob，显示下载按钮
        _assembleAndStore(data.id)
      }
      // 未确认 → 不组装，等待用户确认后再组装
    }
  }

  function _handleFileEnd(data) {
    // 如果已确认，组装并存储 blob
    const existingMsg = store.messages.find(m => m.id === data.id)
    if (existingMsg) {
      _assembleAndStore(data.id)
    }
    // 未确认则不做任何事，等待用户确认时再组装
  }

  /** 组装 chunks 并将 blob 存入消息，自动触发浏览器下载 */
  function _assembleAndStore(fileId) {
    const buf = _fileBuffers[fileId]
    if (!buf) return
    const meta = _fileMetas[fileId] || {}

    let total = 0
    buf.forEach(c => { if (c) total += c.length })
    if (total === 0) return

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

    // 清理缓冲区
    delete _fileBuffers[fileId]
    delete _fileMetas[fileId]

    // 自动触发浏览器下载（与 Flutter 端行为保持一致）
    downloadFile(fileId)
  }

  function _handleCancel(data) {
    delete _fileBuffers[data.id]
    delete _fileMetas[data.id]
    store.updateMessage(data.id, { status: 'cancelled' })
    if (pendingFile.value && pendingFile.value.id === data.id) {
      pendingFile.value = null
    }
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
      const chunkSize = 16384
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

      // 流控发送每个 chunk
      const arrayBuffer = await file.arrayBuffer()
      const fullData = new Uint8Array(arrayBuffer)

      for (let i = 0; i < totalChunks; i++) {
        // 等待缓冲区释放（防止溢出断开）
        while (_dataChannel && _dataChannel.bufferedAmount > chunkSize * 4) {
          await new Promise(r => setTimeout(r, 10))
          if (!_dataChannel || _dataChannel.readyState !== 'open') {
            console.error('[Message] 文件传输中断：DC 已关闭')
            store.updateMessage(msgId, { status: 'failed' })
            return
          }
        }

        const s = i * chunkSize
        const e = Math.min(s + chunkSize, file.size)
        const chunk = fullData.slice(s, e)
        // 转为 base64
        let binary = ''
        for (let j = 0; j < chunk.length; j++) binary += String.fromCharCode(chunk[j])
        const base64 = btoa(binary)

        _dataChannel.send(JSON.stringify({
          type: 'file_chunk', id: msgId, seq: i, total: totalChunks, data: base64,
        }))
        store.updateMessage(msgId, { progress: Math.min(1, (i + 1) / totalChunks) })

        // 每个 chunk 后固定延迟，防止 DataChannel 缓冲区溢出
        await new Promise(r => setTimeout(r, 15))
      }

      if (_dataChannel && _dataChannel.readyState === 'open') {
        _dataChannel.send(JSON.stringify({ type: 'file_end', id: msgId }))
        store.updateMessage(msgId, { status: 'sent', progress: 1 })
      }
    }
    input.click()
  }

  /** 取消传输 */
  function cancelTransfer(id) {
    if (_dataChannel) {
      _dataChannel.send(JSON.stringify({ type: 'cancel', id }))
    }
    delete _fileBuffers[id]
    delete _fileMetas[id]
    store.updateMessage(id, { status: 'cancelled' })
  }

  /** 断开 */
  function disconnect() {
    console.log('[Message] 断开消息通道')
    if (_currentRoomId) send({ type: 'close_room', roomId: _currentRoomId })
    if (_invitationHandler) offMessage('room_invitation', _invitationHandler)
    if (_signalHandler) offMessage('signal', _signalHandler)
    if (_roomClosedHandler) offMessage('room_closed', _roomClosedHandler)
    if (_iceCandidateCb) offIceCandidate(_iceCandidateCb)
    if (_dataChannelCb) offDataChannel(_dataChannelCb)
    rtcClose()
    store.setConnected(false)
    store.isConnecting = false
    store.roomId = null
    _currentRoomId = null
    _dataChannel = null
    _fileBuffers = {}
    _fileMetas = {}
    pendingFile.value = null
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
    sendText,
    pickAndSendFile,
    cancelTransfer,
    disconnect,
    pendingFile,
    confirmFile,
    rejectFile,
    downloadFile,
  }
  return _instance
}
