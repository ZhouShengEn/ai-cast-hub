/**
 * WebSocket 服务初始化
 *
 * 挂载到 HTTP server:
 * - 连接时验证设备身份（URL 参数: deviceUuid + transferKey）
 * - 认证通过 → 注册到 roomManager，发送 connected 确认
 * - 认证失败 → 发送 error 消息，关闭连接
 * - 30s 心跳（服务器主动 ping）
 * - on close → 清理所在房间
 */

const { WebSocketServer } = require('ws');
const DeviceModel = require('../models/Device');
const roomManager = require('./roomManager');
const signaling = require('../services/webrtc/signaling');
const sessionManager = require('../services/webrtc/sessionManager');
const { handleMessage, resendPendingCommands } = require('./handler');
const logger = require('../utils/logger');

/**
 * deviceUuid → Set<ws> 映射（用于查找连接）。
 * 一个设备可对应多个 WebSocket 连接，以支持 PC 多标签页 / 多端同时在线，
 * 解决「A 端标记离线、B 端状态不同步」与「重连后陈旧 ws 引用」问题（P1-8 / P1-9）。
 */
const deviceConnections = new Map();

/** 心跳参数 */
const HEARTBEAT_INTERVAL = 30000; // 30s
const CLIENT_TIMEOUT = 60000;     // 60s 无 pong 响应则断开

/**
 * 设备离线宽限时间：断开后延迟广播 offline，期间若重连成功则取消广播，
 * 以容忍网络抖动造成的短暂断连（不立即标记离线）。
 */
const OFFLINE_GRACE_MS = 8000;

/**
 * 设备离线超过该时长（毫秒）则自动解除绑定关系并通知两端。
 */
const AUTO_UNBIND_THRESHOLD_MS = 10 * 60 * 1000;

/** deviceUuid → 离线宽限定时器（用于重连时取消广播） */
const offlineGraceTimers = new Map();

/**
 * 向某设备的已配对设备广播上下线状态事件
 * @param {string} affectedUuid - 发生上下线的设备 UUID
 * @param {'online'|'offline'} status - 状态
 */
function broadcastDeviceStatus(affectedUuid, status) {
  DeviceModel.getPairedDevices(affectedUuid)
    .then((paired) => {
      for (const p of paired) {
        sendToDevice(p.device_uuid, {
          type: 'device_status',
          payload: {
            deviceUuid: affectedUuid,
            status,
            // 离线时告诉对端「绑定仍在，等待重连」，Web 端据此显示“待重连”
            // 而不是把设备当成已解绑（P1-4）
            bound: true,
          },
        });
      }
    })
    .catch(() => {});
}

/**
 * 设备（重新）上线后的自动重连绑定（P1-4）
 *
 * 后端持久化了「设备 UUID ↔ 传输密钥 ↔ 绑定关系」，设备下线不会删除绑定。
 * 当设备重新建立 WebSocket 连接（已通过 transferKey 鉴权）时，
 * 后端主动向双方推送 device_rebind，App / Web 无需任何手动操作即可恢复配对。
 *
 * 安全性：密钥校验发生在 WS 连接阶段（ws/index.js 认证分支），
 * 密钥不匹配的连接会被 4003 关闭，根本走不到这里，天然不会误绑定。
 *
 * @param {string} deviceUuid - 刚上线的设备 UUID
 */
async function autoRebindOnConnect(deviceUuid) {
  try {
    const paired = await DeviceModel.getPairedDevices(deviceUuid);
    const self = await DeviceModel.findByUuid(deviceUuid);
    for (const p of paired) {
      const boundAt = DeviceModel.getBoundAt(deviceUuid, p.device_uuid);
      // 通知刚上线的设备：你与 p 仍处于绑定关系
      sendToDevice(deviceUuid, {
        type: 'device_rebind',
        payload: {
          deviceUuid: p.device_uuid,
          deviceName: p.device_name,
          platform: p.platform,
          isOnline: DeviceModel.isLive(p.device_uuid),
          boundAt,
          reason: 'auto',
        },
      });
      // 通知对端：该设备已重新上线
      sendToDevice(p.device_uuid, {
        type: 'device_rebind',
        payload: {
          deviceUuid,
          deviceName: self ? self.device_name : undefined,
          platform: self ? self.platform : undefined,
          isOnline: true,
          boundAt,
          reason: 'auto',
        },
      });
    }
    if (paired.length > 0) {
      logger.info(
        `[WS] 设备 ${deviceUuid} 重新上线，已自动恢复 ${paired.length} 条绑定关系 (device_rebind)`,
      );
    }
  } catch (e) {
    logger.warn(`[WS] 自动重连处理失败: ${e.message}`);
  }
}

