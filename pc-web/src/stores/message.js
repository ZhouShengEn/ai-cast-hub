import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

export const useMessageStore = defineStore('message', () => {
  const messages = ref([])
  const isConnected = ref(false)
  const isConnecting = ref(false)
  const error = ref(null)
  const roomId = ref(null)
  const targetDeviceId = ref(null)
  /** 当前是否在消息页面（用于决定是否计入未读） */
  const isViewing = ref(false)

  /** 外部注册的标记所有已读回调（用于通过 DC 通知 App） */
  let _onMarkAllReadCallback = null
  function onMarkAllRead(fn) {
    _onMarkAllReadCallback = fn
  }

  /** 未读消息数 */
  const unreadCount = computed(() => {
    return messages.value.filter(m => !m.isFromMe && m.readStatus !== 'read').length
  })

  function addMessage(msg) {
    messages.value.push(msg)
  }

  function updateMessage(id, updates) {
    const idx = messages.value.findIndex((m) => m.id === id)
    if (idx >= 0) {
      messages.value[idx] = { ...messages.value[idx], ...updates }
    }
  }

  /** 标记某条消息为已读 */
  function markAsRead(msgId) {
    const idx = messages.value.findIndex((m) => m.id === msgId)
    if (idx >= 0) {
      messages.value[idx] = { ...messages.value[idx], readStatus: 'read' }
    }
  }

  /**
   * 标记消息为已读
   * @param {'incoming'|'outgoing'} direction - 'incoming': PC查看App发来的消息（进入消息页时调用）
   *   'outgoing': App已读PC发出的消息（收到read_all时调用）
   */
  function markAllAsRead(direction = 'incoming') {
    messages.value = messages.value.map((m) => {
      const target = direction === 'outgoing' ? m.isFromMe : !m.isFromMe
      if (target && m.readStatus !== 'read') {
        return { ...m, readStatus: 'read' }
      }
      return m
    })
    // 仅当 PC 主动查看时，才通过 DC 通知 App
    if (direction === 'incoming' && _onMarkAllReadCallback) {
      _onMarkAllReadCallback()
    }
  }

  /** 设置是否在查看消息页 */
  function setViewing(val) {
    isViewing.value = val
    if (val) {
      markAllAsRead('incoming')
    }
  }

  function removeMessage(id) {
    messages.value = messages.value.filter((m) => m.id !== id)
  }

  function setConnected(val) {
    isConnected.value = val
    isConnecting.value = false
  }

  function cleanup() {
    messages.value = []
    isConnected.value = false
    isConnecting.value = false
    error.value = null
    roomId.value = null
    targetDeviceId.value = null
    _onMarkAllReadCallback = null
  }

  return {
    messages, isConnected, isConnecting, error, roomId, targetDeviceId,
    unreadCount, isViewing,
    addMessage, updateMessage, markAsRead, markAllAsRead, setViewing, onMarkAllRead,
    removeMessage, setConnected, cleanup,
  }
})
