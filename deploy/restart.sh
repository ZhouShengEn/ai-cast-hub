#!/usr/bin/env bash
#
# AI-Cast-Hub 一键部署重启脚本
# ----------------------------------------------------------------------------
# 流程：拉取最新代码 → 重启后端 server(PM2) → 重建前端 pc-web → 重载 nginx → 健康检查
#
# 适用部署形态（与仓库 README 一致）：
#   - 后端 server 由 PM2 守护，进程名 ai-cast-server（入口 server/src/index.js，端口 3000）
#   - 前端 pc-web 由「系统 nginx」托管 dist/（域名 cast.zhoushengen.xyz），非常驻进程
#
# 用法：
#   bash deploy/restart.sh                       # 使用默认目录 /opt/workspace/ai_cast_hub
#   PROJECT_DIR=/path/to/repo bash deploy/restart.sh
#   bash deploy/restart.sh /path/to/repo         # 也可传参指定项目目录
#
# 注意：脚本对每步做错误中断（失败即退出），nginx 重载前强制 nginx -t 配置校验，
#       避免错误配置导致 nginx 整体退出。本地有未提交改动会自动 stash（末尾提示可恢复）。
# ----------------------------------------------------------------------------

set -uo pipefail

# ---------- 配置 ----------
PROJECT_DIR="${1:-${PROJECT_DIR:-/opt/workspace/ai-cast-hub}}"
SERVER_NAME="ai-cast-server"
FRONTEND_DIR="$PROJECT_DIR/pc-web"
LOG_PREFIX="[restart]"

# ---------- 颜色输出（非终端时自动关闭）----------
if [ -t 1 ]; then
  C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_RESET='\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_INFO=''; C_RESET=''
fi
log()  { echo -e "${C_INFO}${LOG_PREFIX}${C_RESET} $*"; }
ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()  { echo -e "${C_ERR}✘${C_RESET} $*"; }

# ---------- 前置检查 ----------
command -v node >/dev/null 2>&1 || { err "未找到 node，请先安装 Node.js"; exit 1; }
command -v pm2   >/dev/null 2>&1 || { err "未找到 pm2，请先安装：npm i -g pm2"; exit 1; }
if command -v nginx >/dev/null 2>&1; then NGINX_OK=1; else NGINX_OK=0; warn "未检测到 nginx 命令，将跳过 nginx 重载"; fi

if [ ! -d "$PROJECT_DIR" ]; then
  err "项目目录不存在: $PROJECT_DIR"
  exit 1
fi
cd "$PROJECT_DIR" || { err "无法进入 $PROJECT_DIR"; exit 1; }
ok "项目目录: $PROJECT_DIR"

# ---------- 1. 拉取最新代码 ----------
log "步骤 1/5  拉取最新代码 (git pull) ..."
git fetch --all --quiet
if [ -n "$(git status --porcelain)" ]; then
  warn "检测到本地未提交改动，已自动 stash（恢复命令：git stash pop）"
  git stash push -u -m "auto-stash before restart $(date +%F_%T)" >/dev/null 2>&1 || true
fi
if git pull --ff-only >/dev/null 2>&1; then
  ok "代码已更新（fast-forward）"
else
  warn "fast-forward 拉取失败，尝试普通 pull（可能产生 merge 提交）"
  git pull || { err "git pull 失败，请手动解决冲突后重试"; exit 1; }
fi

# ---------- 2. 重启后端 server ----------
log "步骤 2/5  重启后端 server (pm2: $SERVER_NAME) ..."
if pm2 describe "$SERVER_NAME" >/dev/null 2>&1; then
  pm2 restart "$SERVER_NAME" || { err "pm2 restart 失败"; exit 1; }
  ok "已重启 $SERVER_NAME"
else
  warn "PM2 中无 $SERVER_NAME，改为启动..."
  pm2 start server/src/index.js --name "$SERVER_NAME" || { err "pm2 start 失败"; exit 1; }
  ok "已启动 $SERVER_NAME"
fi
pm2 save >/dev/null 2>&1 || true

# ---------- 3. 重建前端 pc-web ----------
log "步骤 3/5  重建前端 pc-web ..."
if [ ! -d "$FRONTEND_DIR" ]; then
  err "前端目录不存在: $FRONTEND_DIR"
  exit 1
fi
cd "$FRONTEND_DIR" || { err "无法进入 $FRONTEND_DIR"; exit 1; }
log "安装依赖 (npm install) ..."
npm install || { err "npm install 失败（检查网络 / npm registry）"; exit 1; }
ok "依赖已安装（含 leaflet 等）"
log "构建产物 (npm run build) ..."
npm run build || { err "npm run build 失败，请查看上方报错"; exit 1; }
ok "pc-web 构建完成 -> dist/"

# ---------- 4. 重载 nginx ----------
if [ "$NGINX_OK" = "1" ]; then
  log "步骤 4/5  重载 nginx (nginx -s reload) ..."
  if nginx -t >/dev/null 2>&1; then
    if nginx -s reload 2>/dev/null; then
      ok "nginx 已重载"
    else
      warn "nginx -s reload 失败（可能未以 root 运行或 pid 路径不对，请手动 reload）"
    fi
  else
    warn "nginx -t 配置校验未通过，已跳过 reload（请手动检查 nginx 配置）"
  fi
else
  log "步骤 4/5  跳过 nginx 重载（未检测到 nginx 命令）"
fi

# ---------- 5. 健康检查 ----------
log "步骤 5/5  健康检查 ..."
sleep 3
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/v1/health 2>/dev/null || echo "000")
if [ "$HEALTH" = "200" ]; then
  ok "后端健康 ✓ (HTTP $HEALTH)"
else
  warn "后端健康检查返回 $HEALTH，查看日志：pm2 logs $SERVER_NAME"
fi
FRONT=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
if [ "$FRONT" = "200" ]; then
  ok "前端可访问 ✓ (HTTP $FRONT)"
else
  warn "前端返回 $FRONT（若使用其它端口/域名请自行访问确认）"
fi

ok "部署重启流程结束。"
echo -e "${C_INFO}监控面板入口：https://cast.zhoushengen.xyz/monitor${C_RESET}"
