import { ref, watch } from 'vue'
import { useWebSocket } from './useWebSocket'
import { useDeviceStore } from '../stores/device'

/**
 * 设备防盗 Composable（单例）
 *
 * 向已配对手机下发防盗指令，并接收手机回传的坐标与执行回执。
 * 配对校验由服务端完成：未配对的设备无法下发任何指令。
 */

let _instance = null

export function useAntiTheft() {
  if (_instance) return _instance

  const { send, onMessage } = useWebSocket()
  const deviceStore = useDeviceStore()

  /** 手机最近一次上报的坐标 */
  const latestLocation = ref(null)
  /** 手机最近一次执行回执 */
  const lastAck = ref(null)
  /** 是否正在请求位置共享 */
  const tracking = ref(false)
  /** 是否已对本次上线自动请求过一次定位（避免重连抖动下重复请求） */
  let _autoRequested = false

  onMessage('device_location_update', (msg) => {
    latestLocation.value = {
      ...(msg.payload || {}),
      fromDeviceUuid: msg.fromDeviceUuid,
      receivedAt: Date.now(),
    }
  })

  onMessage('anti_theft_ack', (msg) => {
    lastAck.value = {
      ...(msg.payload || {}),
      fromDeviceUuid: msg.fromDeviceUuid,
    }
    // 手机端确认停止共享后，同步本地开关状态
    const action = msg.payload?.action
    if (action === 'stop_location_track') tracking.value = false
    if (action === 'start_location_track') tracking.value = true
  })

  // App 重新上线/重连（device_rebind）时主动再要一次定位：
  // 防止自动上报那一次因后台取位置失败而永久不展示（只进消息界面才出现）。
  onMessage('device_rebind', () => {
    const d = deviceStore.pairedDevices[0]
    const uuid = d?.uuid || d?.deviceUuid
    if (uuid) requestLocation()
  })

  /**
   * 手机（配对设备）上线即主动请求一次定位：
   * 满足「App 连接 Web 端后自动上报一次定位信息」的可视效果——Web 首页立即可见坐标，
   * 且坐标常驻展示（不再被 startTracking 清零）。
   */
  watch(
    () => {
      const d = deviceStore.pairedDevices[0]
      return d?.uuid || d?.deviceUuid || null
    },
    (uuid) => {
      // 已配对即主动请求一次定位：不再等 isOnline 时序（isOnline 推送偶发漏触发
      // 会导致「必须进消息界面收条指令才展示」）。配对关系本身即代表两端就绪。
      if (uuid && !_autoRequested) {
        _autoRequested = true
        requestLocation()
      }
      // 配对解除后允许下次重新配对再请求
      if (!uuid) _autoRequested = false
    },
    { immediate: true },
  )

  /**
   * 下发防盗指令
   * @param {string} targetDeviceUuid - 目标手机 UUID（必须已配对）
   * @param {'start_alarm'|'stop_alarm'|'start_location_track'|'stop_location_track'|'lock_device'|'unlock_device'} action
   */
  function command(targetDeviceUuid, action) {
    if (!targetDeviceUuid) return
    send({
      type: 'anti_theft_command',
      targetDeviceUuid,
      payload: { action },
    })
  }

  function startAlarm(uuid) {
    command(uuid, 'start_alarm')
  }

  function stopAlarm(uuid) {
    command(uuid, 'stop_alarm')
  }

  function startTracking(uuid) {
    tracking.value = true
    // 注意：不再清零 latestLocation——坐标需常驻展示，直到用户手动「清除」。
    // 清零会导致「开始定位」后原有坐标一闪消失，与「定位展示一直不消除」需求冲突。
    command(uuid, 'start_location_track')
  }

  function stopTracking(uuid) {
    tracking.value = false
    command(uuid, 'stop_location_track')
  }

  /**
   * 主动向手机请求一次当前坐标（P2-2）。
   * 与「开始定位」(持续共享) 的区别：请求一次即返回，不维持后台定时上报；
   * 即便未开启实时共享，也能立即拿到手机此刻的位置。
   */
  function requestLocation() {
    const d = deviceStore.pairedDevices[0]
    const uuid = d?.uuid || d?.deviceUuid
    if (!uuid) return
    command(uuid, 'request_location')
  }

  /** 清除面板展示的最后一次坐标（P2-2：解决旧坐标一直残留不清除的问题） */
  function clearLocation() {
    latestLocation.value = null
  }

  function lockDevice(uuid) {
    command(uuid, 'lock_device')
  }

  function unlockDevice(uuid) {
    command(uuid, 'unlock_device')
  }

  _instance = {
    latestLocation,
    lastAck,
    tracking,
    command,
    startAlarm,
    stopAlarm,
    startTracking,
    stopTracking,
    requestLocation,
    clearLocation,
    lockDevice,
    unlockDevice,
  }
  return _instance
}
