/**
 * 服务器监控模块 — WebSocket 客户端
 * 独立连接 /ws/monitor（与原有设备 WS 完全解耦）。
 * 支持自动重连、心跳、消息分发（按 type 注册回调）。
 */
import { ref } from 'vue'

const connectionState = ref('disconnected') // connecting | connected | disconnected | reconnecting
const listeners = new Map()
let ws = null
let reconnectTimer = null
let reconnectDelay = 1000
let heartbeatTimer = null
let closedByUser = false
const MAX_DELAY = 30000

function emit(type, msg) {
  const arr = listeners.get(type) || []
  arr.forEach((fn) => fn(msg))
  const wild = listeners.get('*') || []
  wild.forEach((fn) => fn(msg))
}

export function useMonitorWs() {
  function connect() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return
    const deviceUuid = localStorage.getItem('deviceUuid')
    const transferKey = localStorage.getItem('transferKey')
    if (!deviceUuid || !transferKey) {
      console.warn('[MonitorWS] 缺少设备凭证，暂不连接')
      return
    }
    closedByUser = false
    connectionState.value = 'connecting'
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const url = `${proto}//${window.location.host}/ws/monitor?deviceUuid=${encodeURIComponent(deviceUuid)}&transferKey=${encodeURIComponent(transferKey)}`
    ws = new WebSocket(url)

    ws.onopen = () => {
      connectionState.value = 'connected'
      reconnectDelay = 1000
      startHeartbeat()
      emit('open', {})
    }
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data)
        emit(msg.type, msg.payload)
      } catch (_) {}
    }
    ws.onclose = () => {
      connectionState.value = 'disconnected'
      stopHeartbeat()
      if (!closedByUser) scheduleReconnect()
    }
    ws.onerror = () => { /* close 会随后触发 */ }
  }

  function startHeartbeat() {
    stopHeartbeat()
    heartbeatTimer = setInterval(() => {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'ping' }))
    }, 30000)
  }
  function stopHeartbeat() {
    if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null }
  }

  function scheduleReconnect() {
    connectionState.value = 'reconnecting'
    reconnectTimer = setTimeout(() => {
      reconnectDelay = Math.min(reconnectDelay * 2, MAX_DELAY)
      connect()
    }, reconnectDelay)
  }

  function disconnect() {
    closedByUser = true
    if (reconnectTimer) clearTimeout(reconnectTimer)
    stopHeartbeat()
    if (ws) { ws.onclose = null; ws.close(); ws = null }
    connectionState.value = 'disconnected'
  }

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj))
  }

  function onMessage(type, cb) {
    if (!listeners.has(type)) listeners.set(type, [])
    listeners.get(type).push(cb)
    return () => {
      const arr = listeners.get(type)
      if (arr) { const i = arr.indexOf(cb); if (i >= 0) arr.splice(i, 1) }
    }
  }
  function offMessage(type, cb) {
    const arr = listeners.get(type)
    if (arr) { const i = arr.indexOf(cb); if (i >= 0) arr.splice(i, 1) }
  }

  return { connect, disconnect, send, onMessage, offMessage, connectionState }
}
