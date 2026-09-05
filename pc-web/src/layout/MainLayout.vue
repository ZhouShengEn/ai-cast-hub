<template>
  <div class="flex h-screen w-full overflow-hidden">
    <!--
      移动端顶部栏：仅 < 768px 显示（md:hidden）。
      PC 端不渲染，因此 PC 布局与改造前完全一致。
    -->
    <header
      class="fixed top-0 inset-x-0 z-30 h-14 flex items-center gap-3 px-4
             bg-surface-800 text-white md:hidden"
    >
      <button
        type="button"
        class="w-10 h-10 shrink-0 flex items-center justify-center rounded-lg
               hover:bg-white/10 active:bg-white/20 transition-colors"
        :aria-label="ui.isSidebarOpen ? '关闭菜单' : '打开菜单'"
        :aria-expanded="ui.isSidebarOpen"
        aria-controls="app-sidebar"
        @click="ui.toggleSidebar()"
      >
        <!-- 汉堡图标：三条横线，展开时上下两条旋转成 X -->
        <span class="relative block w-5 h-4">
          <span
            class="absolute left-0 top-0 h-0.5 w-5 rounded bg-white
                   transition-all duration-300 ease-in-out"
            :class="ui.isSidebarOpen ? 'rotate-45 translate-y-[7px]' : ''"
          ></span>
          <span
            class="absolute left-0 top-[7px] h-0.5 w-5 rounded bg-white
                   transition-all duration-300 ease-in-out"
            :class="ui.isSidebarOpen ? 'opacity-0' : 'opacity-100'"
          ></span>
          <span
            class="absolute left-0 top-[14px] h-0.5 w-5 rounded bg-white
                   transition-all duration-300 ease-in-out"
            :class="ui.isSidebarOpen ? '-rotate-45 -translate-y-[7px]' : ''"
          ></span>
        </span>
      </button>

      <h1 class="text-base font-bold tracking-wide truncate">
        <span class="text-primary-500">AI</span> Cast Hub
      </h1>
    </header>

    <!--
      遮罩层：仅移动端 + 侧边栏展开时出现。
      点击遮罩收起侧边栏；PC 端因 md:hidden 永不渲染。
    -->
    <Transition name="fade">
      <div
        v-if="ui.isMobile && ui.isSidebarOpen"
        class="fixed inset-0 z-40 bg-black/50 md:hidden"
        @click="ui.closeSidebar()"
      ></div>
    </Transition>

    <!--
      侧边栏：
      - 移动端：fixed 浮层，覆盖内容、不挤压主区域，z-50 高于遮罩 z-40
      - PC 端（md:）：还原为 static 参与 flex 布局，永久展示
    -->
    <Transition name="slide">
      <aside
        v-if="ui.sidebarVisible"
        id="app-sidebar"
        class="fixed inset-y-0 left-0 z-50 w-64 bg-surface-800 text-white
               flex flex-col shrink-0
               md:static md:z-auto md:translate-x-0"
      >
        <!-- Logo 区域（移动端顶部栏已有标题，这里仅在 PC 显示） -->
        <div class="p-6 border-b border-white/10 hidden md:block">
          <h1 class="text-xl font-bold tracking-wide">
            <span class="text-primary-500">AI</span> Cast Hub
          </h1>
          <p class="text-xs text-gray-400 mt-1">跨设备 AI 协作平台</p>
        </div>

        <!-- 移动端顶部留白，避免菜单被顶部栏压住 -->
        <div class="h-14 shrink-0 md:hidden"></div>

        <!-- 导航菜单 -->
        <nav class="flex-1 py-4 overflow-y-auto">
          <ul class="space-y-1 px-3">
            <li v-for="item in navItems" :key="item.path">
              <router-link
                :to="item.path"
                class="flex items-center gap-3 px-4 py-3 rounded-lg text-sm font-medium transition-colors relative"
                :class="isActive(item.path)
                  ? 'bg-primary-600 text-white'
                  : 'text-gray-300 hover:bg-white/10 hover:text-white'"
                @click="onNavClick"
              >
                <span class="text-lg">{{ item.icon }}</span>
                <span class="truncate">{{ item.label }}</span>
                <!-- 消息未读红点 -->
                <span
                  v-if="item.hasBadge && messageStore.unreadCount > 0"
                  class="absolute top-1 right-2 min-w-[18px] h-[18px] px-1 bg-red-500 text-white text-[10px] font-bold rounded-full flex items-center justify-center"
                >
                  {{ messageStore.unreadCount > 99 ? '99+' : messageStore.unreadCount }}
                </span>
              </router-link>
            </li>
          </ul>
        </nav>

        <!-- 底部状态 -->
        <div class="p-4 border-t border-white/10">
          <div class="flex items-center gap-2 text-xs text-gray-400">
            <span class="w-2 h-2 rounded-full shrink-0" :class="deviceStatusClass"></span>
            <span class="truncate">{{ deviceStatusText }}</span>
          </div>
        </div>
      </aside>
    </Transition>

    <!--
      主内容区：
      - 移动端：pt-14 给顶部栏让位；min-w-0 + overflow-x-hidden 防止子内容撑出横向滚动条
      - PC 端：保持原有 flex-1 自适应
    -->
    <main
      class="flex-1 min-w-0 overflow-y-auto overflow-x-hidden bg-surface-50"
      :class="ui.isMobile ? 'w-full pt-14' : ''"
    >
      <slot />
    </main>
  </div>
</template>

<script setup>
import { computed, inject, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useUiStore } from '../stores/ui'
import { useMessageStore } from '../stores/message'

const route = useRoute()
const ui = useUiStore()
const messageStore = useMessageStore()

/** 设备连接状态由 App.vue 通过 provide 注入，保持原有逻辑不变 */
const deviceConnected = inject('deviceConnected', ref(false))

/** 导航菜单项（与改造前完全一致） */
const navItems = [
  { path: '/', label: '首页', icon: '🏠' },
  { path: '/chat', label: 'AI 对话', icon: '💬' },
  { path: '/cast', label: '投屏接收', icon: '📺' },
  { path: '/message', label: '消息', icon: '💬', hasBadge: true },
]

const deviceStatusClass = computed(() =>
  deviceConnected.value ? 'bg-green-400' : 'bg-yellow-400'
)

const deviceStatusText = computed(() =>
  deviceConnected.value ? '设备已连接' : '等待设备连接'
)

/** 判断当前路由是否激活（沿用原有逻辑） */
function isActive(path) {
  if (path === '/') {
    return route.path === '/'
  }
  return route.path.startsWith(path)
}

/** 移动端点击导航后自动收起侧边栏 */
function onNavClick() {
  if (ui.isMobile) {
    ui.closeSidebar()
  }
}

// 路由变化（含返回键、代码跳转）时收起，避免浮层残留
watch(() => route.fullPath, () => {
  if (ui.isMobile) {
    ui.closeSidebar()
  }
})
</script>

<style scoped>
/* 遮罩淡入淡出 */
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.3s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

/* 侧边栏从左滑入滑出 */
.slide-enter-active,
.slide-leave-active {
  transition: transform 0.3s ease-in-out;
}
.slide-enter-from,
.slide-leave-to {
  transform: translateX(-100%);
}

/*
  PC 端侧边栏是静态布局成员，不参与浮层动画。
  这里在 md 断点以上直接关掉过渡，避免缩放窗口跨断点时出现多余的滑入动画。
*/
@media (min-width: 768px) {
  .slide-enter-active,
  .slide-leave-active {
    transition: none !important;
  }
}
</style>
