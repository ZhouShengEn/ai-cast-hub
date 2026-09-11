/** 服务器监控模块 — 前端格式化工具 */

const TYPE_LABELS = {
  node: 'Node.js',
  vue: 'Vue/前端',
  springboot: 'SpringBoot',
  python: 'Python',
  go: 'Go',
  rust: 'Rust',
  php: 'PHP',
  dotnet: '.NET',
  static: '静态网页',
  shell: 'Shell 脚本',
  'nginx-site': 'Nginx 站点',
  'docker-compose': 'Docker Compose',
  unknown: '未知类型',
}

const GIT_LABELS = {
  up_to_date: { text: '已是最新', icon: '✅', cls: 'text-green-600' },
  dirty: { text: '本地有未提交修改', icon: '⚠️', cls: 'text-yellow-600' },
  behind: { text: '远程有新版本', icon: '🔽', cls: 'text-blue-600' },
  no_repo: { text: '非 Git 仓库', icon: '❌', cls: 'text-gray-500' },
  error: { text: 'Git 异常', icon: '❌', cls: 'text-red-600' },
}

export function typeLabel(t) {
  return TYPE_LABELS[t] || t || '未知'
}

export function gitLabel(s) {
  return GIT_LABELS[s] || { text: s || '未知', icon: '❓', cls: 'text-gray-500' }
}

export function formatUptime(sec) {
  if (sec == null) return '-'
  const d = Math.floor(sec / 86400)
  const h = Math.floor((sec % 86400) / 3600)
  const m = Math.floor((sec % 3600) / 60)
  const s = Math.floor(sec % 60)
  const parts = []
  if (d) parts.push(`${d}天`)
  if (h) parts.push(`${h}时`)
  if (m) parts.push(`${m}分`)
  parts.push(`${s}秒`)
  return parts.join('')
}

export function formatBytes(bytes) {
  if (bytes == null) return '-'
  const u = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  let n = bytes
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
  return `${n.toFixed(i === 0 ? 0 : 1)} ${u[i]}`
}

export function statusInfo(s) {
  // s: service object
  if (s.running) return { text: '运行中', cls: 'bg-green-100 text-green-700' }
  if (s.status === 'error') return { text: '异常', cls: 'bg-red-100 text-red-700' }
  return { text: '已停止', cls: 'bg-gray-100 text-gray-600' }
}

export function truncatePath(p, n = 42) {
  if (!p) return ''
  if (p.length <= n) return p
  return p.slice(0, n - 12) + '…' + p.slice(-12)
}
