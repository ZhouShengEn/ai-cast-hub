/**
 * WebRTC 会话管理器
 *
 * 内存中维护房间状态:
 * Map<roomId, { deviceA, deviceB, type, createdAt }>
 *
 * 支持:
 * - 房间创建/查询/删除
 * - 获取对方设备
 * - 过期房间自动清理
 */

const { generateShortId } = require('../../utils/uid');
const logger = require('../../utils/logger');

/** @type {Map<string, {roomId: string, deviceA: string, deviceB: string, type: string, createdAt: number}>} */
const rooms = new Map();

/**
 * 创建房间
 * @param {string} deviceA - 设备 A UUID
 * @param {string} deviceB - 设备 B UUID
 * @param {string} type - 房间类型 (cast/file/chat)
 * @returns {{ roomId: string, deviceA: string, deviceB: string, type: string, createdAt: number }}
 */
function createRoom(deviceA, deviceB, type = 'cast') {
  const roomId = `room_${generateShortId(10)}`;

  const room = {
    roomId,
    deviceA,
    deviceB,
    type,
    createdAt: Date.now(),
  };

  rooms.set(roomId, room);
  logger.debug(`[SessionManager] 房间创建: ${roomId} (当前房间数: ${rooms.size})`);
  return room;
}

/**
 * 获取房间信息
 * @param {string} roomId - 房间 ID
 * @returns {object|undefined} 房间对象
 */
function getRoom(roomId) {
  return rooms.get(roomId);
}

/**
 * 获取房间中指定设备的对方设备 UUID
 * @param {string} roomId - 房间 ID
 * @param {string} currentDevice - 当前设备 UUID
 * @returns {string|null} 对方设备 UUID 或 null
 */
function getPeerDevice(roomId, currentDevice) {
  const room = rooms.get(roomId);
  if (!room) return null;

  if (room.deviceA === currentDevice) return room.deviceB;
  if (room.deviceB === currentDevice) return room.deviceA;
  return null;
}

/**
 * 删除房间
 * @param {string} roomId - 房间 ID
 * @returns {boolean} 是否删除成功
 */
function removeRoom(roomId) {
  const existed = rooms.has(roomId);
  rooms.delete(roomId);
  if (existed) {
    logger.debug(`[SessionManager] 房间删除: ${roomId} (当前房间数: ${rooms.size})`);
  }
  return existed;
}

/**
 * 清理过期房间
 * @param {number} [maxAge=600000] - 最大存活时间（毫秒），默认10分钟
 * @returns {number} 清理的房间数
 */
function cleanupExpired(maxAge = 600000) {
  const now = Date.now();
  let cleaned = 0;

  for (const [roomId, room] of rooms) {
    if (now - room.createdAt > maxAge) {
      rooms.delete(roomId);
      cleaned++;
    }
  }

  if (cleaned > 0) {
    logger.info(`[SessionManager] 已清理 ${cleaned} 个过期房间 (当前房间数: ${rooms.size})`);
  }
  return cleaned;
}

/**
 * 获取当前房间总数
 * @returns {number}
 */
function getRoomCount() {
  return rooms.size;
}

module.exports = {
  createRoom,
  getRoom,
  getPeerDevice,
  removeRoom,
  cleanupExpired,
  getRoomCount,
};
