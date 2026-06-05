import { ref } from 'vue'

/**
 * SSE 流式响应 Composable
 *
 * 通过 fetch + ReadableStream 读取 SSE 格式数据。
 * 解析 "data: {...}\n\n" 并触发 token/done/error 回调。
 *
 * @returns {{ connect, abort, onToken, onDone, onError, isStreaming }}
 */
export function useSSE() {
  const isStreaming = ref(false)
  let abortController = null
  let _onToken = null
  let _onDone = null
  let _onError = null

  /**
   * 建立 SSE 连接
   *
   * @param {Request|string} url    - fetch URL 或 Request 对象
   * @param {object}         options - fetch 选项
   */
  async function connect(url, options = {}) {
    abortController = new AbortController()
    isStreaming.value = true

    try {
      const response = await fetch(url, {
        ...options,
        signal: abortController.signal,
        headers: {
          'Content-Type': 'application/json',
          'X-Device-UUID': localStorage.getItem('deviceUuid') || '',
          'X-Transfer-Key': localStorage.getItem('transferKey') || '',
          ...(options.headers || {}),
        },
      })

      if (!response.ok) {
        const text = await response.text().catch(() => '')
        throw new Error(text || `HTTP ${response.status}`)
      }

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })

        // 解析 SSE 格式
        const lines = buffer.split('\n')
        buffer = lines.pop() || ''

        for (const line of lines) {
          if (!line.startsWith('data: ')) continue

          const payload = line.slice(6).trim()

          // 流结束标记
          if (payload === '[DONE]') {
            isStreaming.value = false
            if (_onDone) _onDone()
            return
          }

          let parsed
          try {
            parsed = JSON.parse(payload)

            // 错误类型
            if (parsed.type === 'error') {
              const err = new Error(parsed.error || 'SSE 流错误')
              if (_onError) _onError(err)
              throw err
            }

            // token 内容
            const token = parsed.token || parsed.content || ''
            if (token && _onToken) {
              _onToken(token)
            }
          } catch (parseErr) {
            // JSON 不完整，放回 buffer
            if (parsed?.type !== 'error') {
              buffer = line + '\n' + buffer
            } else {
              throw parseErr
            }
          }
        }
      }

      // 流自然结束
      isStreaming.value = false
      if (_onDone) _onDone()
    } catch (err) {
      if (err.name === 'AbortError') {
        isStreaming.value = false
        return
      }
      isStreaming.value = false
      if (_onError) _onError(err)
      else throw err
    }
  }

  /** 取消 SSE 连接 */
  function abort() {
    if (abortController) {
      abortController.abort()
      abortController = null
    }
    isStreaming.value = false
  }

  /** 注册 token 回调 */
  function onToken(callback) {
    _onToken = callback
  }

  /** 注册完成回调 */
  function onDone(callback) {
    _onDone = callback
  }

  /** 注册错误回调 */
  function onError(callback) {
    _onError = callback
  }

  return {
    connect,
    abort,
    onToken,
    onDone,
    onError,
    isStreaming,
  }
}
