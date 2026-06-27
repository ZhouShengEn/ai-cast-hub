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
        continue;
      }

      ws._isAlive = false;
      ws.ping();
    }
  }, HEARTBEAT_INTERVAL);

  wss.on('close', () => {
    clearInterval(heartbeatTimer);
    clearInterval(roomCleanupTimer);
    deviceConnections.clear();
    logger.info('[WS] WebSocket 服务已关闭');
  });

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
