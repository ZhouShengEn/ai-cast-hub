/**
 * 服务器监控模块 — 全局状态管理（Pinia）
 *
 * 通过 WebSocket 实时接收快照 / 增量更新 / 日志 / 告警，
 * 并封装所有运维动作（REST 调用 + WS 日志流）。
 * 页面只读取本 store，不直接请求接口，保证统一实时刷新。
 */
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { monitorApi } from '../api/monitor'
import { useMonitorWs } from '../composables/useMonitorWs'

export const useMonitorStore = defineStore('monitor', () => {
  const connected = ref(false)
  const role = ref('readonly')
  const services = ref([])
  const external = ref([])
  const nginxLinks = ref([])
  const system = ref({})
  const config = ref({})
  const alerts = ref([])
  const logs = ref({}) // id -> [{line, level}]
  const loading = ref(false)

  const stats = computed(() => {
    const s = services.value
    const running = s.filter((x) => x.running).length
    const stopped = s.filter((x) => !x.running && x.status !== 'error').length
    const error = s.filter((x) => x.status === 'error' || (x.running && x.nginxLink && x.portLocked && false)).length
    return { total: s.length, running, stopped, error: s.length - running - stopped < 0 ? 0 : s.length - running - stopped }
  })

  const ws = useMonitorWs()
  let registered = false

  function pushAlert(a) {
    alerts.value.unshift({ ...a, id: Date.now() + Math.random(), time: new Date().toISOString() })
    if (alerts.value.length > 60) alerts.value = alerts.value.slice(0, 60)
  }
  function dismissAlert(id) {
    alerts.value = alerts.value.filter((a) => a.id !== id)
  }

  function applySnapshot(payload) {
    services.value = payload.services || []
    external.value = payload.external || []
    nginxLinks.value = payload.nginxLinks || []
    if (payload.system) system.value = payload.system
    if (payload.config) config.value = payload.config
    connected.value = true
  }

  function registerWs() {
    if (registered) return
    registered = true
    ws.onMessage('auth', (p) => { role.value = p.role; connected.value = true })
    ws.onMessage('snapshot', (p) => applySnapshot(p))
    ws.onMessage('services_update', (p) => { services.value = p.services || []; connected.value = true })
    ws.onMessage('system_update', (p) => { system.value = p.system })
    ws.onMessage('nginx_links_update', (p) => { nginxLinks.value = p.nginxLinks || [] })
    ws.onMessage('alert', (p) => pushAlert(p))
    ws.onMessage('log_line', (p) => {
      const arr = logs.value[p.projectId] || []
      arr.push({ line: p.line, level: p.level || 'INFO' })
      if (arr.length > 2000) arr.splice(0, arr.length - 2000)
      logs.value[p.projectId] = arr
    })
    ws.onMessage('log_history', (p) => {
      const lines = (p.content || '').split('\n').filter(Boolean).map((l) => ({ line: l, level: 'INFO' }))
      logs.value[p.projectId] = lines.slice(-2000)
    })
  }

  function connect() {
    registerWs()
    ws.connect()
  }
  function disconnect() {
    ws.disconnect()
    connected.value = false
  }

  function subscribeLog(id) { ws.send({ type: 'subscribe_log', payload: { id } }) }
  function unsubscribeLog() { ws.send({ type: 'unsubscribe_log' }) }
  function clearLogs(id) { logs.value[id] = [] }

  // ---- REST 兜底刷新 ----
  async function refreshAll() {
    loading.value = true
    try {
      const [svc, ext, links, sys] = await Promise.all([
        monitorApi.getServices(),
        monitorApi.getExternal(),
        monitorApi.nginxLinks(),
        monitorApi.getSystem().catch(() => ({})),
      ])
      services.value = svc
      external.value = ext
      nginxLinks.value = links
      if (sys && sys.cpuUsagePercent !== undefined) system.value = sys
    } catch (e) {
      pushAlert({ level: 'error', kind: 'fetch', message: '刷新失败: ' + (e.message || '') })
    } finally {
      loading.value = false
    }
  }

  async function getConfig() { config.value = await monitorApi.getConfig() }
  async function updateConfig(patch) {
    config.value = await monitorApi.updateConfig(patch)
    return config.value
  }
  async function addIgnore(path) { return monitorApi.addIgnore(path) }
  async function removeIgnore(path) { return monitorApi.removeIgnore(path) }

  async function start(id) { return monitorApi.startService(id) }
  async function stop(id) { return monitorApi.stopService(id) }
  async function restart(id) { return monitorApi.restartService(id) }
  async function build(id) { return monitorApi.buildService(id) }
  async function pull(id, rebase) { return monitorApi.pullGit(id, rebase) }
  async function setPort(id, port) { return monitorApi.setPort(id, port) }
  async function setEnv(id, env) { return monitorApi.setEnv(id, env) }
  async function setScript(id, payload) { return monitorApi.setScript(id, payload) }
  async function setDisplayName(id, name) { return monitorApi.setDisplayName(id, name) }

  async function scan() { return monitorApi.scan() }

  return {
    connected, role, services, external, nginxLinks, system, config, alerts, logs, loading, stats,
    connect, disconnect, subscribeLog, unsubscribeLog, clearLogs, refreshAll,
    getConfig, updateConfig, addIgnore, removeIgnore,
    start, stop, restart, build, pull, setPort, setEnv, setScript, setDisplayName, scan,
    pushAlert, dismissAlert,
  }
})