/**
 * 设备（重新）连接成功：取消待广播的 offline，并向已配对设备推送 online。
 * @param {string} deviceUuid
 */
function handleDeviceConnected(deviceUuid) {
  if (offlineGraceTimers.has(deviceUuid)) {
    clearTimeout(offlineGraceTimers.get(deviceUuid));
    offlineGraceTimers.delete(deviceUuid);
  }
  DeviceModel.markConnected(deviceUuid);
  broadcastDeviceStatus(deviceUuid, 'online');
  // 设备重新上线：匹配持久化的绑定关系并推送重连指令（P1-4）
  autoRebindOnConnect(deviceUuid);
  // 设备上线后补投离线期间未 ACK 的防盗指令（P1-10）
  try {
    resendPendingCommands(deviceUuid, (uuid, msg) => sendToDevice(uuid, msg));
  } catch (e) {
    logger.warn(`[WS] 补投离线指令失败: ${e.message}`);
  }
}

/**
 * 设备断开：延迟 OFFLINE_GRACE_MS 后，若仍未重连则广播 offline。
 * 宽限期内重连会经 handleDeviceConnected 取消本定时器。
 * @param {string} deviceUuid
 */
function scheduleOfflineBroadcast(deviceUuid) {
  if (offlineGraceTimers.has(deviceUuid)) {
    clearTimeout(offlineGraceTimers.get(deviceUuid));
  }
  const timer = setTimeout(() => {
    offlineGraceTimers.delete(deviceUuid);
    // 重连成功（仍有活跃连接）则不广播离线
    if (deviceConnections.has(deviceUuid)) return;
    DeviceModel.markDisconnected(deviceUuid);
    broadcastDeviceStatus(deviceUuid, 'offline');
    logger.info(`[WS] 设备离线(已确认): ${deviceUuid}`);
  }, OFFLINE_GRACE_MS);
  offlineGraceTimers.set(deviceUuid, timer);
}

/**
 * 扫描离线超过阈值的设备，自动解除绑定并通知两端。
 * 依赖 last_seen_at（连接期间随 pong 刷新），故在线设备不会误判。
 */
async function scanAutoUnbind() {
  try {
    const all = await DeviceModel.listAll();
    const now = Date.now();
    for (const d of all) {
      // 仍在线则跳过
      if (deviceConnections.has(d.device_uuid)) continue;
      const lastSeen = new Date(d.last_seen_at).getTime();
      if (now - lastSeen < AUTO_UNBIND_THRESHOLD_MS) continue;

      const paired = await DeviceModel.getPairedDevices(d.device_uuid);
      if (paired.length === 0) continue;

      for (const p of paired) {
        await DeviceModel.unbindDevices(d.device_uuid, p.device_uuid);
        // 通知对端：d 已与你解绑（对端按 fromDeviceUuid 移除 d）
        sendToDevice(p.device_uuid, {
          type: 'device_unbound',
          payload: {
            fromDeviceUuid: d.device_uuid,
            reason: 'auto',
            message: '对方设备离线超过10分钟，已自动解除绑定',
          },
        });
        // 通知离线端 d：你与 p 已解绑（d 按 fromDeviceUuid 移除 p）
        sendToDevice(d.device_uuid, {
          type: 'device_unbound',
          payload: {
            fromDeviceUuid: p.device_uuid,
            reason: 'auto',
            message: '你离线超过10分钟，已自动解除绑定',
          },
        });
      }
      logger.info(`[WS] 设备 ${d.device_uuid} 离线超过10分钟，已自动解除与其 ${paired.length} 个配对设备的解绑`);
    }
  } catch (e) {
    logger.error(`[WS] 自动解绑扫描失败: ${e.message}`);
  }
}

/**
 * 初始化 WebSocket 服务
 * @param {import('http').Server} server - HTTP Server 实例
 * @returns {import('ws').WebSocketServer} wss 实例
 */
