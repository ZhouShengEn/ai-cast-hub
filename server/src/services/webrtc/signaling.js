/**
 * WebRTC 信令处理服务
 *
 * 处理 WebRTC 信令消息的转发:
 * - handleOffer: 转发 SDP Offer
 * - handleAnswer: 转发 SDP Answer
 * - handleIceCandidate: 转发 ICE Candidate
 * - createRoom / closeRoom: 房间生命周期
 */

const sessionManager = require('./sessionManager');
const logger = require('../../utils/logger');

/**
 * 处理 SDP Offer
 * @param {string} roomId - 房间 ID
 * @param {string} fromDevice - 发送方设备 UUID
 * @param {object} sdp - SDP 描述
 * @param {function} sendToPeer - 发送消息给对方的回调 (deviceUuid, message) => void
 * @returns {object} 处理结果
 */
function handleOffer(roomId, fromDevice, sdp, sendToPeer) {
  const room = sessionManager.getRoom(roomId);
  if (!room) {
    logger.warn(`[Signaling] 房间不存在: ${roomId}`);
    return { success: false, error: '房间不存在' };
  }

  const peerDevice = sessionManager.getPeerDevice(roomId, fromDevice);
  if (!peerDevice) {
    logger.warn(`[Signaling] 房间 ${roomId} 中找不到对方设备`);
    return { success: false, error: '对方设备不在房间中' };
  }

  sendToPeer(peerDevice, {
    type: 'signal',
    roomId,
    payload: {
      signalType: 'offer',
      from: fromDevice,
      sdp,
    },
  });

  logger.debug(`[Signaling] Offer 已转发: ${fromDevice} → ${peerDevice} room=${roomId}`);
  return { success: true };
}

/**
 * 处理 SDP Answer
 * @param {string} roomId - 房间 ID
 * @param {string} fromDevice - 发送方设备 UUID
 * @param {object} sdp - SDP 描述
 * @param {function} sendToPeer - 发送消息给对方的回调
 * @returns {object} 处理结果
 */
function handleAnswer(roomId, fromDevice, sdp, sendToPeer) {
  const room = sessionManager.getRoom(roomId);
  if (!room) {
    logger.warn(`[Signaling] 房间不存在: ${roomId}`);
    return { success: false, error: '房间不存在' };
  }

  const peerDevice = sessionManager.getPeerDevice(roomId, fromDevice);
  if (!peerDevice) {
    logger.warn(`[Signaling] 房间 ${roomId} 中找不到对方设备`);
    return { success: false, error: '对方设备不在房间中' };
  }

  sendToPeer(peerDevice, {
    type: 'signal',
    roomId,
    payload: {
      signalType: 'answer',
      from: fromDevice,
      sdp,
    },
  });

  logger.debug(`[Signaling] Answer 已转发: ${fromDevice} → ${peerDevice} room=${roomId}`);
  return { success: true };
}

/**
 * 处理 ICE Candidate
 * @param {string} roomId - 房间 ID
 * @param {string} fromDevice - 发送方设备 UUID
 * @param {object} candidate - ICE Candidate 对象
 * @param {function} sendToPeer - 发送消息给对方的回调
 * @returns {object} 处理结果
 */
function handleIceCandidate(roomId, fromDevice, candidate, sendToPeer) {
  const room = sessionManager.getRoom(roomId);
  if (!room) {
    logger.warn(`[Signaling] 房间不存在: ${roomId}`);
    return { success: false, error: '房间不存在' };
  }

  const peerDevice = sessionManager.getPeerDevice(roomId, fromDevice);
  if (!peerDevice) {
    logger.warn(`[Signaling] 房间 ${roomId} 中找不到对方设备`);
    return { success: false, error: '对方设备不在房间中' };
  }

  sendToPeer(peerDevice, {
    type: 'signal',
    roomId,
    payload: {
      signalType: 'ice_candidate',
      from: fromDevice,
      candidate,
    },
  });

  logger.debug(`[Signaling] ICE Candidate 已转发: ${fromDevice} → ${peerDevice} room=${roomId}`);
  return { success: true };
}

/**
 * 创建 WebRTC 信令房间
 * @param {string} deviceA - 设备 A UUID
 * @param {string} deviceB - 设备 B UUID
 * @param {string} type - 房间类型 (cast/file)
 * @returns {object} { roomId, room }
 */
function createRoom(deviceA, deviceB, type) {
  const room = sessionManager.createRoom(deviceA, deviceB, type);
  logger.info(`[Signaling] 房间已创建: ${room.roomId} 类型=${type} A=${deviceA} B=${deviceB}`);
  return room;
}

/**
 * 关闭房间
 * @param {string} roomId - 房间 ID
 * @param {function} notifyDevice - 通知设备的回调 (deviceUuid, message) => void
 * @returns {boolean} 是否成功
 */
function closeRoom(roomId, notifyDevice) {
  const room = sessionManager.getRoom(roomId);
  if (!room) {
    return false;
  }

  // 通知双方房间关闭
  if (notifyDevice) {
    notifyDevice(room.deviceA, {
      type: 'room_closed',
      roomId,
      payload: { reason: 'remote_close' },
    });
    notifyDevice(room.deviceB, {
      type: 'room_closed',
      roomId,
      payload: { reason: 'remote_close' },
    });
  }

  sessionManager.removeRoom(roomId);
  logger.info(`[Signaling] 房间已关闭: ${roomId}`);
  return true;
}

module.exports = {
  handleOffer,
  handleAnswer,
  handleIceCandidate,
  createRoom,
  closeRoom,
};
