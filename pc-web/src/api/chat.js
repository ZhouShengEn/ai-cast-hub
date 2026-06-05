import client from './client'

/**
 * 对话 API — 对话列表、消息、SSE 流式发送
 */
export default {
  /** 获取对话列表 */
  async getConversations() {
    return client.get('/chat/conversations', { params: { limit: 50 } })
  },

  /** 获取某个对话的消息列表 */
  async getMessages(convId) {
    return client.get(`/chat/conversation/${convId}/messages`)
  },

  /** 删除对话 */
  async deleteConversation(convId) {
    return client.delete(`/chat/conversation/${convId}`)
  },

  /**
   * 发送消息 — 返回 SSE ReadableStream
   *
   * 使用 fetch + ReadableStream 读取 SSE 流式响应，
   * 不使用 axios（axios 不支持流式解析）。
   *
   * @param {string} convId  对话 ID
   * @param {string} content 消息内容
   * @param {string} model   模型 ID，如 'openai:gpt-4o'
   * @returns {Promise<{ abort: Function, stream: ReadableStream }>}
   */
  async sendMessage(convId, content, model) {
    const deviceUuid = localStorage.getItem('deviceUuid') || ''
    const transferKey = localStorage.getItem('transferKey') || ''

    const controller = new AbortController()

    const response = await fetch('/api/v1/chat/send', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Device-UUID': deviceUuid,
        'X-Transfer-Key': transferKey,
      },
      body: JSON.stringify({ conversationId: convId, content, model }),
      signal: controller.signal,
    })

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new Error(text || `HTTP ${response.status}`)
    }

    return {
      abort: () => controller.abort(),
      stream: response.body,
    }
  },
}
