import { ref } from 'vue'

/**
 * WebSocket 全局单例管理
 *
 * 连接在 App.vue 层建立，整个应用生命周期保持。
 * 各视图通过 onMessage/offMessage 注册监听，不管理连接。
 */

// ---- 单例状态（模块级，所有调用共享） ----
let ws = null
let pingTimer = null
let pongTimer = null
let reconnectTimer = null
let reconnectDelay = 1000
const MAX_RECONNECT_DELAY = 30000
const PING_INTERVAL = 30000
const PONG_TIMEOUT = 60000
const listeners = new Map()

/** 连接状态: 'connecting' | 'connected' | 'disconnected' | 'reconnecting' */
const connectionState = ref('disconnected')

/** 是否已初始化（防止重复连接） */
let initialized = false

/** 建立 WebSocket 连接 */
function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return
  }

  const deviceUuid = localStorage.getItem('deviceUuid') || ''
  const transferKey = localStorage.getItem('transferKey') || ''
  if (!deviceUuid || !transferKey) {
    console.warn('[WS] 缺少 deviceUuid 或 transferKey，暂不连接')
    return
  }

  const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  const url = `${wsProtocol}//${window.location.host}/ws?deviceUuid=${encodeURIComponent(deviceUuid)}&transferKey=${encodeURIComponent(transferKey)}`

  connectionState.value = 'connecting'
  ws = new WebSocket(url)

  ws.onopen = () => {
    connectionState.value = 'connected'
    reconnectDelay = 1000
    startHeartbeat()
    console.log('[WS] 连接已建立')
  }

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data)
      if (msg.type === 'pong') {
        resetPongTimer()
        return
      }
      // 分发消息到注册的回调
      const type = msg.type || '*'
      const handlers = listeners.get(type) || []
      handlers.forEach((fn) => fn(msg))
      const wildcardHandlers = listeners.get('*') || []
      wildcardHandlers.forEach((fn) => fn(msg))
    } catch {
      // 非 JSON 消息忽略
    }
  }

  ws.onclose = (event) => {
    connectionState.value = 'disconnected'
    stopHeartbeat()
    // 认证失败（4000-4003）不重连
    if (event.code >= 4000 && event.code <= 4003) {
      console.warn('[WS] 认证失败，停止重连:', event.code, event.reason)
      return
    }
    scheduleReconnect()
  }

  ws.onerror = () => {
    // onclose 会随后触发
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
    pongTimer = setTimeout(() => {
      if (ws) ws.close()
    }, PONG_TIMEOUT)
  }, PING_INTERVAL)
}

function stopHeartbeat() {
  if (pingTimer) { clearInterval(pingTimer); pingTimer = null }
  if (pongTimer) { clearTimeout(pongTimer); pongTimer = null }
}

function resetPongTimer() {
  if (pongTimer) { clearTimeout(pongTimer); pongTimer = null }
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
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null }
}

/**
 * useWebSocket Composable
 * 返回全局共享的 WS 实例方法
 */
export function useWebSocket() {
  return {
    send,
    onMessage,
    offMessage,
    connectionState,
    connect,
    disconnect,
  }
}
