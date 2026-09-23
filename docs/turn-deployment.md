# TURN 中继部署与排障（coturn）

> 适用场景：WebRTC（消息通道 / 投屏 / 文件传输）在部分网络下「信令正常但一直转圈、最后 ICE failed」。
>
> 相关文件
>
> - `server/src/services/webrtc/turnConfig.js` —— 把 TURN 配置下发给客户端
> - `server/.env` —— `TURN_SERVER` / `TURN_USERNAME` / `TURN_CREDENTIAL`
> - `scripts/check-turn.js` —— STUN/TURN 可达性自检脚本
>
> 当前生产服务器：`cast.zhoushengen.xyz`（`43.108.9.6`，Ubuntu 24.04，PM2 + nginx，**未使用 Docker**）

---

## 目录

1. [为什么必须有 TURN](#1-为什么必须有-turn)
2. [判断「是不是 TURN 的问题」](#2-判断是不是-turn-的问题)
3. [服务器现状（NAT 关键信息）](#3-服务器现状nat-关键信息)
4. [部署步骤](#4-部署步骤)
5. [⚠️ 腾讯云安全组必须放行的 3 条规则](#5-️-腾讯云安全组必须放行的-3-条规则)
6. [接入应用（环境变量）](#6-接入应用环境变量)
7. [验证清单](#7-验证清单)
8. [常见故障排查](#8-常见故障排查)
9. [运维备忘](#9-运维备忘)

---

## 1. 为什么必须有 TURN

WebRTC 的连通性只有两条路：

| 路径 | 原理 | 依赖 |
|------|------|------|
| **P2P 直连** | 用 host / srflx 候选互相发包 | 双方网络允许入向 UDP；同 NAT 出口时需网关支持 **NAT 回环（Hairpin）** |
| **TURN 中继** | 双方都主动连到公网中继，由中继转发 | 只需**出向**能连到 TURN（UDP 3478 或 TCP 3478） |

**只要 P2P 打不通，没有 TURN 就一定失败**，而且信令、房间、日志看起来全是正常的——表现为「一直转圈然后超时」。

真实案例（企业网络）：手机和 PC 在同一套公司网络下，两端 STUN 拿到的 srflx **是同一个公网 IP**，也就是「自己连自己」：

- 局域网直连这条路被浏览器挡住了：Chrome 会把 PC 的局域网 IP 用 mDNS 匿名化成 `xxxx.local`，
  而 Android 端 libwebrtc **不解析 mDNS 候选** → 该候选作废；
- 只剩 `srflx ↔ srflx`，要求网关支持 NAT 回环。企业网关/云端安全网关通常不支持 → ICE failed。

家用路由器普遍支持 NAT 回环，所以「家里没问题、公司连不上」是典型症状。

---

## 2. 判断「是不是 TURN 的问题」

### 最快的一步：看服务端下发了什么

```bash
# 需要一个已注册的 X-Device-UUID
curl -s https://cast.zhoushengen.xyz/api/v1/webrtc/config \
  -H "X-Device-UUID: <任意已注册UUID>"
```

- 只返回 **1 条**（只有 STUN）→ 没有 TURN，跨 NAT 必然不可靠
- 返回 **2 条**（第二条带 `username` / `credential`）→ TURN 已下发

### 网络可达性自检

```bash
node scripts/check-turn.js
node scripts/check-turn.js "turn:cast.zhoushengen.xyz:3478?transport=udp,turn:cast.zhoushengen.xyz:3478?transport=tcp"
TURN_SERVER="turn:cast.zhoushengen.xyz:3478" node scripts/check-turn.js
```

脚本用 **RFC 5389 STUN Binding Request**（无需鉴权）测 UDP 并打印本机出口地址，用 TCP/TLS 建连探测另外两种传输。
结论对照：

| 现象 | 含义 |
|------|------|
| UDP OK | 网络到 TURN 的 UDP 通，TURN 可正常中继 |
| UDP FAIL | 网关封 UDP（或安全组未放行）→ 必须补 `?transport=tcp` |
| 全 FAIL | 安全组 / ufw 未放行、coturn 未启动、或 IP 端口写错 |

### 浏览器侧（最权威）

PC 上用同一网络打开 `chrome://webrtc-internals`，发起一次连接后看：

- `ICE candidate grid` 里是否出现 `relay` 类型的候选
- `selected candidate pair` 选中的是 `host` / `srflx` 还是 `relay`

出现 `relay` 且被选中 = 正在走 TURN 中继。

---

## 3. 服务器现状（NAT 关键信息）

```
公网 IP : 43.108.9.6          <- 对外
内网 IP : 172.19.30.32/18     <- eth0 上真实绑定的地址
```

这台机器是 **NAT 型云主机**：公网 IP 不落在网卡上。因此 coturn **必须**写成：

```
external-ip=43.108.9.6/172.19.30.32
```

否则 coturn 会把内网地址 `172.19.30.32` 当作 relay 候选下发给客户端，客户端永远连不上——**这是最容易踩的坑**。

同时注意：该 NAT **不支持回环**，在服务器上 `curl/telnet 自己的公网IP:3478` 是不通的，别用它来验证。

---

## 4. 部署步骤

以下命令均在服务器上以 root 执行（`ssh root@43.108.9.6`）。

### 4.1 安装

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y coturn
systemctl stop coturn        # 先停，配置好再起
```

Ubuntu 24.04 的 apt 源里是 `coturn 4.6.1`。

### 4.2 写配置 `/etc/turnserver.conf`

```bash
PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

cat > /etc/turnserver.conf <<TURNCONF
# 云主机 NAT 映射：公网/内网
external-ip=43.108.9.6/172.19.30.32

listening-port=3478
listening-ip=0.0.0.0
relay-ip=172.19.30.32

# 中继端口范围：收窄到 100 个，便于云安全组放行
min-port=49160
max-port=49259

# 认证：长期凭证
lt-cred-mech
user=ai_cast:${PASS}
realm=ai-cast-hub

# 未启用 TLS/DTLS（如需 turns: 见 §9.4）
no-tls
no-dtls

# 安全收敛
no-cli
no-multicast-peers
no-software-attribute

log-file=/var/log/turnserver.log
simple-log
no-stdout-log
TURNCONF

chown root:turnserver /etc/turnserver.conf
chmod 640 /etc/turnserver.conf
touch /var/log/turnserver.log
chown turnserver:turnserver /var/log/turnserver.log

printf '%s' "$PASS" > /root/.turn-credential
chmod 600 /root/.turn-credential
```

> `no-loopback-peers` 刻意**不启用**：启用后 coturn 会拒绝向回环地址中继，
> 导致「服务器上用 `turnutils_uclient` 自测」必然失败，反而难以排障。
> TURN 已有口令鉴权，风险可接受。

### 4.3 启用服务

Debian/Ubuntu 的 coturn 默认不开机自启，需要打开 `/etc/default/coturn` 里的开关：

```bash
sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn

systemctl enable coturn
systemctl restart coturn
systemctl is-active coturn          # 应输出 active
```

### 4.4 放行系统防火墙 ufw

```bash
ufw allow 3478/udp comment 'coturn turn udp'
ufw allow 3478/tcp comment 'coturn turn tcp'
ufw allow 49160:49259/udp comment 'coturn relay'
```

### 4.5 本机功能自测（重要）

```bash
turnutils_uclient -y -u ai_cast -w "$(cat /root/.turn-credential)" -p 3478 127.0.0.1
```

期望最后出现：

```
tot_send_msgs=20, tot_recv_msgs=20
Total lost packets 0 (0.000000%)
```

`-y` 是把自身地址当作 peer（少了会报 `Either -e peer_address or -y must be specified`）。
这一步通过，说明**配置解析、账号口令、relay 端口分配、数据转发**都是好的。

---

## 5. ⚠️ 腾讯云安全组必须放行的 3 条规则

**这一步在服务器上做不到，只能去腾讯云控制台（或云 API）改。**
ufw 放行 ≠ 外网可达；安全组是云端独立一层，而且是**显式白名单**。

控制台路径：**云服务器 CVM → 安全组 → 找到该实例所属安全组 → 入站规则 → 添加规则**

| 来源 | 协议端口 | 策略 | 备注 |
|------|----------|------|------|
| `0.0.0.0/0` | **UDP:3478** | 允许 | TURN over UDP（主通道，最快） |
| `0.0.0.0/0` | **TCP:3478** | 允许 | TURN over TCP（封 UDP 的网络兜底） |
| `0.0.0.0/0` | **UDP:49160-49259** | 允许 | TURN relay 中继数据端口段 |

> 中继端口段**必须放行**，这是最常见的遗漏：光放 3478 的话，
> TURN 分配（Allocate）会成功，但两端的中继数据发不进来，ICE 依旧失败。
>
> 为什么收窄到 100 个端口：安全组一条规则能表达的范围有限，且端口段过大不易审计。
> 若并发连接很多（>50 对同时走中继），再适当扩大 `min-port`/`max-port`。

**怎么确认安全组是不是拦住了**：从外网对比测试多个端口（本机 PowerShell）：

```powershell
foreach ($p in @(80,443,3478)) {
  Test-NetConnection -ComputerName 43.108.9.6 -Port $p -InformationLevel Quiet
}
```

如果 `80/443` 通而 `3478` 不通，同时服务器上 `ss -lntup | grep 3478` 有监听、`ufw status` 有放行，
那拦截点就一定是安全组。

---

## 6. 接入应用（环境变量）

编辑 `/opt/workspace/ai-cast-hub/server/.env`（PM2 的 `exec cwd` 就是这个目录，`dotenv` 从这里加载）：

```bash
TURN_SERVER=turn:cast.zhoushengen.xyz:3478?transport=udp,turn:cast.zhoushengen.xyz:3478?transport=tcp
TURN_USERNAME=ai_cast
TURN_CREDENTIAL=<与 /root/.turn-credential 一致>
```

`TURN_SERVER` **支持逗号分隔的多个传输方式**（`turnConfig.js` 会拆成 `urls` 数组下发）。
客户端（Chrome / flutter_webrtc）都会依次尝试，哪个通就用哪个。

> ⚠️ **不要**在未部署 coturn 时填 `turn:localhost:3478` 之类的占位值。
> 客户端会去连一个永远不通的地址并等待超时，比不下发 TURN 更慢。
> 未部署时三个变量全部留空。

改完重启服务：

```bash
pm2 restart ai-cast-server --update-env
pm2 logs ai-cast-server --lines 30 --nostream | grep TURN
# 期望看到：[TURN] TURN 服务器已配置（2 个传输方式）: turn:...
```

客户端**无需改代码**：Web（`pc-web/src/composables/useWebRTC.js` 的 `fetchIceServers`）
与 App（`message_service.dart` / `cast_service.dart` 的 `_fetchIceServers`）
都是启动连接时从 `/api/v1/webrtc/config` 现取的。

---

## 7. 验证清单

按顺序全部通过才算部署完成：

```bash
# ① 服务在跑且在监听
systemctl is-active coturn
ss -lntup | grep -E ':(3478|49160)'

# ② ufw 已放行
ufw status | grep -E '3478|49160'

# ③ 本机功能自测（配置+口令+relay 都正常）
turnutils_uclient -y -u ai_cast -w "$(cat /root/.turn-credential)" -p 3478 127.0.0.1 | tail -5

# ④ 云安全组（只能从外网测）
```

```powershell
# ⑤ 外网可达性（在客户端所在网络执行，最有说服力）
node scripts/check-turn.js "turn:cast.zhoushengen.xyz:3478?transport=udp,turn:cast.zhoushengen.xyz:3478?transport=tcp"
```

```bash
# ⑥ 服务端已下发 TURN
curl -s https://cast.zhoushengen.xyz/api/v1/webrtc/config -H "X-Device-UUID: <已注册UUID>" | jq .
```

⑦ 真机复测：手机 + PC 在同一网络下点「连接消息通道 / 开始投屏」，
连上后到 `chrome://webrtc-internals` 确认 `selected candidate pair` 是 `relay`，
`relay` 说明走的是中继（P2P 打不通时的预期结果，属正常）。

---

## 8. 常见故障排查

| 现象 | 原因 | 处理 |
|------|------|------|
| `/webrtc/config` 只有 1 条 | `.env` 没配或为空 | 检查 `server/.env` 的 `TURN_*`，`pm2 restart --update-env` |
| 外网 3478 不通，服务器上却在监听 | **云安全组未放行** | 见 §5 |
| 外网 3478 通，客户端仍连不上 | relay 端口段 `49160-49259/udp` 未放行 | 见 §5 表格第三行 |
| 客户端拿到的是 `172.19.x.x` 的中继地址 | `external-ip` 写错/缺失 | 必须是 `external-ip=43.108.9.6/172.19.30.32` |
| `turnutils_uclient` 报 `Either -e peer_address or -y` | 少了 `-y` | 加 `-y` |
| `turnutils_uclient` 报 `Cannot allocate` | 口令不一致 或 relay 端口段被 ufw 拦 | 核对 `/etc/turnserver.conf` 与 `.env` 的 `TURN_CREDENTIAL`；`ufw status` |
| coturn 启动失败，`systemctl status` 报配置错 | `/etc/default/coturn` 未开 `TURNSERVER_ENABLED=1` | 见 §4.3 |
| 服务器上 `curl 自己的公网IP:3478` 不通 | 该 NAT 不支持回环 | **正常现象**，不要用它判断服务好坏 |
| 日志文件无内容 | coturn 以 `turnserver` 用户运行，无权写 `/var/log/turnserver.log` | `chown turnserver:turnserver /var/log/turnserver.log` |
| 客户端一直转圈、ICE `failed` | P2P 打不通且未下发 TURN | 看 `chrome://webrtc-internals` 里有没有 `relay` 候选 |

---

## 9. 运维备忘

### 9.1 日志

```bash
tail -f /var/log/turnserver.log
```

日志里出现 `session ... allocated` / `relay` 字样说明有客户端在用中继。
需要更详细的信息时，在 `/etc/turnserver.conf` 里临时加 `verbose` 并重启（调试完记得去掉，避免日志膨胀）。

### 9.2 增删用户 / 改口令

```bash
# 方式一：直接改配置文件再重启
sed -i 's/^user=ai_cast:.*/user=ai_cast:<新口令>/' /etc/turnserver.conf
printf '%s' '<新口令>' > /root/.turn-credential
systemctl restart coturn
# 同步改 server/.env 的 TURN_CREDENTIAL 后重启 Node
pm2 restart ai-cast-server --update-env
```

```bash
# 方式二：用 turnadmin 写 SQLite 用户库
turnadmin -a -u ai_cast -p '<新口令>' -r ai-cast-hub
```

### 9.3 中继端口段调整

改 `min-port`/`max-port` 后**必须同步**改两处：`ufw` 规则 + 云安全组。三者不一致就会出现「分配成功但数据不通」。

### 9.4 需要更强的穿透力时（TURN over TLS）

企业网络若连 UDP 与 TCP:3478 都封，只能走 `turns:`（TLS，通常伪装在 443/5349 上）：

```bash
# 1) /etc/turnserver.conf 增加（去掉 no-tls）
tls-listening-port=5349
cert=/etc/coturn/certs/fullchain.pem
pkey=/etc/coturn/certs/privkey.pem

# 2) 证书：coturn 以 turnserver 用户运行，需复制一份可读的
mkdir -p /etc/coturn/certs
cp /etc/letsencrypt/live/cast.zhoushengen.xyz/fullchain.pem /etc/coturn/certs/
cp /etc/letsencrypt/live/cast.zhoushengen.xyz/privkey.pem  /etc/coturn/certs/
chown -R turnserver:turnserver /etc/coturn/certs
chmod 640 /etc/coturn/certs/*
# 3) ufw / 安全组放行 TCP 5349
# 4) TURN_SERVER 追加：,turns:cast.zhoushengen.xyz:5349?transport=tcp
```

**注意 443 不能给 coturn**——本机 443 已被 nginx 占用（证书续期也依赖它）。用 5349 更省事。
另外 certbot 续期后需要重新拷贝证书，建议加一个 `--deploy-hook` 自动同步。

### 9.5 凭证安全

`TURN_CREDENTIAL` 是长期固定口令。更推荐 `use-auth-secret` + TURN REST API 生成**临时凭证**
（客户端用 `username=<过期时间戳>:<标识>` + `credential=<HMAC-SHA1>` 申请），
这样即使口令泄漏也能通过改密钥立刻失效。当前规模下静态口令可以接受。
