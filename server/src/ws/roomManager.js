/**
 * WebSocket 房间管理器
 *
 * 维护 WebSocket 连接级别的房间状态:
 * Map<roomId, { clients: Map<deviceUuid, ws>, type, createdAt }>
 *
 * 与 services/webrtc/sessionManager.js 协作:
 * - sessionManager 管理业务逻辑层面的房间
 * - roomManager 管理 WebSocket 连接层面的房间
 */

const logger = require('../utils/logger');

/** @type {Map<string, {roomId: string, clients: Map<string, import('ws').WebSocket>, type: string, createdAt: number}>} */
const rooms = new Map();

/**
 * 创建房间并注册客户端连接
 * @param {string} roomId - 房间 ID
 * @param {string} deviceUuid - 设备 UUID
 * @param {import('ws').WebSocket} ws - WebSocket 连接
 * @param {string} [type='cast'] - 房间类型
 */
function joinRoom(roomId, deviceUuid, ws, type = 'cast') {
  if (!rooms.has(roomId)) {
    rooms.set(roomId, {
      roomId,
      clients: new Map(),
      type,
      createdAt: Date.now(),
    });
    logger.debug(`[WS RoomManager] 房间创建: ${roomId} type=${type}`);
  }

  const room = rooms.get(roomId);
  room.clients.set(deviceUuid, ws);
  logger.debug(`[WS RoomManager] 设备 ${deviceUuid} 加入房间 ${roomId} (当前成员: ${room.clients.size})`);
}

/**
 * 获取房间信息
 * @param {string} roomId - 房间 ID
 * @returns {object|undefined}
 */
function getRoom(roomId) {
  return rooms.get(roomId);
}

/**
 * 获取房间中指定设备的对方 WebSocket 连接
 * @param {string} roomId - 房间 ID
 * @param {string} myDeviceUuid - 我的设备 UUID
 * @returns {import('ws').WebSocket|null} 对方的 WS 连接或 null
 */
function getPeer(roomId, myDeviceUuid) {
  const room = rooms.get(roomId);
  if (!room) return null;

  for (const [deviceUuid, ws] of room.clients) {
    if (deviceUuid !== myDeviceUuid) {
      return ws;
    }
  }
  return null;
}

/**
 * 从房间中移除设备
 * @param {string} roomId - 房间 ID
 * @param {string} deviceUuid - 设备 UUID
 */
function leaveRoom(roomId, deviceUuid) {
  const room = rooms.get(roomId);
  if (!room) return;

  room.clients.delete(deviceUuid);
  logger.debug(`[WS RoomManager] 设备 ${deviceUuid} 离开房间 ${roomId}`);

  // 如果房间已空，删除房间
  if (room.clients.size === 0) {
    rooms.delete(roomId);
    logger.debug(`[WS RoomManager] 房间已空删除: ${roomId}`);
  }
}

/**
 * 删除房间并通知残留客户端
 * @param {string} roomId - 房间 ID
 */
function removeRoom(roomId) {
  const room = rooms.get(roomId);
  if (!room) return;

  // 通知所有客户端房间已关闭
  for (const [deviceUuid, ws] of room.clients) {
    try {
      if (ws.readyState === 1) { // WebSocket.OPEN
        ws.send(JSON.stringify({
          type: 'room_closed',
          roomId,
          payload: { reason: 'room_removed' },
        }));
      }
    } catch (err) {
      logger.warn(`[WS RoomManager] 通知设备 ${deviceUuid} 失败: ${err.message}`);
    }
  }

  rooms.delete(roomId);
  logger.info(`[WS RoomManager] 房间已删除: ${roomId} (当前房间数: ${rooms.size})`);
}

/**
 * 清理过期房间
 * @param {number} [maxAge=600000] - 最大存活时间（毫秒）
 * @returns {number} 清理的房间数
 */
function cleanupExpired(maxAge = 600000) {
  const now = Date.now();
  let cleaned = 0;

  for (const [roomId, room] of rooms) {
    if (now - room.createdAt > maxAge) {
      removeRoom(roomId);
      cleaned++;
    }
  }

  if (cleaned > 0) {
    logger.info(`[WS RoomManager] 已清理 ${cleaned} 个过期房间 (当前房间数: ${rooms.size})`);
  }
  return cleaned;
}

/**
 * 获取设备所在的所有房间 ID
 * @param {string} deviceUuid - 设备 UUID
 * @returns {Array<string>} 房间 ID 列表
 */
function getDeviceRooms(deviceUuid) {
  const deviceRooms = [];
  for (const [roomId, room] of rooms) {
    if (room.clients.has(deviceUuid)) {
      deviceRooms.push(roomId);
    }
  }
  return deviceRooms;
}

/**
 * 获取当前房间总数
 * @returns {number}
 */
function getRoomCount() {
  return rooms.size;
}

module.exports = {
  joinRoom,
  getRoom,
  getPeer,
  leaveRoom,
  removeRoom,
  cleanupExpired,
  getDeviceRooms,
  getRoomCount,
};
