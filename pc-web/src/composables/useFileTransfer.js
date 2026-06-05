import { ref } from 'vue'
import { useFileStore } from '../stores/file'

/**
 * 文件传输接收 Composable
 *
 * 通过 DataChannel 接收分片文件数据，支持进度、
 * 内存缓冲（Blob 降级）和 SHA-256 校验。
 *
 * @returns {{ startReceiving, onProgress, onComplete, onError, progress, isReceiving }}
 */
export function useFileTransfer() {
  const fileStore = useFileStore()
  const progress = ref(0)
  const isReceiving = ref(false)

  let _onProgress = null
  let _onComplete = null
  let _onError = null
  let chunks = []
  let transferMeta = null
  let receivedCount = 0

  /**
   * 开始接收文件
   * @param {object} meta - { id, fileName, fileSize, totalChunks, checksum }
   */
  function startReceiving(meta) {
    transferMeta = {
      id: meta.id || `transfer_${Date.now()}`,
      fileName: meta.fileName || 'unknown',
      fileSize: meta.fileSize || 0,
      totalChunks: meta.totalChunks || 0,
      checksum: meta.checksum || null,
    }
    chunks = new Array(transferMeta.totalChunks)
    receivedCount = 0
    progress.value = 0
    isReceiving.value = true

    const item = fileStore.addTransfer({
      ...transferMeta,
      status: 'transferring',
    })
    return item
  }

  /**
   * 处理接收到的数据分片
   * @param {object} header - { type, seq, total }
   * @param {ArrayBuffer} data
   */
  function handleChunk(header, data) {
    if (!transferMeta || !isReceiving.value) return

    const { seq, total } = header
    if (total && total !== transferMeta.totalChunks) {
      transferMeta.totalChunks = total
    }

    if (!chunks[seq]) {
      chunks[seq] = data
      receivedCount++
    }

    const pct =
      transferMeta.totalChunks > 0
        ? Math.min(100, Math.round((receivedCount / transferMeta.totalChunks) * 100))
        : 0
    progress.value = pct
    fileStore.updateTransferProgress(transferMeta.id, {
      receivedChunks: receivedCount,
      totalChunks: transferMeta.totalChunks,
    })

    if (_onProgress) _onProgress(pct)

    // 检查是否完成
    if (receivedCount >= transferMeta.totalChunks) {
      finishReceiving()
    }
  }

  /** 完成接收，拼装 Blob */
  async function finishReceiving() {
    isReceiving.value = false
    progress.value = 100

    try {
      // 拼装所有分片
      const totalSize = chunks.reduce((sum, c) => sum + (c ? c.byteLength : 0), 0)
      const merged = new Uint8Array(totalSize)
      let offset = 0
      for (let i = 0; i < chunks.length; i++) {
        if (chunks[i]) {
          merged.set(new Uint8Array(chunks[i]), offset)
          offset += chunks[i].byteLength
        }
      }

      // 校验 SHA-256（如果提供了）
      if (transferMeta.checksum) {
        const hashBuffer = await crypto.subtle.digest('SHA-256', merged)
        const hashArray = Array.from(new Uint8Array(hashBuffer))
        const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('')
        if (hashHex !== transferMeta.checksum) {
          throw new Error(`文件校验失败: 期望 ${transferMeta.checksum.slice(0, 8)}..., 实际 ${hashHex.slice(0, 8)}...`)
        }
      }

      const blob = new Blob([merged])
      fileStore.completeTransfer(transferMeta.id, blob)
      if (_onComplete) _onComplete(blob, transferMeta)
    } catch (err) {
      fileStore.updateTransferProgress(transferMeta.id, {
        receivedChunks,
        totalChunks: transferMeta.totalChunks,
      })
      const t = fileStore.transfers.find((x) => x.id === transferMeta.id)
      if (t) t.status = 'failed'
      if (_onError) _onError(err)
    }
  }

  /** 注册进度回调 */
  function onProgress(callback) {
    _onProgress = callback
  }

  /** 注册完成回调 */
  function onComplete(callback) {
    _onComplete = callback
  }

  /** 注册错误回调 */
  function onError(callback) {
    _onError = callback
  }

  return {
    startReceiving,
    handleChunk,
    onProgress,
    onComplete,
    onError,
    progress,
    isReceiving,
  }
}
