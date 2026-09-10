#!/usr/bin/env bash
# =============================================================================
# AI-Cast-Hub —— 本地一键部署脚本（Windows Git Bash / macOS / Linux 通用）
#
# 作用：把本地代码推送到 GitHub，再 SSH 到云服务器执行 remote-update.sh
#       （拉代码 → 装依赖 → 构建 pc-web → 重启 server → reload nginx → 健康检查）
#
# 用法：
#   bash scripts/deploy/deploy.sh                 # 推送 + 完整部署
#   bash scripts/deploy/deploy.sh --no-push       # 只触发服务器拉取部署（不推送）
#   bash scripts/deploy/deploy.sh --skip-build    # 不重新构建前端
#   bash scripts/deploy/deploy.sh --skip-install  # 不安装依赖
#   bash scripts/deploy/deploy.sh --install-hook  # 安装 git 自动部署钩子
#
# 配置项可用同名环境变量覆盖：SSH_HOST / SSH_PORT / SSH_USER / SSH_KEY /
#                             REMOTE_DIR / BRANCH / PM2_APP
# =============================================================================
set -euo pipefail

SSH_HOST="${SSH_HOST:-43.108.9.6}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
# Git Bash 下 E:\workspace\ali.pem 对应 /e/workspace/ali.pem
SSH_KEY="${SSH_KEY:-/e/workspace/ali.pem}"
REMOTE_DIR="${REMOTE_DIR:-/opt/workspace/ai-cast-hub}"
BRANCH="${BRANCH:-master}"
PM2_APP="${PM2_APP:-ai-cast-server}"

DO_PUSH=1
SKIP_INSTALL=0
SKIP_BUILD=0
ACTION="deploy"

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-push)      DO_PUSH=0 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --skip-build)   SKIP_BUILD=1 ;;
    --install-hook) ACTION="install-hook" ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE_SCRIPT="$REPO_ROOT/scripts/deploy/remote-update.sh"
HOOK_FILE="$REPO_ROOT/.git/hooks/post-commit"

C_CYAN='\033[36m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_OFF='\033[0m'
log()  { printf "${C_CYAN}[local]${C_OFF} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[local]${C_OFF} %s\n" "$*"; }
die()  { printf "${C_RED}[local]${C_OFF} %s\n" "$*" >&2; exit 1; }

# ------------------------------------------------------- 安装 git 自动部署钩子
if [ "$ACTION" = "install-hook" ]; then
  mkdir -p "$(dirname "$HOOK_FILE")"
  cat > "$HOOK_FILE" <<'HOOK'
#!/bin/sh
# AI-Cast-Hub 自动部署钩子：每次 commit 后自动推送并更新云服务器。
# 临时不想要自动部署时：SKIP_AUTO_DEPLOY=1 git commit ...
# 卸载：删除本文件（.git/hooks/post-commit）
[ "${SKIP_AUTO_DEPLOY:-0}" = "1" ] && exit 0

BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
[ "$BRANCH_NOW" = "master" ] || exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$HOOK_DIR/../.." && pwd)"
LOG_FILE="$REPO_DIR/logs/deploy.log"
mkdir -p "$(dirname "$LOG_FILE")"

echo ""                                              >> "$LOG_FILE"
echo "===== post-commit 触发 $(date '+%F %T') =====" >> "$LOG_FILE"

if [ "${AUTO_DEPLOY_FOREGROUND:-0}" = "1" ]; then
  "$REPO_DIR/scripts/deploy/deploy.sh" 2>&1 | tee -a "$LOG_FILE"
else
  nohup "$REPO_DIR/scripts/deploy/deploy.sh" >> "$LOG_FILE" 2>&1 &
  echo "[auto-deploy] 已在后台部署，日志: $LOG_FILE"
fi
exit 0
HOOK
  chmod +x "$HOOK_FILE"
  ok "钩子已安装: $HOOK_FILE"
  exit 0
fi

# ------------------------------------------------------------------- 1. 推送
cd "$REPO_ROOT" || die "仓库根目录不存在: $REPO_ROOT"

if [ "$DO_PUSH" = "1" ]; then
  log "[1/2] 推送 $BRANCH 到 origin ..."
  if ! git push origin "$BRANCH"; then
    log "推送被拒，尝试 pull --rebase 后重试 ..."
    git pull --rebase --autostash origin "$BRANCH" || die "pull --rebase 失败，请手动处理冲突"
    git push origin "$BRANCH" || die "推送失败，请手动处理"
  fi
  ok "代码已推送: $(git rev-parse --short HEAD)"
else
  log "[1/2] 跳过推送 (--no-push)"
fi

# ------------------------------------------------------------------- 2. 远端
log "[2/2] SSH 到 $SSH_USER@$SSH_HOST 执行远端更新 ..."
[ -f "$SSH_KEY" ]   || die "SSH 私钥不存在: $SSH_KEY"
[ -f "$REMOTE_SCRIPT" ] || die "远端更新脚本不存在: $REMOTE_SCRIPT"

# 私钥权限过宽时 ssh 会拒绝使用（Windows 上可能出现），尝试收紧
chmod 600 "$SSH_KEY" 2>/dev/null || true

SSH_OPTS="-i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"

# 把远端脚本通过 stdin 传给服务器执行，服务器无需保存脚本副本
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$SSH_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' BRANCH='$BRANCH' PM2_APP='$PM2_APP' SKIP_INSTALL='$SKIP_INSTALL' SKIP_BUILD='$SKIP_BUILD' bash -s" \
  < "$REMOTE_SCRIPT"

ok "全部完成 🎉  线上地址: https://cast.zhoushengen.xyz"
