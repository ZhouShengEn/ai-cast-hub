import { defineStore } from 'pinia'

/**
 * 移动端断点（px）。
 * 与 Tailwind 默认 md 断点一致 —— md: 768px，即 `md:` 生效时为 PC 模式。
 */
export const MOBILE_BREAKPOINT = 768

/** resize 回调，模块级保存，避免把函数塞进 Pinia state 被响应式包裹 */
let resizeHandler = null

/**
 * 全局 UI 状态（纯布局，不含业务逻辑）
 *
 * 侧边栏语义：
 * - PC（>= 768px）：永久展开，isSidebarOpen 不参与判定
 * - 移动端（< 768px）：浮层模式，由 isSidebarOpen 控制，且每次进入移动端都重置为收起
 *   —— 不记忆展开状态，符合「移动端打开默认收起」的要求
 */
export const useUiStore = defineStore('ui', {
  state: () => ({
    /** 移动端侧边栏是否展开（PC 端该值不影响展示） */
    isSidebarOpen: false,
    /** 当前视口宽度，0 表示尚未初始化 */
    viewportWidth: 0,
    /**
     * PC 端侧边栏是否收起（手动折叠）。
     * 持久化到 localStorage，刷新后保持用户选择；移动端走 isSidebarOpen 分支，不受此值影响。
     */
    pcSidebarCollapsed: (() => {
      try {
        return localStorage.getItem('pcSidebarCollapsed') === '1'
      } catch (_) {
        return false
      }
    })(),
  }),

  getters: {
    /** 是否处于移动端模式 */
    isMobile: (state) =>
      state.viewportWidth > 0 && state.viewportWidth < MOBILE_BREAKPOINT,

    /**
     * 侧边栏是否可见。
     * 移动端：浮层模式，跟随 isSidebarOpen。
     * PC 端：跟随 pcSidebarCollapsed（可手动折叠，持久化）。
     */
    sidebarVisible() {
      return this.isMobile ? this.isSidebarOpen : !this.pcSidebarCollapsed
    },
  },

  actions: {
    openSidebar() {
      this.isSidebarOpen = true
    },

    closeSidebar() {
      this.isSidebarOpen = false
    },

    toggleSidebar() {
      this.isSidebarOpen = !this.isSidebarOpen
    },

    /** PC 端侧边栏手动折叠/展开，并持久化到 localStorage */
    togglePcSidebar() {
      this.pcSidebarCollapsed = !this.pcSidebarCollapsed
      try {
        localStorage.setItem('pcSidebarCollapsed', this.pcSidebarCollapsed ? '1' : '0')
      } catch (_) {
        // localStorage 不可用时仅内存态生效
      }
    },

    /**
     * 同步视口宽度。
     * 跨断点切换时强制收起侧边栏，避免把移动端的展开态带进 PC 或反之。
     */
    syncViewport(width) {
      const wasMobile = this.isMobile
      this.viewportWidth = width
      if (wasMobile !== this.isMobile) {
        this.isSidebarOpen = false
      }
    },

    /** 注册 resize 监听（应用启动时调用一次） */
    bindViewportListener() {
      if (resizeHandler || typeof window === 'undefined') return
      resizeHandler = () => this.syncViewport(window.innerWidth)
      window.addEventListener('resize', resizeHandler, { passive: true })
      // 立即同步一次，保证首屏就能拿到正确的模式
      this.syncViewport(window.innerWidth)
    },

    /** 注销 resize 监听 */
    unbindViewportListener() {
      if (!resizeHandler) return
      window.removeEventListener('resize', resizeHandler)
      resizeHandler = null
    },
  },
})
