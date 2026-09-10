#!/usr/bin/env bash
# =============================================================================
# AI-Cast-Hub —— 云服务器端更新脚本（在服务器上执行）
#
# 流程：
#   1. git 拉取最新代码（以 GitHub 远端为准）
#   2. 依赖指纹变化时才 npm install（省时间）
#   3. pc-web 构建产物（nginx 直接托管 dist）
#   4. pm2 重启 server 端
#   5. nginx 配置校验 + reload
#   6. 健康检查，失败则打印日志并退出非 0
#
# 手动执行：
#   bash /opt/workspace/ai-cast-hub/scripts/deploy/remote-update.sh
#
# 通常由本地 scripts/deploy/deploy.sh 通过 ssh 管道传入执行，
# 因此服务器上不需要额外维护一份脚本副本。
# =============================================================================
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/opt/workspace/ai-cast-hub}"
BRANCH="${BRANCH:-master}"
PM2_APP="${PM2_APP:-ai-cast-server}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:3100/api/v1/health}"

# 非交互 ssh 下 PATH 很干净，这里补齐全
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export NODE_ENV="${NODE_ENV:-production}"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true

C_CYAN='\033[36m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_OFF='\033[0m'
log()  { printf "${C_CYAN}[deploy]${C_OFF} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[deploy]${C_OFF} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[deploy]${C_OFF} %s\n" "$*"; }
die()  { printf "${C_RED}[deploy]${C_OFF} %s\n" "$*" >&2; exit 1; }

# 依赖指纹：文件内容 md5（文件不存在时返回 missing）
fp() { [ -f "$1" ] && md5sum "$1" | awk '{print $1}' || echo "missing"; }

log "===== 远端更新开始 $(date '+%F %T') ====="
log "目录=$REMOTE_DIR  分支=$BRANCH  pm2应用=$PM2_APP"

cd "$REMOTE_DIR" || die "项目目录不存在: $REMOTE_DIR"
command -v git >/dev/null || die "服务器未安装 git"

SRV_FP_BEFORE="$(fp "$REMOTE_DIR/server/package.json")"
WEB_FP_BEFORE="$(fp "$REMOTE_DIR/pc-web/package.json")"
COMMIT_BEFORE="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

# ---------------------------------------------------------------- 1. 拉取代码
log "[1/6] 拉取最新代码 ..."
DIRTY="$(git status --porcelain || true)"
if [ -n "$DIRTY" ]; then
  warn "检测到服务器本地改动，部署将以远端代码为准覆盖它们："
  echo "$DIRTY" | head -20 | sed 's/^/         /'
fi
git fetch --all --prune || die "git fetch 失败（检查网络 / GitHub 可达性）"
git checkout -B "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1 \
  || die "切换到 origin/$BRANCH 失败"
COMMIT_AFTER="$(git rev-parse --short HEAD)"
ok "代码已更新: $COMMIT_BEFORE -> $COMMIT_AFTER  $(git log -1 --pretty=%s)"

# ---------------------------------------------------------------- 2. 安装依赖
log "[2/6] 检查依赖 ..."
if [ "$SKIP_INSTALL" = "1" ]; then
  warn "已跳过依赖安装 (SKIP_INSTALL=1)"
else
  SRV_FP_AFTER="$(fp "$REMOTE_DIR/server/package.json")"
  WEB_FP_AFTER="$(fp "$REMOTE_DIR/pc-web/package.json")"

  if [ ! -d "$REMOTE_DIR/server/node_modules" ] || [ "$SRV_FP_BEFORE" != "$SRV_FP_AFTER" ]; then
    log "server 依赖有变化，npm install ..."
    (cd "$REMOTE_DIR/server" && npm install --omit=dev --no-audit --no-fund) || die "server 依赖安装失败"
  else
    log "server 依赖无变化，跳过"
  fi

  if [ ! -d "$REMOTE_DIR/pc-web/node_modules" ] || [ "$WEB_FP_BEFORE" != "$WEB_FP_AFTER" ]; then
    log "pc-web 依赖有变化，npm install ..."
    (cd "$REMOTE_DIR/pc-web" && npm install --no-audit --no-fund) || die "pc-web 依赖安装失败"
  else
    log "pc-web 依赖无变化，跳过"
  fi
fi

# ---------------------------------------------------------------- 3. 构建前端
log "[3/6] 构建 pc-web ..."
if [ "$SKIP_BUILD" = "1" ]; then
  warn "已跳过前端构建 (SKIP_BUILD=1)"
else
  (cd "$REMOTE_DIR/pc-web" && npm run build) || die "pc-web 构建失败"
  [ -f "$REMOTE_DIR/pc-web/dist/index.html" ] || die "构建产物缺失: pc-web/dist/index.html"
  ok "前端构建完成"
fi

# ---------------------------------------------------------------- 4. 重启后端
log "[4/6] 重启 server (pm2: $PM2_APP) ..."
command -v pm2 >/dev/null || die "服务器未安装 pm2"
if pm2 describe "$PM2_APP" >/dev/null 2>&1; then
  pm2 restart "$PM2_APP" --update-env >/dev/null || die "pm2 restart 失败"
else
  warn "pm2 中不存在 $PM2_APP，按默认方式首次启动"
  (cd "$REMOTE_DIR/server" && pm2 start src/index.js --name "$PM2_APP" >/dev/null) || die "pm2 start 失败"
fi
pm2 save >/dev/null 2>&1 || warn "pm2 save 失败（不影响本次部署）"
ok "server 已重启"

# ---------------------------------------------------------------- 5. reload nginx
log "[5/6] 校验并 reload nginx ..."
if command -v nginx >/dev/null 2>&1; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx && ok "nginx 已 reload" || warn "nginx reload 失败"
  else
    warn "nginx 配置校验未通过，已跳过 reload（线上仍用旧配置）"
  fi
else
  warn "未检测到 nginx，跳过"
fi

# ---------------------------------------------------------------- 6. 健康检查
log "[6/6] 健康检查 $HEALTH_URL ..."
HEALTHY=0
if command -v curl >/dev/null 2>&1; then
  for _ in $(seq 1 20); do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HEALTH_URL" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ]; then HEALTHY=1; break; fi
    sleep 1
  done
else
  warn "未安装 curl，跳过健康检查"
  HEALTHY=1
fi

if [ "$HEALTHY" = "1" ]; then
  ok "健康检查通过"
else
  warn "健康检查失败（HTTP $CODE），最近 40 行日志："
  pm2 logs "$PM2_APP" --lines 40 --nostream 2>/dev/null || true
  die "部署后服务异常，请检查上方日志"
fi

ok "===== 部署完成 $(date '+%F %T')  $COMMIT_AFTER ====="
