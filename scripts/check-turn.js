#!/usr/bin/env node
/**
 * STUN / TURN 服务器可达性自检
 *
 * 用途：判断**当前所在网络**到 ICE 服务器的 UDP / TCP / TLS 是否通。
 * WebRTC 打不通时，先跑这个脚本，能立刻区分两类原因：
 *   1) 网络到 TURN 不通（企业网关封 UDP、或安全组没放行）→ 换传输方式或改防火墙
 *   2) 网络到 TURN 通，但 ICE 仍失败        → 问题在候选交换 / 对端，不在网络
 *
 * 用法：
 *   node scripts/check-turn.js
 *   node scripts/check-turn.js turn:your.domain:3478
 *   node scripts/check-turn.js "turn:your.domain:3478?transport=udp,turn:your.domain:3478?transport=tcp"
 *   TURN_SERVER="turn:your.domain:3478" node scripts/check-turn.js
 *
 * 原理：RFC 5389 的 STUN Binding Request **无需鉴权**，coturn / 公共 STUN 都会回
 * Binding Success Response，响应里带 XOR-MAPPED-ADDRESS（即本机出口地址）。
 * 因此本脚本可以证明「网络可达 + 服务在监听」，但不能校验 TURN 账号密码是否正确。
 */

'use strict';

const dgram = require('dgram');
const net = require('net');
const tls = require('tls');
const dns = require('dns');
const { randomBytes } = require('crypto');

const MAGIC_COOKIE = Buffer.from([0x21, 0x12, 0xa4, 0x42]);
const DEFAULT_TARGETS = ['stun:stun.l.google.com:19302'];
const TIMEOUT_MS = Number(process.env.CHECK_TIMEOUT_MS || 3000);

/** 默认端口 */
const DEFAULT_PORTS = {
  stun: 3478,
  stuns: 5349,
  turn: 3478,
  turns: 5349,
};

/**
 * 解析 "turn:host:3478?transport=tcp" 这类 URL
 * @returns {{scheme:string,host:string,port:number,transport:'udp'|'tcp',tls:boolean,raw:string}|null}
 */
function parseServerUrl(raw) {
  const text = String(raw || '').trim();
  const match = /^(stun|stuns|turn|turns):([^?]+)(\?.*)?$/i.exec(text);
  if (!match) return null;

  const scheme = match[1].toLowerCase();
  let hostPort = match[2];
  const query = match[3] || '';

  // IPv6 形如 turn:[::1]:3478
  let host = '';
  let port = DEFAULT_PORTS[scheme];
  const v6 = /^\[([^\]]+)\](?::(\d+))?$/.exec(hostPort);
  if (v6) {
    host = v6[1];
    if (v6[2]) port = Number(v6[2]);
  } else {
    const idx = hostPort.lastIndexOf(':');
    if (idx > -1) {
      host = hostPort.slice(0, idx);
      port = Number(hostPort.slice(idx + 1)) || port;
    } else {
      host = hostPort;
    }
  }

  const transportParam = /transport=(\w+)/i.exec(query);
  const isTls = scheme === 'stuns' || scheme === 'turns';
  return {
    scheme,
    host,
    port,
    transport: transportParam ? transportParam[1].toLowerCase() : 'udp',
    tls: isTls,
    raw: text,
  };
}

/** 构造 STUN Binding Request（20 字节） */
function buildBindingRequest() {
  const buf = Buffer.alloc(20);
  buf.writeUInt16BE(0x0001, 0); // Binding Request
  buf.writeUInt16BE(0x0000, 2); // message length
  MAGIC_COOKIE.copy(buf, 4);
  randomBytes(12).copy(buf, 8); // transaction id
  return buf;
}

/** 从 STUN 响应里取 XOR-MAPPED-ADDRESS / MAPPED-ADDRESS */
function parseMappedAddress(msg) {
  if (msg.length < 20) return null;
  const msgType = msg.readUInt16BE(0);
  if (msgType !== 0x0101) return null; // 只认 Binding Success Response

  const total = 20 + msg.readUInt16BE(2);
  let offset = 20;
  const txId = msg.subarray(8, 20);

  while (offset + 4 <= Math.min(total, msg.length)) {
    const attrType = msg.readUInt16BE(offset);
    const attrLen = msg.readUInt16BE(offset + 2);
    const value = msg.subarray(offset + 4, offset + 4 + attrLen);

    // 0x0020 XOR-MAPPED-ADDRESS，0x0001 MAPPED-ADDRESS
    if (attrType === 0x0020 || attrType === 0x0001) {
      const isXor = attrType === 0x0020;
      const family = value[1];
      let port = value.readUInt16BE(2);
      if (isXor) port ^= 0x2112;

      if (family === 0x01 && value.length >= 8) {
        const addr = Buffer.from(value.subarray(4, 8));
        if (isXor) {
          for (let i = 0; i < 4; i += 1) addr[i] ^= MAGIC_COOKIE[i];
        }
        return `${addr.join('.')}:${port}`;
      }
      if (family === 0x02 && value.length >= 20) {
        const addr = Buffer.from(value.subarray(4, 20));
        if (isXor) {
          for (let i = 0; i < 16; i += 1) {
            addr[i] ^= i < 4 ? MAGIC_COOKIE[i] : txId[i - 4];
          }
        }
        const hex = addr.toString('hex').match(/.{1,4}/g) || [];
        return `[${hex.join(':')}]:${port}`;
      }
    }
    offset += 4 + attrLen + ((4 - (attrLen % 4)) % 4); // 4 字节对齐
  }
  return null;
}

