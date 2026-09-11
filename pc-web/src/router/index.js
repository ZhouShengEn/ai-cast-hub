import { createRouter, createWebHistory } from 'vue-router'

/** 路由懒加载：各页面视图 */
const HomeView = () => import('../views/HomeView.vue')
const ChatView = () => import('../views/ChatView.vue')
const CastView = () => import('../views/CastView.vue')
const MessageView = () => import('../views/MessageView.vue')

// 服务器运维监控模块（全新独立模块）
const ServerMonitorDashboard = () => import('../views/server-monitor/ServerMonitorDashboard.vue')
const ServerMonitorServices = () => import('../views/server-monitor/ServerMonitorServices.vue')
const ServerMonitorServiceDetail = () => import('../views/server-monitor/ServerMonitorServiceDetail.vue')
const ServerMonitorNginx = () => import('../views/server-monitor/ServerMonitorNginx.vue')
const ServerMonitorAudit = () => import('../views/server-monitor/ServerMonitorAudit.vue')
const ServerMonitorSettings = () => import('../views/server-monitor/ServerMonitorSettings.vue')

const routes = [
  { path: '/',     name: 'Home',     component: HomeView,     meta: { title: '首页 - 设备绑定' } },
  { path: '/chat', name: 'Chat',     component: ChatView,     meta: { title: 'AI 对话' } },
  { path: '/cast', name: 'Cast',     component: CastView,     meta: { title: '投屏接收' } },
  { path: '/message', name: 'Message', component: MessageView, meta: { title: '消息' } },

  // ---- 服务器运维监控（独立模块） ----
  { path: '/monitor', name: 'MonitorDashboard', component: ServerMonitorDashboard, meta: { title: '服务监控 - 概览' } },
  { path: '/monitor/services', name: 'MonitorServices', component: ServerMonitorServices, meta: { title: '服务监控 - 服务列表' } },
  { path: '/monitor/service/:id', name: 'MonitorServiceDetail', component: ServerMonitorServiceDetail, meta: { title: '服务监控 - 服务详情' } },
  { path: '/monitor/nginx', name: 'MonitorNginx', component: ServerMonitorNginx, meta: { title: '服务监控 - Nginx 管理' } },
  { path: '/monitor/audit', name: 'MonitorAudit', component: ServerMonitorAudit, meta: { title: '服务监控 - 操作审计' } },
  { path: '/monitor/settings', name: 'MonitorSettings', component: ServerMonitorSettings, meta: { title: '服务监控 - 设置' } },
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
