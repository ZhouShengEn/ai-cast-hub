/**
 * 服务器监控模块 — 常量定义
 *
 * 集中定义：项目类型、命令白名单、操作枚举等。
 * 安全相关：ALLOWED_BINS 是命令执行器的唯一可执行二进制白名单。
 */

/** 支持识别的项目类型（枚举，用于前端展示与脚本生成分支） */
const PROJECT_TYPES = {
  NODE: 'node',
  VUE: 'vue',
  SPRINGBOOT: 'springboot',
  PYTHON: 'python',
  GO: 'go',
  RUST: 'rust',
  PHP: 'php',
  DOTNET: 'dotnet',
  STATIC: 'static',
  SHELL: 'shell',
  NGINX_SITE: 'nginx-site',
  DOCKER_COMPOSE: 'docker-compose',
  UNKNOWN: 'unknown',
};

/** 中文映射，便于前端展示 */
const PROJECT_TYPE_LABELS = {
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
};

/**
 * 服务识别优先级（从高到低）。
 * 数值越小优先级越高。
 */
const IDENT_PRIORITY = {
  pm2: 0,
  systemd: 1,
  docker: 2,
  nginx: 3,
  auto: 4,
  custom: 5,
};

/**
 * 命令执行白名单 —— 安全核心。
 * 只允许执行以下二进制，且必须以数组参数方式（无 shell 拼接）调用。
 * 任何不在列表中的命令都会被拒绝。
 */
const ALLOWED_BINS = new Set([
  // 运行/构建
  'node', 'npm', 'npx', 'yarn', 'pnpm',
  'python', 'python3',
  'java', 'mvn', 'gradle',
  'go', 'cargo', 'rustc',
  'php', 'dotnet', 'sh', 'bash',
  // 容器 / 系统
  'docker', 'docker-compose', 'systemctl', 'service',
  // 网络 / 进程查询（只读探测）
  'ss', 'lsof', 'ps', 'pgrep', 'pm2', 'df',
  // 版本控制
  'git',
  // nginx
  'nginx',
  // 工具
  'sleep', 'echo', 'cat', 'env',
]);

/** 最大单次命令输出缓冲（防止内存溢出），默认 4MB */
const MAX_OUTPUT_BUFFER = 4 * 1024 * 1024;

/** 环境变量 KEY 校验正则：仅允许合法标识符 */
const ENV_KEY_REGEX = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** 端口号校验 */
function isValidPort(p) {
  const n = Number(p);
  return Number.isInteger(n) && n >= 1 && n <= 65535;
}

/** 身份识别来源展示用 */
const SOURCE_LABELS = {
  pm2: 'PM2 进程',
  systemd: 'Systemd 服务',
  docker: 'Docker 容器',
  nginx: 'Nginx 站点',
  auto: '自动识别项目',
  custom: '自定义脚本',
};

/** Git 代码状态枚举 */
const GIT_STATUS = {
  UP_TO_DATE: 'up_to_date',     // ✅ 已是最新
  DIRTY: 'dirty',               // ⚠️ 本地有未提交修改
  BEHIND: 'behind',             // 🔽 远程有新版本
  NO_REPO: 'no_repo',           // ❌ 非 Git 仓库
  ERROR: 'error',               // ❌ 异常
};

module.exports = {
  PROJECT_TYPES,
  PROJECT_TYPE_LABELS,
  IDENT_PRIORITY,
  ALLOWED_BINS,
  MAX_OUTPUT_BUFFER,
  ENV_KEY_REGEX,
  isValidPort,
  SOURCE_LABELS,
  GIT_STATUS,
};
