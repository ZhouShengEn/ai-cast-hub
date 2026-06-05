import { defineStore } from 'pinia'

/**
 * 文件传输状态 Store — 管理文件传输任务列表
 */
export const useFileStore = defineStore('file', {
  state: () => ({
    /** 传输任务列表 */
    transfers: [],
    /** 待确认的传输任务 */
    pendingTransfer: null,
    /** 是否显示确认弹窗 */
    showConfirm: false,
  }),

  getters: {
    /** 活跃的传输任务（传输中） */
    activeTransfers: (state) => {
      return state.transfers.filter((t) => t.status === 'transferring' || t.status === 'pending')
    },

    /** 已完成的传输任务 */
    completedTransfers: (state) => {
      return state.transfers.filter((t) => t.status === 'completed')
    },
  },

  actions: {
    /** 添加新传输任务 */
    addTransfer(transfer) {
      const item = {
        id: transfer.id || `transfer_${Date.now()}`,
        fileName: transfer.fileName || 'unknown',
        fileSize: transfer.fileSize || 0,
        totalChunks: transfer.totalChunks || 0,
        receivedChunks: 0,
        progress: 0,
        status: 'pending',
        blob: null,
        blobUrl: null,
        checksum: transfer.checksum || null,
        createdAt: new Date().toISOString(),
        ...transfer,
      }
      this.transfers.unshift(item)
      return item
    },

    /** 更新传输进度 */
    updateTransferProgress(id, { receivedChunks, totalChunks }) {
      const transfer = this.transfers.find((t) => t.id === id)
      if (transfer) {
        transfer.receivedChunks = receivedChunks
        transfer.totalChunks = totalChunks || transfer.totalChunks
        transfer.progress =
          transfer.totalChunks > 0
            ? Math.min(100, Math.round((receivedChunks / transfer.totalChunks) * 100))
            : 0
      }
    },

    /** 确认接收文件 */
    confirmTransfer() {
      if (this.pendingTransfer) {
        const t = this.transfers.find((x) => x.id === this.pendingTransfer.id)
        if (t) {
          t.status = 'transferring'
        }
        this.showConfirm = false
      }
    },

    /** 拒绝接收文件 */
    rejectTransfer() {
      if (this.pendingTransfer) {
        this.removeTransfer(this.pendingTransfer.id)
        this.pendingTransfer = null
        this.showConfirm = false
      }
    },

    /** 完成传输 */
    completeTransfer(id, blob) {
      const transfer = this.transfers.find((t) => t.id === id)
      if (transfer) {
        transfer.status = 'completed'
        transfer.progress = 100
        if (blob) {
          transfer.blob = blob
          transfer.blobUrl = URL.createObjectURL(blob)
        }
      }
    },

    /** 删除传输任务 */
    removeTransfer(id) {
      const transfer = this.transfers.find((t) => t.id === id)
      if (transfer && transfer.blobUrl) {
        URL.revokeObjectURL(transfer.blobUrl)
      }
      this.transfers = this.transfers.filter((t) => t.id !== id)
    },
  },
})
