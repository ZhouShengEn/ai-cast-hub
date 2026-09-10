import { ref } from 'vue'
import { useWebSocket } from './useWebSocket'

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

  /** 手机最近一次上报的坐标 */
  const latestLocation = ref(null)
  /** 手机最近一次执行回执 */
  const lastAck = ref(null)
  /** 是否正在请求位置共享 */
  const tracking = ref(false)

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
    latestLocation.value = null
    command(uuid, 'start_location_track')
  }

  function stopTracking(uuid) {
    tracking.value = false
    command(uuid, 'stop_location_track')
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
    lockDevice,
    unlockDevice,
  }
  return _instance
}
