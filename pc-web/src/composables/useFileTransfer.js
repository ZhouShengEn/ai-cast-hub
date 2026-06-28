import { ref } from 'vue'
import { useFileStore } from '../stores/file'
import client from '../api/client.js'

/**
 * 文件传输接收 Composable
 *
 * 通过 DataChannel 接收分片文件数据，支持进度、
 * 内存缓冲（Blob 降级）和 SHA-256 校验。
 *
 * 支持断点续传：
 * - 每接收一个分片即向服务器报告，供发送方查询已收分片
 * - 连接中断后保留分片缓冲，重连后可继续接收
 * - 30 分钟无活动自动过期
 *
 * @returns {{ startReceiving, onProgress, onComplete, onError, progress, isReceiving, getReceivedChunks, markInterrupted, cleanup }}
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
  let _transferId = null
  let _transferTimeout = null

  /** 传输超时：30 分钟 */
  const TRANSFER_TIMEOUT_MS = 30 * 60 * 1000

  /**
   * 开始接收文件
   * @param {object} meta - { id, fileName, fileSize, totalChunks, checksum, transferId }
   */
  function startReceiving(meta) {
    // 如果已有正在进行中的传输，先清理
    if (transferMeta && isReceiving.value) {
      console.warn('[FileTransfer] 已有进行中的传输，先清理旧传输')
    }

    transferMeta = {
      id: meta.id || `transfer_${Date.now()}`,
      fileName: meta.fileName || 'unknown',
      fileSize: meta.fileSize || 0,
      totalChunks: meta.totalChunks || 0,
      checksum: meta.checksum || null,
    }
    _transferId = meta.transferId || null

    // 如果是断点续传（已有部分分片），复用现有缓冲
    if (meta.resume && chunks.length === transferMeta.totalChunks && receivedCount > 0) {
      // 保留已有分片，只更新元数据
      transferMeta.totalChunks = Math.max(transferMeta.totalChunks, chunks.length)
      // 确保缓冲数组大小匹配
      if (chunks.length < transferMeta.totalChunks) {
        const newChunks = new Array(transferMeta.totalChunks)
        for (let i = 0; i < chunks.length; i++) {
          newChunks[i] = chunks[i]
        }
        chunks = newChunks
      }
      console.log(`[FileTransfer] 断点续传: 已有 ${receivedCount}/${transferMeta.totalChunks} 分片`)
    } else if (!meta.resume || chunks.length === 0) {
      // 全新传输或缓冲已丢失，重新初始化
      chunks = new Array(transferMeta.totalChunks)
      receivedCount = 0
    }

    progress.value = transferMeta.totalChunks > 0
      ? Math.min(100, Math.round((receivedCount / transferMeta.totalChunks) * 100))
      : 0
    isReceiving.value = true

    const item = fileStore.addTransfer({
      ...transferMeta,
      status: 'transferring',
    })

    // 启动超时计时器
    _resetTransferTimeout()

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
      // 调整缓冲数组大小
      if (chunks.length < total) {
        const newChunks = new Array(total)
        for (let i = 0; i < chunks.length; i++) {
          newChunks[i] = chunks[i]
        }
        chunks = newChunks
      }
    }

    if (!chunks[seq]) {
      chunks[seq] = data
      receivedCount++
    }

    // 向服务器报告已接收分片（用于断点续传），fire-and-forget
    if (_transferId) {
      client.post(`/file/transfer/${_transferId}/chunk`, { chunkIndex: seq })
        .catch(() => { /* 静默失败，不影响传输 */ })
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

    // 活动重置超时计时器
    _resetTransferTimeout()

    // 检查是否完成
    if (receivedCount >= transferMeta.totalChunks) {
      finishReceiving()
    }
  }

  /** 完成接收，拼装 Blob */
  async function finishReceiving() {
    isReceiving.value = false
    progress.value = 100
    _clearTransferTimeout()

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

      // 清理
      chunks = []
      transferMeta = null
      receivedCount = 0
      _transferId = null
    } catch (err) {
      fileStore.updateTransferProgress(transferMeta.id, {
        receivedChunks: receivedCount,
        totalChunks: transferMeta.totalChunks,
        status: 'failed',
      })
      if (_onError) _onError(err)
    }
  }

  /**
   * 获取已接收的分片索引列表（用于断点续传查询）
   */
  function getReceivedChunks() {
    const received = []
    for (let i = 0; i < chunks.length; i++) {
      if (chunks[i]) received.push(i)
    }
    return received
  }

  /**
   * 标记传输中断（连接断开但保留缓冲以便恢复）
   */
  function markInterrupted() {
    if (!transferMeta) return
    isReceiving.value = false
    fileStore.markTransferInterrupted(transferMeta.id, receivedCount, transferMeta.totalChunks)
    console.log(`[FileTransfer] 传输中断: ${transferMeta.fileName}, 已收 ${receivedCount}/${transferMeta.totalChunks}`)
    // 不清除 chunks、transferMeta、_transferId，保留以便重连后续传
  }

  /**
   * 清理所有传输状态
   */
  function cleanup() {
    _clearTransferTimeout()
    chunks = []
    transferMeta = null
    receivedCount = 0
    _transferId = null
    progress.value = 0
    isReceiving.value = false
  }

  // ---- 内部方法 ----

  /** 重置超时计时器（每次活动时调用） */
  function _resetTransferTimeout() {
    _clearTransferTimeout()
    _transferTimeout = setTimeout(() => {
      console.warn(`[FileTransfer] 传输超时: ${transferMeta?.fileName}, 已收 ${receivedCount}/${transferMeta?.totalChunks}`)
      if (transferMeta) {
        fileStore.expireTransfer(transferMeta.id)
      }
      cleanup()
    }, TRANSFER_TIMEOUT_MS)
  }

  /** 清除超时计时器 */
  function _clearTransferTimeout() {
    if (_transferTimeout) {
      clearTimeout(_transferTimeout)
      _transferTimeout = null
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
    getReceivedChunks,
    markInterrupted,
    cleanup,
  }
}