function resolveHost(host) {
  return new Promise((resolve, reject) => {
    // families: 4 优先 IPv4，很多云主机没有 AAAA 记录
    dns.lookup(host, { family: 4 }, (err, address) => {
      if (err) reject(err);
      else resolve(address);
    });
  });
}

/** UDP：发 STUN Binding 请求，收到响应即视为可达 */
function testUdp(address, port) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket('udp4');
    const request = buildBindingRequest();
    const startedAt = Date.now();
    let done = false;

    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        socket.close();
      } catch (_) {
        /* ignore */
      }
      resolve(result);
    };

    const timer = setTimeout(
      () => finish({ ok: false, detail: `UDP 无响应（${TIMEOUT_MS}ms 超时）` }),
      TIMEOUT_MS,
    );

    socket.on('message', (msg) => {
      const mapped = parseMappedAddress(msg);
      finish({
        ok: true,
        detail: mapped
          ? `STUN 响应正常，本机出口地址 ${mapped}`
          : '收到非 STUN 响应（端口可达但不是标准 STUN/TURN 服务）',
        rttMs: Date.now() - startedAt,
      });
    });

    socket.on('error', (err) => finish({ ok: false, detail: `UDP 错误: ${err.message}` }));

    socket.send(request, 0, request.length, port, address, (err) => {
      if (err) finish({ ok: false, detail: `UDP 发送失败: ${err.message}` });
    });
  });
}

/** TCP / TLS：能建连即视为可达 */
function testStream(address, port, useTls) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        socket.destroy();
      } catch (_) {
        /* ignore */
      }
      resolve(result);
    };

    const socket = useTls
      ? tls.connect({ host: address, port, rejectUnauthorized: false, servername: address })
      : net.connect({ host: address, port });

    const timer = setTimeout(
      () => finish({ ok: false, detail: `TCP 建连超时（${TIMEOUT_MS}ms）` }),
      TIMEOUT_MS,
    );

    socket.once('connect', () => {
      finish({
        ok: true,
        detail: useTls ? 'TLS 握手成功（TCP 可达）' : 'TCP 建连成功',
        rttMs: Date.now() - startedAt,
      });
    });
    socket.once('secureConnect', () => {
      finish({ ok: true, detail: 'TLS 握手成功', rttMs: Date.now() - startedAt });
    });
    socket.once('error', (err) => finish({ ok: false, detail: `${useTls ? 'TLS' : 'TCP'} 错误: ${err.message}` }));
  });
}

async function checkTarget(target) {
  const label = `${target.transport.toUpperCase()}${target.tls ? '+TLS' : ''}`;
  let address;
  try {
    address = await resolveHost(target.host);
  } catch (err) {
    return { ok: false, line: `${target.raw}  [${label}]  DNS 解析失败: ${err.message}` };
  }

  const result =
    target.transport === 'udp'
      ? await testUdp(address, target.port)
      : await testStream(address, target.port, target.tls);

  const flag = result.ok ? 'OK  ' : 'FAIL';
  const rtt = result.rttMs ? ` (${result.rttMs}ms)` : '';
  return {
    ok: result.ok,
    line: `[${flag}] ${target.raw}\n         → ${address}:${target.port} ${target.transport.toUpperCase()}${rtt} · ${result.detail}`,
  };
}

async function main() {
  const fromArgs = process.argv.slice(2).join(',');
  const fromEnv = process.env.TURN_SERVER || '';
  const rawList = fromArgs || fromEnv || DEFAULT_TARGETS.join(',');

  const targets = rawList
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map(parseServerUrl)
    .filter(Boolean);

  if (!targets.length) {
    console.error('没有可用的检查目标。用法: node scripts/check-turn.js turn:host:3478');
    process.exit(2);
  }

  console.log('STUN/TURN 可达性自检');
  console.log(`超时 ${TIMEOUT_MS}ms（可用 CHECK_TIMEOUT_MS 调整）\n`);

  let allOk = true;
  for (const target of targets) {
    // eslint-disable-next-line no-await-in-loop
    const result = await checkTarget(target);
    if (!result.ok) allOk = false;
    console.log(result.line);
  }

  console.log('');
  if (allOk) {
    console.log('结论：到 ICE 服务器的网络可达。若 WebRTC 仍失败，问题不在网络层。');
  } else {
    console.log('结论：存在不可达的传输方式。');
    console.log('  · UDP FAIL  → 网关大概率封了 UDP，请在 TURN_SERVER 里补 ?transport=tcp');
    console.log('  · TCP FAIL  → 安全组 / ufw 未放行该端口，或 coturn 未监听');
    console.log('  · 全部 FAIL → 服务器 IP / 端口配错，或服务未启动');
  }
  process.exit(allOk ? 0 : 1);
}

main().catch((err) => {
  console.error('自检异常:', err);
  process.exit(2);
});
