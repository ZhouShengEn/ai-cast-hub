# 服务器运维监控面板（Server Monitor）

基于 AI-Cast-Hub 项目（Vue3 PC-Web + Node.js 后端）新增的**独立、解耦**云服务器服务监控运维模块。
**完全不改动**原有投屏、WebRTC、设备管理、音频、隧道、防盗等业务，所有代码位于独立子模块。

---

## 一、能力总览

| 能力 | 说明 |
|------|------|
| 自动扫描 | 固定扫描 `/opt/workspace`，受 `maxDepth` 限制防递归卡死，支持忽略列表 |
| 全语言识别 | Node / Vue / SpringBoot / Python / Go / Rust / PHP / .NET / 静态 / Shell / Nginx 站点 / Docker Compose |
| 自动生成脚本 | 根据项目特征自动生成 start/stop/restart/build 命令，支持 Web 端手动覆盖 |
| Nginx 全量管理 | 配置在线编辑+强制语法校验、nginx -t、-s reload、启停重启、访问/错误日志 |
| **端口联动锁定** | 解析 proxy_pass 自动绑定后端端口与项目，端口置灰锁定，启动前双重校验，双向联动，MD5 变更告警 |
| 实时状态 | WebSocket 长连接推送：PID / 端口 / 运行时长 / CPU / 内存 / 启停状态 |
| Git 运维 | 多维度状态判定（最新/脏代码/可拉取/非仓库/异常）+ 一键 pull（可选 rebase） |
| 日志系统 | 分级着色（ERROR/WARN/INFO/DEBUG）、流式推送、关键词过滤、暂停滚动 |
| 统计告警 | 顶部统计卡片 + 宕机/配置错误/端口冲突实时弹窗告警 |
| 审计权限 | 操作审计留痕（可导出）+ 只读/管理员细粒度权限 |

---

## 二、目录结构

```
server/src/modules/server-monitor/   # 后端独立模块
├── index.js            # 模块入口（router + initMonitor）
├── routes.js           # REST API（/api/v1/server-monitor）
├── wsHub.js            # WebSocket 实时推送（独立 /ws/monitor）
├── config.js           # 配置持久化（JSON）
├── permission.js       # 权限（复用设备认证）
├── commandRunner.js    # ★ 安全命令执行器（白名单/沙箱/超时）
├── constants.js        # 类型/白名单常量
├── util.js             # 沙箱校验/进程读取等工具
├── ids.js              # 项目 ID 编解码
├── typeDetector.js     # 项目类型识别
├── scriptGenerator.js  # 启停脚本自动生成
├── projectStore.js     # 单项目覆盖配置
├── scanner.js          # 目录扫描
├── processManager.js   # 启停/重启/PID/资源追踪
├── nginxManager.js     # Nginx 管理 + 端口锁定
├── gitService.js       # Git 状态/拉取
├── logService.js       # 日志读取/增量监听
├── audit.js            # 操作审计
└── systemInfo.js       # CPU/内存/磁盘采集

pc-web/src/
├── api/monitor.js                  # API 客户端
├── composables/useMonitorWs.js     # 监控 WebSocket 客户端
├── stores/monitor.js               # 全局状态（WS + REST 聚合）
├── components/monitor/             # StatCard / StatusBadge / LogViewer
├── views/server-monitor/           # Dashboard / Services / ServiceDetail / Nginx / Audit / Settings
├── router/index.js                 # 新增 /monitor/* 路由
└── layout/MainLayout.vue           # 新增「服务监控」导航项
```

---

## 三、安全设计（重中之重）

1. **严格命令白名单**：所有命令必须在 `constants.js` 的 `ALLOWED_BINS` 中，其余一律拒绝。
2. **目录沙箱锁定**：`cwd` 必须位于沙箱根目录（扫描根 + 允许的 Nginx 目录）内，越权访问直接抛错。
3. **无 shell 拼接**：所有命令以数组参数经 `child_process.spawn`（无 shell）执行，前端输入仅作校验后的参数/环境变量，杜绝注入。
4. **超时强杀**：一次性命令超时 `SIGKILL`；长期服务停止先 `SIGTERM` 后超时 `SIGKILL`。
5. **全局鉴权**：复用项目 `deviceAuth` 中间件，未授权请求直接拦截。
6. **细粒度权限**：`enablePermission` 开启后，按设备 UUID 映射 `admin` / `readonly`；只读角色禁止一切运维写操作。
7. **高危二次确认**：前端停止/重启/编译/改 Nginx 配置均触发确认弹窗（后端同样校验权限）。
8. **操作审计**：所有写操作留存操作人/时间/服务/类型/日志/成功状态，可查询导出。

