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
const { handleMessage } = require('./handler');
const logger = require('../utils/logger');

/** deviceUuid → ws 映射（用于查找连接） */
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
          payload: { deviceUuid: affectedUuid, status },
        });
      }
    })
    .catch(() => {});
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
  broadcastDeviceStatus(deviceUuid, 'online');
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
    // 重连成功则不广播离线
    if (deviceConnections.has(deviceUuid)) return;
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
function initWebSocket(server) {
  const wss = new WebSocketServer({ server, path: '/ws' });

  logger.info('[WS] WebSocket 服务已挂载到 /ws');

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

    // 认证通过 → 注册连接
    deviceConnections.set(deviceUuid, ws);
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
    ws.on('message', (data) => {
      try {
        const message = JSON.parse(data.toString());

        const getWsByDeviceUuid = (targetDeviceUuid) => {
          return deviceConnections.get(targetDeviceUuid);
        };

        const response = handleMessage(ws, deviceUuid, message, getWsByDeviceUuid);

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
      const rooms = roomManager.getDeviceRooms(deviceUuid);
      const notify = (device, msg) => {
        const clientWs = deviceConnections.get(device);
        if (clientWs && clientWs.readyState === 1) {
          try { clientWs.send(JSON.stringify(msg)); } catch (_) {}
        }
      };

      for (const roomId of rooms) {
        signaling.closeRoom(roomId, notify);
        roomManager.removeRoom(roomId);
      }

      deviceConnections.delete(deviceUuid);
      logger.info(`[WS] 设备断开: ${deviceUuid} code=${code} (当前连接数: ${deviceConnections.size})`);

      // 延迟广播 offline（宽限期容忍网络抖动，重连会取消）
      scheduleOfflineBroadcast(deviceUuid);
    });

    // 连接错误
    ws.on('error', (err) => {
      logger.error(`[WS] 连接错误: ${deviceUuid} - ${err.message}`);
      deviceConnections.delete(deviceUuid);
    });
  });

  // 心跳检测定时器
  const heartbeatTimer = setInterval(() => {
    for (const [deviceUuid, ws] of deviceConnections) {
      if (ws._isAlive === false) {
        logger.warn(`[WS] 心跳超时，断开: ${deviceUuid}`);
        deviceConnections.delete(deviceUuid);
        // 清理房间
        const rooms = roomManager.getDeviceRooms(deviceUuid);
        for (const roomId of rooms) {
          roomManager.leaveRoom(roomId, deviceUuid);
        }
        ws.terminate();
        // 延迟广播 offline（宽限期容忍网络抖动，重连会取消）
        scheduleOfflineBroadcast(deviceUuid);
        continue;
      }

      ws._isAlive = false;
      ws.ping();
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
  const ws = deviceConnections.get(deviceUuid);
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify(message));
    return true;
  }
  return false;
}

module.exports = { initWebSocket, getConnectionCount, sendToDevice };
