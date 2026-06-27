import { defineStore } from 'pinia'
import chatApi from '../api/chat'

/**
 * 对话状态 Store — 管理对话列表、消息、流式输出
 */
export const useChatStore = defineStore('chat', {
  state: () => ({
    /** 对话列表 */
    conversations: [],
    /** 当前选中对话 ID */
    activeConversationId: null,
    /** 当前对话的消息列表 */
    messages: [],
    /** 是否正在流式输出 */
    streaming: false,
    /** 流式输出的当前累积内容 */
    streamingContent: '',
    /** 当前选中的模型 */
    selectedModel: 'openai:gpt-4o',
    /** 错误信息 */
    error: null,
    /** 流式请求的 abort 控制 */
    _abortController: null,
  }),

  getters: {
    /** 当前活跃的对话对象 */
    activeConversation: (state) => {
      if (!state.activeConversationId) return null
      return state.conversations.find((c) => c.id === state.activeConversationId) || null
    },

    /** 按更新时间倒序排列的对话列表 */
    sortedConversations: (state) => {
      return [...state.conversations].sort((a, b) => {
        const da = new Date(a.updatedAt || a.createdAt || 0).getTime()
        const db = new Date(b.updatedAt || b.createdAt || 0).getTime()
        return db - da
      })
    },
  },

  actions: {
    /** 获取对话列表 */
    async fetchConversations() {
      this.error = null
      try {
        const data = await chatApi.getConversations()
        this.conversations = Array.isArray(data) ? data : []
        return this.conversations
      } catch (err) {
        this.error = err.message
        throw err
      }
    },

    /** 选择对话并加载消息 */
    async selectConversation(convId) {
      this.activeConversationId = convId
      this.error = null
      try {
        const data = await chatApi.getMessages(convId)
        this.messages = Array.isArray(data) ? data : []
        return this.messages
      } catch (err) {
        this.error = err.message
        throw err
      }
    },

    /** 创建新对话（在列表中插入空对话项，实际创建由 sendMessage 触发） */
    async createConversation() {
      const tempConv = {
        id: `temp_${Date.now()}`,
        title: '新对话',
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      }
      this.conversations.unshift(tempConv)
      this.activeConversationId = tempConv.id
      this.messages = []
      this.streamingContent = ''
      return tempConv
    },

    /** 删除对话 */
    async deleteConversation(convId) {
      this.error = null
      try {
        await chatApi.deleteConversation(convId)
        this.conversations = this.conversations.filter((c) => c.id !== convId)
        if (this.activeConversationId === convId) {
          this.activeConversationId = null
          this.messages = []
          this.streamingContent = ''
        }
      } catch (err) {
        this.error = err.message
        throw err
      }
    },

    /**
     * 发送消息 — 使用 SSE 流式响应
     *
     * @param {string} convId  对话 ID
     * @param {string} content 消息内容
     * @param {string} model   模型 ID
     * @param {Function} onToken 每个 token 的回调
     * @param {Function} onDone  完成回调
     * @param {Function} onError 错误回调
     */
    async sendMessage(convId, content, model, { onToken, onDone, onError } = {}) {
      this.error = null
      this.streaming = true
      this.streamingContent = ''

      // 添加用户消息到列表
      const userMsg = {
        id: `user_${Date.now()}`,
        role: 'user',
        content,
        createdAt: new Date().toISOString(),
      }
      this.messages.push(userMsg)

      // 添加空的 AI 消息占位
      const aiMsgId = `ai_${Date.now()}`
      const aiMsg = {
        id: aiMsgId,
        role: 'assistant',
        content: '',
        createdAt: new Date().toISOString(),
        streaming: true,
      }
      this.messages.push(aiMsg)

      const isTempConv = String(convId).startsWith('temp_')

      try {
        const { abort, stream } = await chatApi.sendMessage(convId, content, model)
        this._abortController = { abort }

        const reader = stream.getReader()
        const decoder = new TextDecoder()
        let buffer = ''

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })

          // 解析 SSE 格式: "data: {...}\n\n"
          const lines = buffer.split('\n')
          buffer = lines.pop() || ''

          for (const line of lines) {
            if (line.startsWith('data: ')) {
              const payload = line.slice(6).trim()
              if (payload === '[DONE]') {
                // 流结束
                this.finishStream(aiMsgId)
                if (onDone) onDone()
                return
              }
              let parsed
              try {
                parsed = JSON.parse(payload)
                if (parsed.type === 'conversation_created') {
                  // 服务端创建了真实对话 → 替换临时对话
                  this._replaceTempConversation(convId, parsed.conversationId)
                  convId = parsed.conversationId
                  continue
                }
                if (parsed.type === 'error') {
                  throw new Error(parsed.error || '流式响应错误')
                }
                // 提取 token
                const token = parsed.token || parsed.content || ''
                if (token) {
                  this.appendStreamToken(aiMsgId, token)
                  if (onToken) onToken(token)
                }
              } catch (parseErr) {
                // 如果是错误类型 payload 但 JSON 解析失败，直接抛出
                if (payload.includes('"type":"error"') || payload.includes("'type':'error'")) {
                  throw new Error('SSE 流错误')
                }
                // JSON 不完整（跨 TCP 分片），放回 buffer
                buffer = line + '\n' + buffer
              }
            }
          }
        }

        // reader 结束时未收到 [DONE]
        this.finishStream(aiMsgId)
        if (onDone) onDone()
      } catch (err) {
        if (err.name === 'AbortError') {
          // 用户主动取消
          this.finishStream(aiMsgId)
          return
        }
        this.streaming = false
        // 更新 AI 消息为错误状态
        const msg = this.messages.find((m) => m.id === aiMsgId)
        if (msg) {
          msg.content = this.streamingContent || '（请求失败）'
          msg.streaming = false
          msg.error = true
        }
        this.error = err.message
        if (onError) onError(err)
      }
    },

    /** 取消流式输出 */
    cancelStream() {
      if (this._abortController) {
        this._abortController.abort()
        this._abortController = null
      }
      this.streaming = false
    },

    /** 追加流式 token 到 AI 消息 */
    appendStreamToken(msgId, token) {
      this.streamingContent += token
      const msg = this.messages.find((m) => m.id === msgId)
      if (msg) {
        msg.content = this.streamingContent
      }
    },

    /** 完成流式输出 */
    finishStream(msgId) {
      this.streaming = false
      this._abortController = null
      const msg = this.messages.find((m) => m.id === msgId)
      if (msg) {
        msg.content = this.streamingContent
        msg.streaming = false
      }
      this.streamingContent = ''
    },

    /** 用服务端返回的真实 ID 替换临时对话 */
    _replaceTempConversation(tempId, realId) {
      const tempConv = this.conversations.find((c) => String(c.id) === String(tempId))
      if (tempConv) {
        tempConv.id = realId
        this.activeConversationId = realId
      }
    },

    /** 设置当前模型 */
    setModel(modelId) {
      this.selectedModel = modelId
    },
  },
})
