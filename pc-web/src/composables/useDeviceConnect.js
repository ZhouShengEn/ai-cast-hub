import { computed, inject } from 'vue'
import { useMessageStore } from '../stores/message'
import { useDeviceStore } from '../stores/device'
import { useMessageTransfer } from './useMessageTransfer'

/**
 * 全局连接锁：同一时刻只允许一个「主动连接」流程在跑。
 *
 * 多个页面/按钮都可能触发连接，若不做互斥会并发 createRoom，
 * 旧房间与新房间的信令互相覆盖，表现为连接状态乱跳、点了没反应。
 */
let _connecting = false

/**
 * 统一的「主动连接 App 端」入口
 *
 * 背景：此前各页面的连接按钮各自实现一套（有的只调 createRoom、有的先清 error），
 * 状态判断不一致；加上错误状态锁死、isConnecting 卡住后按钮被 v-if 直接隐藏，
 * 于是多处按钮点击后「毫无反应」且无法重试。
 *
 * 现在所有页面的连接按钮统一调用 [startConnectDevice]，保证：
 *   1. 未连接才可点，连接中/已连接置灰禁用（不再隐藏，状态始终可见）
 *   2. 点击时强制重置旧错误状态、销毁旧 PeerConnection/DataChannel/房间
 *   3. 每一步都打日志，并通过 toast 给用户可见反馈
 *   4. 异常统一捕获并弹 toast
 */
export function useDeviceConnect() {
  const messageStore = useMessageStore()
  const deviceStore = useDeviceStore()
  const { createRoom, disconnect } = useMessageTransfer()
  // 未显式传入 showToast 时，回退到 App.vue provide 的全局 toast
  const globalToast = inject('showToast', null)

  const pairedDevices = computed(() => deviceStore.pairedDevices || [])

  /** 按钮是否可点击：仅「未连接 且 未在连接中 且 有已配对设备」才可点 */
  const canConnect = computed(
    () =>
      !messageStore.isConnected &&
      !messageStore.isConnecting &&
      pairedDevices.value.length > 0,
  )

  /** 按钮文案：已连接 / 连接中 / 主动连接 */
  const connectButtonText = computed(() => {
    if (messageStore.isConnected) return '已连接'
    if (messageStore.isConnecting) return '连接中...'
    return '主动连接 App 端'
  })

  /**
   * 发起一次完整的设备连接：建房间 → 等 App 加入 → 建 WebRTC → 等 DataChannel 打开
   *
   * @param {object}   [options]
   * @param {Function} [options.showToast] 自定义 toast，缺省用全局 provide 的
   * @param {string}   [options.deviceUuid] 指定设备，缺省取第一个已配对设备
   * @param {boolean}  [options.force]      true 时忽略「已连接/连接中」守卫，强制重连
   * @returns {Promise<boolean>} 是否成功启动连接流程
   */
  async function startConnectDevice(options = {}) {
    const toast = options.showToast || globalToast || (() => {})

    // ---- 1. 状态守卫 ----
    if (messageStore.isConnected && !options.force) {
      console.log('[DeviceConnect] 已连接，忽略重复点击')
      toast('已与 App 端连接，无需重复连接', 'info')
      return false
    }
    if ((_connecting || messageStore.isConnecting) && !options.force) {
      console.log('[DeviceConnect] 连接流程进行中，忽略重复点击')
      toast('正在连接中，请稍候', 'info')
      return false
    }

    // ---- 2. 目标设备 ----
    const targetUuid = options.deviceUuid || pairedDevices.value[0]?.deviceUuid
    if (!targetUuid) {
      console.warn('[DeviceConnect] 没有已配对设备，无法连接')
      toast('还没有配对的设备，请先在首页配对手机', 'warning')
      return false
    }

    _connecting = true
    try {
      // ---- 3. 强制重置：清错误态 + 销毁旧 PeerConnection/DataChannel/房间 ----
      // 旧错误状态若不重置，后续流程会在开头就 return，表现同样是「点了没反应」。
      console.log('[DeviceConnect] 重置旧状态并清理残留连接')
      messageStore.error = null
      messageStore.isConnecting = false
      disconnect()

      toast('开始发起设备连接...', 'info')
      messageStore.isConnecting = true

      // ---- 4. 走完整流程 ----
      console.log('[DeviceConnect] 创建房间，目标设备:', targetUuid)
      await createRoom(targetUuid)
      console.log('[DeviceConnect] 信令流程完成，等待 DataChannel 打开')
      return true
    } catch (e) {
      console.error('[DeviceConnect] 连接失败:', e)
      messageStore.isConnecting = false
      messageStore.error = e?.message || '连接失败，请重试'
      toast(`连接失败：${messageStore.error}`, 'error')
      return false
    } finally {
      _connecting = false
    }
  }

  /** 主动断开连接（供「断开」按钮统一调用） */
  function stopConnectDevice() {
    console.log('[DeviceConnect] 主动断开连接')
    messageStore.error = null
    disconnect()
  }

  return {
    startConnectDevice,
    stopConnectDevice,
    canConnect,
    connectButtonText,
    pairedDevices,
  }
}
