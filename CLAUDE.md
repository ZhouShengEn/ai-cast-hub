# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI Cast Hub is a cross-device AI collaboration platform. Three components:
- **server/** — Node.js 20 + Express 4 backend (REST API, WebSocket signaling, SSE streaming)
- **pc-web/** — Vue 3.4 + Vite 5 + Pinia + TailwindCSS 3 PC browser client
- **flutter-app/** — Flutter 3.x + Riverpod mobile app (Android/Web)

Core features: multi-model AI chat (7 providers), screen casting (WebRTC P2P), P2P file transfer (WebRTC DataChannel), and a Docker sandbox for code execution.

## Development Commands

### Backend (server/)
```bash
cd server && npm install && npm start          # start on port 3000
cd server && npm run dev                       # start with --watch (auto-restart)
```

### PC Web (pc-web/)
```bash
cd pc-web && npm install && npm run dev        # Vite dev server on port 5173
cd pc-web && npm run build                     # production build
```

### Flutter App (flutter-app/)
```bash
cd flutter-app && flutter pub get && flutter run    # run on connected device/emulator
cd flutter-app && flutter build apk                 # build Android APK
```

### Docker Deployment
```bash
docker compose build sandbox-builder           # build sandbox image first
docker compose up -d                           # start all 5 services (nginx, server, mysql, coturn, sandbox)
```

### Environment Setup
```bash
cp .env.example .env                           # then edit .env with required values
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"  # generate ENCRYPTION_KEY
```

## Architecture

### Data Flow
```
Mobile (Flutter) ←── WebRTC P2P ──→ PC Browser (Vue 3)
       │                                   │
       └──── WebSocket (/ws) ────→ Node.js Server ←── REST/SSE ←──┘
                                       │
                                       ├── AI Providers (OpenAI, Claude, Gemini, Qwen, Ernie, DeepSeek, GLM)
                                       ├── MySQL (production) / In-Memory Map (dev)
                                       └── Docker Sandbox
```

### Server Layer Organization
- **routes/** — REST endpoints: `device.js`, `chat.js`, `model.js`, `file.js`, `stats.js`
- **services/ai/** — Adapter pattern: `adapter.js` resolves `{provider}:{modelName}`, `providerBase.js` is an OpenAI-compatible base class that Qwen/Ernie/DeepSeek/GLM extend. OpenAI, Claude, Gemini each use their own SDK.
- **services/webrtc/** — `signaling.js` handles WebRTC offer/answer/ICE relay; `sessionManager.js` manages rooms with 5-min expiry; `turnConfig.js` returns Coturn credentials
- **ws/** — WebSocket server at `/ws?deviceUuid=xxx&transferKey=xxx` with 30s heartbeat (60s timeout)
- **middleware/deviceAuth.js** — Authenticates REST requests via `X-Device-UUID` + `X-Transfer-Key` headers
- **services/cryptoService.js** — AES-256-GCM encryption for stored API keys

### PC Web Organization
- **composables/** — Core logic in reusable composables: `useWebSocket.js`, `useWebRTC.js`, `useSSE.js`, `useFileTransfer.js`, `useCastReceiver.js`
- **stores/** — Pinia stores: `chat.js`, `device.js`, `cast.js`, `file.js`, `message.js`
- **views/** — 4 main pages: Home (pairing), Chat, Cast, Message
- Dev server proxies `/api` and `/ws` to `localhost:3000` via Vite config

### Flutter App Organization
- **services/** — Backend communication: `api_client.dart` (Dio), `websocket_service.dart`, `webrtc_service.dart`, `cast_service.dart`, `file_service.dart`
- **providers/** — Riverpod state management mirroring Pinia stores
- **screens/** — Home, Chat, Cast, File, Settings, Scan (QR pairing)
- Uses `flutter_webrtc` for screen capture (MediaProjection) and DataChannel file transfer

### Device Pairing Flow
1. PC generates a 6-digit pairing code (displayed on HomeView)
2. Mobile user enters the code → `POST /device/bind` pairs the two device UUIDs
3. Both devices share a `transferKey` for subsequent authenticated communication

### WebRTC Signaling Protocol
1. Client creates room via WebSocket → server returns `room_created` with `roomId`
2. Client sends `offer` → server relays to peer in room
3. Peer responds with `answer` → server relays back
4. ICE candidates exchanged bidirectionally through signaling
5. Coturn TURN server used as fallback for NAT traversal

### P2P File Transfer
- WebRTC DataChannel with 64KB chunks, SHA-256 integrity verification
- Max file size: 2GB
- Server coordinates metadata only (`POST /file/transfer/init`); data flows P2P

### Database (MySQL, production only)
Six tables defined in `deploy/mysql/init.sql`: `devices`, `device_bindings`, `conversations`, `messages`, `api_keys`, `token_usage`, `file_transfers`. Dev mode uses in-memory Map storage.

## Key Configuration

`.env` is loaded by `dotenv` — see `.env.example` for all variables. Critical ones:
- `ENCRYPTION_KEY` — 32-byte hex for AES-256-GCM API key encryption
- `DB_MYSQL_*` — MySQL connection; when unset, falls back to in-memory storage
- `TURN_SERVER` — Coturn address for WebRTC NAT traversal
- `SANDBOX_TIMEOUT_SEC` — code execution timeout (default 120)

## Design Documentation

`docs/system_design.md` contains detailed architecture diagrams, sequence diagrams, API contracts, and task breakdown (T01-T05). Consult this for comprehensive design rationale.

## 记忆规则

每次对话结束，如果修改了代码，需完成以下步骤：

1. **告知修改的服务列表**：明确指出修改了哪些服务（server、pc-web、flutter-app）
2. **简要描述改动**：说明每个服务具体改了什么内容
3. **重启对应服务**：新开 PowerShell 窗口重启被修改的服务

示例格式：
```
本次对话修改了以下服务：
- server: 修改了 xxx 功能
- pc-web: 新增了 xxx 组件
- flutter-app: 修复了 xxx bug

正在重启服务...
```
