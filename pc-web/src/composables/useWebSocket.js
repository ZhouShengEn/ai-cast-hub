import { ref, onUnmounted } from 'vue'

/**
 * WebSocket 管理 Composable
 *
 * 连接 ws://localhost:3000，自动重连（指数退避），心跳保活，
 * 根据 message.type 分发消息到注册的回调。
 *
 * @returns {{ send, onMessage, offMessage, connectionState, connect, disconnect }}
 */
export function useWebSocket() {
  /** 连接状态: 'connecting' | 'connected' | 'disconnected' | 'reconnecting' */
  const connectionState = ref('disconnected')

  let ws = null
  let pingTimer = null
  let pongTimer = null
  let reconnectTimer = null
  let reconnectDelay = 1000
  const MAX_RECONNECT_DELAY = 30000
  const PING_INTERVAL = 30000
  const PONG_TIMEOUT = 60000
  const listeners = new Map()

  /** 建立 WebSocket 连接 */
  function connect() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
      return
    }

    const deviceUuid = localStorage.getItem('deviceUuid') || ''
    const transferKey = localStorage.getItem('transferKey') || ''
    // 动态构建 WebSocket URL，适配开发代理和生产环境
    const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const url = `${wsProtocol}//${window.location.host}/ws?deviceUuid=${encodeURIComponent(deviceUuid)}&transferKey=${encodeURIComponent(transferKey)}`

    connectionState.value = 'connecting'
    ws = new WebSocket(url)

    ws.onopen = () => {
      connectionState.value = 'connected'
      reconnectDelay = 1000
      startHeartbeat()
    }

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data)
        // 心跳响应
        if (msg.type === 'pong') {
          resetPongTimer()
          return
        }
        // 分发消息到注册的回调
        const type = msg.type || '*'
        const handlers = listeners.get(type) || []
        handlers.forEach((fn) => fn(msg))
        // 通配符监听
        const wildcardHandlers = listeners.get('*') || []
        wildcardHandlers.forEach((fn) => fn(msg))
      } catch {
        // 非 JSON 消息忽略
      }
    }

    ws.onclose = () => {
      connectionState.value = 'disconnected'
      stopHeartbeat()
      scheduleReconnect()
    }

    ws.onerror = () => {
      // onclose 会随后触发，这里不重复处理
    }
  }

  /** 断开连接 */
  function disconnect() {
    clearReconnect()
    stopHeartbeat()
    if (ws) {
      ws.onclose = null
      ws.onerror = null
      ws.close()
      ws = null
    }
    connectionState.value = 'disconnected'
  }

  /** 发送消息 */
  function send(data) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data))
    }
  }

  /** 注册消息监听 */
  function onMessage(type, callback) {
    if (!listeners.has(type)) {
      listeners.set(type, [])
    }
    listeners.get(type).push(callback)
  }

  /** 移除消息监听 */
  function offMessage(type, callback) {
    if (!listeners.has(type)) return
    const arr = listeners.get(type)
    const idx = arr.indexOf(callback)
    if (idx !== -1) arr.splice(idx, 1)
  }

  // ---- 心跳 ----

  function startHeartbeat() {
    stopHeartbeat()
    pingTimer = setInterval(() => {
      send({ type: 'ping' })
      // 设置 pong 超时
      pongTimer = setTimeout(() => {
        // 60s 无 pong, 重连
        if (ws) {
          ws.close()
        }
      }, PONG_TIMEOUT)
    }, PING_INTERVAL)
  }

  function stopHeartbeat() {
    if (pingTimer) {
      clearInterval(pingTimer)
      pingTimer = null
    }
    if (pongTimer) {
      clearTimeout(pongTimer)
      pongTimer = null
    }
  }

  function resetPongTimer() {
    if (pongTimer) {
      clearTimeout(pongTimer)
      pongTimer = null
    }
  }

  // ---- 重连 ----

  function scheduleReconnect() {
    clearReconnect()
    connectionState.value = 'reconnecting'
    reconnectTimer = setTimeout(() => {
      connect()
      reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
    }, reconnectDelay)
  }

  function clearReconnect() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
  }

  onUnmounted(() => {
    disconnect()
  })

  return {
    send,
    onMessage,
    offMessage,
    connectionState,
    connect,
    disconnect,
  }
}
