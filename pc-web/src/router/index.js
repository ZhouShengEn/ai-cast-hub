import { createRouter, createWebHistory } from 'vue-router'

/** 路由懒加载：各页面视图 */
const HomeView = () => import('../views/HomeView.vue')
const ChatView = () => import('../views/ChatView.vue')
const CastView = () => import('../views/CastView.vue')
const MessageView = () => import('../views/MessageView.vue')

const routes = [
  { path: '/',     name: 'Home',     component: HomeView,     meta: { title: '首页 - 设备绑定' } },
  { path: '/chat', name: 'Chat',     component: ChatView,     meta: { title: 'AI 对话' } },
  { path: '/cast', name: 'Cast',     component: CastView,     meta: { title: '投屏接收' } },
  { path: '/message', name: 'Message', component: MessageView, meta: { title: '消息' } },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
})

/** 路由守卫：设置页面标题 */
router.beforeEach((to) => {
  document.title = to.meta.title || 'AI Cast Hub'
})

export default router