---

## 四、部署依赖

模块运行在 Linux 服务器（生产）上，按需具备以下命令（均在白名单内）：

| 依赖 | 用途 | 必需 |
|------|------|------|
| `git` | 代码状态检测 / 拉取 | 是（Git 项目） |
| `nginx` | Nginx 管理 / 校验 / 重载 | 是（Nginx 模块） |
| `ss` | 端口监听探测 | 推荐（否则端口状态降级） |
| `node` / `npm` | Node/Vue 项目 | 按项目 |
| `java` / `mvn` / `gradle` | SpringBoot | 按项目 |
| `python3` | Python / 静态托管 | 按项目 |
| `go` / `cargo` / `php` / `dotnet` | 对应语言 | 按项目 |
| `docker` / `docker-compose` | 容器项目 | 按项目 |
| `systemctl` / `service` | Nginx/系统服务控制 | 按需 |

配置/运行时数据持久化于 `server/data/server-monitor/`（`config.json` / `runtime.json` / `nginxLinks.json` / `audit.jsonl` / `projects.json` / `logs/`）。

---

## 五、配置说明

`GET /api/v1/server-monitor/config` 返回并可经 `PUT` 修改：

| 字段 | 默认 | 说明 |
|------|------|------|
| `scanRoot` | `/opt/workspace` | 扫描根目录（Web 可改，持久化） |
| `maxDepth` | `1` | 递归深度，0–5，防卡死 |
| `ignoreList` | `[]` | 忽略的项目绝对路径 |
| `useSystemNginx` | `false` | 是否加载系统 `/etc/nginx`（默认关闭防误伤） |
| `nginxConfigDirs` | `[]` | 额外 Nginx 配置目录 |
| `enablePermission` | `false` | 细粒度权限开关 |
| `roles` | `{}` | 设备 UUID → `admin`/`readonly` |
| `pollIntervalMs` | `5000` | 前端轮询兜底间隔 |
| `refreshIntervalMs` | `3000` | 实时推送间隔 |
| `commandTimeoutSec` | `60` | 一次性命令超时 |
| `stopGraceSec` | `8` | 进程优雅停止等待 |
| `enableAlertPush` | `false` | 告警推送到安卓 App |

---

## 六、REST API 概览

前缀 `/api/v1/server-monitor`，均经设备认证；写操作需 `admin` 角色。

- `GET  /config` · `PUT /config` · `POST /config/ignore` · `DELETE /config/ignore`
- `POST /scan` · `GET /services` · `GET /services/external` · `GET /services/:id`
- `POST /services/:id/start|stop|restart|build` · `GET /services/:id/logs`
- `GET /services/:id/git` · `POST /services/:id/git/pull`
- `PUT /services/:id/port|env|script|display-name`
- `GET /nginx/configs` · `GET/PUT /nginx/configs/:id` · `POST /nginx/test|reload|control`
- `GET /nginx/logs/:type` · `GET /nginx/links` · `POST /nginx/links` · `DELETE /nginx/links/:id`
- `GET /audit` · `GET /audit/export`
- `GET /system` · `GET/PUT /roles/:deviceUuid`

## 七、WebSocket 协议（/ws/monitor）

消息格式 `{ type, payload }`：
- 服务端 → 客户端：`auth` / `snapshot` / `services_update` / `system_update` / `nginx_links_update` / `log_line` / `log_history` / `alert` / `error`
- 客户端 → 服务端：`subscribe_log`({id}) / `unsubscribe_log` / `ping`

断线由前端自动重连；重连后服务端重发 `snapshot`，后台异步任务（启动/编译/git）不中断，结果通过实时通道回传。

---

## 八、已知边界与降级

- **CPU/内存采集**依赖 Linux `/proc`，非 Linux 环境返回 `null`（前端降级展示）。
- **外部托管服务**（pm2/systemd/docker）做只读状态检测，其生命周期不接管；启停经由对应 CLI。
- **Nginx 语法校验**优先 `nginx -t`，不可用时退化为正则基础校验并明确提示。
- 所有接口/命令均带异常捕获与状态兜底，单项目异常不影响整体面板。
