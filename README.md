# AI Cast Hub

跨设备 AI 协作平台 —— 多模型 AI 聊天 + 屏幕投屏 + P2P 文件传输。

## 核心功能

| 功能 | 说明 |
|------|------|
| **多模型 AI 聊天** | 统一接入 7 个 AI 模型提供商（OpenAI GPT、Claude、Gemini、通义千问、文心一言、DeepSeek、GLM），支持 SSE 流式响应 |
| **屏幕投屏** | 手机屏幕实时推送到 PC 浏览器，基于 WebRTC P2P（MediaProjection + Coturn TURN 中继） |
| **P2P 文件传输** | 最大 2GB 文件直传，WebRTC DataChannel 64KB 分片 + SHA-256 校验 |
| **代码沙箱** | AI 生成代码在 Docker 隔离容器中安全执行 |
| **跨平台** | PC Web (Vue 3) + 移动端 (Flutter)，Node.js/Express 后端 |

## 技术栈

| 层 | 技术 |
|----|------|
| **后端** | Node.js 20 + Express 4 + WebSocket + Dockerode |
| **PC 前端** | Vue 3.4 + Vite 5 + Pinia + TailwindCSS 3 |
| **移动端** | Flutter 3.x + Riverpod + flutter_webrtc |
| **数据库** | MySQL 8.0（生产）/ 内存存储（开发） |
| **基础设施** | Docker Compose + Nginx + Coturn |

## 快速开始

### 前置条件

- Node.js 20 LTS
- Docker & Docker Compose
- Flutter 3.x（移动端开发）

### 本地开发

```bash
# 1. 配置环境变量
cp .env.example .env
# 编辑 .env 填入必要的配置

# 2. 启动后端
cd server
npm install
npm start

# 3. 启动 PC Web（另一个终端）
cd pc-web
npm install
npm run dev

# 4. 启动 Flutter 移动端
cd flutter-app
flutter pub get
flutter run
```

### Docker 部署

```bash
# 构建沙箱镜像
docker compose build sandbox-builder

# 启动全部服务
docker compose up -d

# 查看服务状态
docker compose ps
```

## 项目结构

```
ai-cast-hub/
├── server/             # Node.js 后端服务
│   ├── src/
│   │   ├── routes/     # REST API 路由
│   │   ├── models/     # 数据模型
│   │   ├── services/   # 业务逻辑（AI适配器/WebRTC/沙箱）
│   │   ├── middleware/  # 中间件（认证/限流/错误处理）
│   │   ├── ws/         # WebSocket 服务
│   │   └── config/     # 配置管理
│   └── Dockerfile
├── pc-web/             # Vue 3 PC 前端
│   └── src/
│       ├── views/      # 页面
│       ├── components/ # 组件
│       ├── stores/     # Pinia 状态管理
│       ├── composables/# 组合式函数（WebSocket/WebRTC/SSE）
│       └── api/        # API 客户端
├── flutter-app/        # Flutter 移动端
│   └── lib/
│       ├── screens/    # 页面
│       ├── providers/  # Riverpod 状态管理
│       ├── services/   # API/WebSocket/WebRTC 服务
│       └── models/     # 数据模型
├── docs/               # 设计文档
├── deploy/             # 部署配置
│   ├── nginx/          # Nginx 配置
│   ├── coturn/         # TURN 服务器配置
│   ├── mysql/          # 数据库初始化
│   └── sandbox/        # 沙箱 Dockerfile
└── docker-compose.yml
```

## 设备配对流程

1. PC 端打开首页，生成 6 位连接码
2. 手机端打开 App，输入连接码完成绑定
3. 绑定后即可使用 AI 对话、投屏、消息等功能

## 支持的 AI 模型

| 提供商 | 模型 |
|--------|------|
| OpenAI | gpt-4o, gpt-4-turbo, gpt-3.5-turbo |
| Claude | claude-3-5-sonnet, claude-3-opus |
| Gemini | gemini-1.5-pro, gemini-1.5-flash |
| 通义千问 | qwen-plus, qwen-max, qwen-turbo |
| 文心一言 | ernie-4.0-8k, ernie-3.5-8k |
| DeepSeek | deepseek-chat, deepseek-coder |
| GLM | glm-4, glm-4-flash |

## 环境变量

参见 `.env.example`，主要配置项：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PORT` | 服务端口 | 3000 |
| `DB_MYSQL_*` | MySQL 连接信息 | mysql:3306 |
| `ENCRYPTION_KEY` | API Key 加密密钥（32字节 hex） | 需自行生成 |
| `TURN_SERVER` | Coturn 服务器地址 | turn:localhost:3478 |
| `SANDBOX_TIMEOUT_SEC` | 沙箱超时时间 | 120 |

### 生成加密密钥

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

## 文档

详细设计文档见 `docs/system_design.md`，包含架构图、时序图和完整 API 规格。