function initWebSocket() {
  // 使用 noServer: 多个 WebSocketServer 共享同一 http server 时，server 选项会各自注册
  // 不过滤 path 的 upgrade 监听器，导致同一次连接被双处理 → 帧解析错误。
  // 统一 upgrade 路由在 src/index.js 中按 path 分发到本 server。
  const wss = new WebSocketServer({ noServer: true });

  logger.info('[WS] WebSocket 服务已挂载到 /ws');

  // 捕获 WebSocketServer 层错误，避免未处理的 'error' 事件冒泡成 uncaughtException 致进程退出
  wss.on('error', (err) => {
    logger.error(`[WS] WebSocketServer 错误: ${err.message}`);
  });

  wss.on('connection', async (ws, req) => {
    // 解析 URL 参数
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const deviceUuid = url.searchParams.get('deviceUuid');
    const transferKey = url.searchParams.get('transferKey');

    logger.debug(`[WS] 新连接: deviceUuid=${deviceUuid}`);

    // 验证参数
    if (!deviceUuid || !transferKey) {
      ws.send(JSON.stringify({
        type: 'error',
        roomId: null,
        payload: { message: '缺少 deviceUuid 或 transferKey 参数' },
      }));
      ws.close(4001, '缺少认证参数');
      return;
    }

    // 验证设备身份
    try {
      const device = await DeviceModel.findByUuid(deviceUuid);

      if (!device) {
        ws.send(JSON.stringify({
          type: 'error',
          roomId: null,
          payload: { message: '设备未注册' },
        }));
        ws.close(4002, '设备未注册');
        return;
      }

      if (device.transfer_key !== transferKey) {
        ws.send(JSON.stringify({
          type: 'error',
          roomId: null,
          payload: { message: '传输密钥不匹配' },
        }));
        ws.close(4003, '密钥不匹配');
        return;
      }

      // 更新最后在线时间
      await DeviceModel.updateLastSeen(deviceUuid);
    } catch (err) {
      logger.error(`[WS] 设备认证查询失败: ${err.message}`);
      ws.send(JSON.stringify({
        type: 'error',
        roomId: null,
        payload: { message: '认证服务异常' },
      }));
      ws.close(4000, '认证失败');
      return;
    }

    // 认证通过 → 注册连接（一个 uuid 可对应多个 ws，支持多标签页 / 多端）
    let connSet = deviceConnections.get(deviceUuid);
    if (!connSet) {
      connSet = new Set();
      deviceConnections.set(deviceUuid, connSet);
    }
    connSet.add(ws);
    ws._deviceUuid = deviceUuid;
    ws._isAlive = true;

    // 发送连接确认
    ws.send(JSON.stringify({
      type: 'connected',
      roomId: null,
      payload: {
        deviceUuid,
        message: 'WebSocket 连接已建立',
      },
    }));

    logger.info(`[WS] 设备认证通过: ${deviceUuid} (当前连接数: ${deviceConnections.size})`);

    // 上线：取消待广播的 offline（若为重连），并向已配对设备推送 online 事件
    handleDeviceConnected(deviceUuid);

    // 消息处理
    ws.on('message', async (data) => {
      try {
        const message = JSON.parse(data.toString());

        const getWsByDeviceUuid = (targetDeviceUuid) => {
          return deviceConnections.get(targetDeviceUuid);
        };

        // handleMessage 为 async（防盗指令需异步校验配对关系）
        const response = await handleMessage(ws, deviceUuid, message, getWsByDeviceUuid);

        if (response) {
          ws.send(JSON.stringify(response));
        }
      } catch (err) {
        logger.warn(`[WS] 消息解析失败: ${err.message}`);
        ws.send(JSON.stringify({
          type: 'error',
          roomId: null,
          payload: { message: '消息格式无效' },
        }));
      }
    });

    // pong 响应处理（心跳）
    ws.on('pong', () => {
      ws._isAlive = true;
      // 刷新最后在线时间，保证设备列表 isOnline 准确（连接期间不会误判离线）
      DeviceModel.updateLastSeen(deviceUuid).catch(() => {});
    });

    // 连接关闭
    ws.on('close', (code, reason) => {
      // 从本设备的连接集合中移除本 ws
      const connSet = deviceConnections.get(deviceUuid);
      if (connSet) {
        connSet.delete(ws);
        if (connSet.size === 0) deviceConnections.delete(deviceUuid);
      }

      // 仅当该设备已无任何活跃连接时才清理房间与广播离线，
      // 避免多标签页场景下单个标签关闭误拆其它标签正在使用的房间。
      if (!deviceConnections.has(deviceUuid)) {
        const rooms = roomManager.getDeviceRooms(deviceUuid);
        const notify = (device, msg) => {
          const clients = deviceConnections.get(device);
          if (clients) {
            for (const c of clients) {
              if (c.readyState === 1) {
                try { c.send(JSON.stringify(msg)); } catch (_) {}
              }
            }
          }
        };

        for (const roomId of rooms) {
          signaling.closeRoom(roomId, notify);
          roomManager.removeRoom(roomId);
        }

        logger.info(`[WS] 设备断开: ${deviceUuid} code=${code} (当前设备数: ${deviceConnections.size})`);

        // 延迟广播 offline（宽限期容忍网络抖动，重连会取消）
        scheduleOfflineBroadcast(deviceUuid);
      } else {
        logger.info(`[WS] 设备某连接关闭(仍有其它活跃连接): ${deviceUuid} code=${code}`);
      }
    });

    // 连接错误
    ws.on('error', (err) => {
      logger.error(`[WS] 连接错误: ${deviceUuid} - ${err.message}`);
      // 从设备连接集合中移除本 ws（出错即视为该连接不可用）
      const connSet = deviceConnections.get(deviceUuid);
      if (connSet) {
        connSet.delete(ws);
        if (connSet.size === 0) deviceConnections.delete(deviceUuid);
      }
    });
  });

  // 心跳检测定时器
  const heartbeatTimer = setInterval(() => {
    for (const [deviceUuid, connSet] of deviceConnections) {
      for (const ws of connSet) {
        if (ws._isAlive === false) {
          logger.warn(`[WS] 心跳超时，断开: ${deviceUuid}`);
          // 直接 terminate，由 close 事件统一处理房间清理与离线广播
          try { ws.terminate(); } catch (_) {}
          // 延迟广播 offline（宽限期容忍网络抖动，重连会取消）
          scheduleOfflineBroadcast(deviceUuid);
          continue;
        }

        ws._isAlive = false;
        try { ws.ping(); } catch (_) {}
      }
    }
  }, HEARTBEAT_INTERVAL);

  wss.on('close', () => {
    clearInterval(heartbeatTimer);
    clearInterval(roomCleanupTimer);
    clearInterval(autoUnbindTimer);
    for (const t of offlineGraceTimers.values()) clearTimeout(t);
    offlineGraceTimers.clear();
    deviceConnections.clear();
    logger.info('[WS] WebSocket 服务已关闭');
  });

  // 离线自动解绑定时器（每分钟扫描一次，离线超 10 分钟自动解除绑定并通知两端）
  const autoUnbindTimer = setInterval(() => {
    scanAutoUnbind();
  }, 60 * 1000);

  // 房间过期清理定时器（每5分钟清理超过10分钟无活动的房间）
  const roomCleanupTimer = setInterval(() => {
    sessionManager.cleanupExpired();
    roomManager.cleanupExpired();
  }, 5 * 60 * 1000);

  // 返回 wss 以便外部管理
  return wss;
}

/**
 * 获取设备连接数
 * @returns {number}
 */
function getConnectionCount() {
  return deviceConnections.size;
}

/**
 * 向指定设备发送 WebSocket 消息（供 HTTP 路由调用，如绑定通知）
 * @param {string} deviceUuid - 目标设备 UUID
 * @param {object} message - 消息对象
 * @returns {boolean} 是否发送成功（设备在线且连接打开）
 */
function sendToDevice(deviceUuid, message) {
  const connSet = deviceConnections.get(deviceUuid);
  if (!connSet) return false;
  let sent = false;
  for (const ws of connSet) {
    if (ws.readyState === 1) {
      try {
        ws.send(JSON.stringify(message));
        sent = true;
      } catch (_) {
        // 单条发送失败不影响其它连接
      }
    }
  }
  return sent;
}

module.exports = { initWebSocket, getConnectionCount, sendToDevice };
