/**
 * WebSocket 消息处理器
 *
 * 根据消息 type 将 WS 消息路由到对应处理逻辑:
 * - signal        → 转发信令到 peer
 * - create_room   → 创建 WebRTC 房间
 * - close_room    → 关闭房间
 * - ping          → 回复 pong
 */

const roomManager = require('./roomManager');
const signaling = require('../services/webrtc/signaling');
const sessionManager = require('../services/webrtc/sessionManager');
const logger = require('../utils/logger');

/**
 * 发送消息给指定设备
 * @param {string} deviceUuid - 目标设备 UUID
 * @param {object} message - 消息对象
 * @param {function} getWsByDeviceUuid - 根据设备 UUID 获取 WS 连接的回调
 */
function sendToDevice(deviceUuid, message, getWsByDeviceUuid) {
  const ws = getWsByDeviceUuid(deviceUuid);
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify(message));
  }
}

/**
 * 处理 WebSocket 消息
 * @param {import('ws').WebSocket} ws - WebSocket 连接
 * @param {string} deviceUuid - 设备 UUID
 * @param {object} message - 解析后的 JSON 消息
 * @param {function} getWsByDeviceUuid - 根据设备 UUID 获取 WS 连接
 * @returns {object|undefined} 直接返回的响应消息（可选）
 */
function handleMessage(ws, deviceUuid, message, getWsByDeviceUuid) {
  // 必须有 type 字段
  if (!message.type || typeof message.type !== 'string') {
    return {
      type: 'error',
      roomId: message.roomId || null,
      payload: { message: '消息必须包含 type 字段' },
    };
  }

  const roomId = message.roomId;

  switch (message.type) {
    // ---- 信令转发 ----
    case 'signal': {
      if (!roomId) {
        return { type: 'error', roomId: null, payload: { message: 'signal 消息需要 roomId' } };
      }

      const signalPayload = message.payload || {};
      const signalType = signalPayload.signalType;

      if (signalType === 'offer') {
        signaling.handleOffer(roomId, deviceUuid, signalPayload.sdp, (peer, msg) => {
          sendToDevice(peer, msg, getWsByDeviceUuid);
        });
      } else if (signalType === 'answer') {
        signaling.handleAnswer(roomId, deviceUuid, signalPayload.sdp, (peer, msg) => {
          sendToDevice(peer, msg, getWsByDeviceUuid);
        });
      } else if (signalType === 'ice_candidate') {
        signaling.handleIceCandidate(roomId, deviceUuid, signalPayload.candidate, (peer, msg) => {
          sendToDevice(peer, msg, getWsByDeviceUuid);
        });
      } else {
        return { type: 'error', roomId, payload: { message: `未知信令类型: ${signalType}` } };
      }
      break;
    }

    // ---- 创建房间 ----
    case 'create_room': {
      const targetDevice = message.payload?.targetDeviceUuid;
      const roomType = message.payload?.type || 'cast';

      logger.info(`[WS Handler] create_room: from=${deviceUuid} target=${targetDevice} type=${roomType}`);

      if (!targetDevice) {
        return { type: 'error', roomId: null, payload: { message: '缺少目标设备 UUID' } };
      }

      const room = signaling.createRoom(deviceUuid, targetDevice, roomType);

      // 加入 WS 房间
      roomManager.joinRoom(room.roomId, deviceUuid, ws, roomType);

      // 通知目标设备
      const notified = sendToDevice(targetDevice, {
        type: 'room_invitation',
        roomId: room.roomId,
        payload: {
          fromDeviceUuid: deviceUuid,
          type: roomType,
        },
      }, getWsByDeviceUuid);

      logger.info(`[WS Handler] 房间创建: roomId=${room.roomId} type=${roomType} 通知目标设备 ${targetDevice} ${notified ? '成功(在线)' : '失败(离线)'}`);

      return {
        type: 'room_created',
        roomId: room.roomId,
        payload: {
          roomId: room.roomId,
          type: roomType,
          peerDeviceUuid: targetDevice,
        },
      };
    }

    // ---- 加入房间（响应邀请） ----
    case 'join_room': {
      if (!roomId) {
        return { type: 'error', roomId: null, payload: { message: '缺少 roomId' } };
      }

      const room = sessionManager.getRoom(roomId);
      if (!room) {
        logger.warn(`[WS Handler] join_room: 房间不存在 roomId=${roomId}`);
        return { type: 'error', roomId, payload: { message: '房间不存在' } };
      }

      logger.info(`[WS Handler] join_room: device=${deviceUuid} roomId=${roomId} type=${room.type}`);

      roomManager.joinRoom(roomId, deviceUuid, ws, room.type);

      // 通知房间创建者（对方）对端已加入，可以开始发 offer
      const peerDevice = sessionManager.getPeerDevice(roomId, deviceUuid);
      if (peerDevice) {
        const peerNotified = sendToDevice(peerDevice, {
          type: 'peer_joined',
          roomId,
          payload: { roomId, peerDeviceUuid: deviceUuid },
        }, getWsByDeviceUuid);
        logger.info(`[WS Handler] peer_joined 通知: ${peerDevice} ${peerNotified ? '成功' : '失败'}`);
      } else {
        logger.warn(`[WS Handler] join_room: 找不到对方设备 roomId=${roomId}`);
      }

      return {
        type: 'room_joined',
        roomId,
        payload: { roomId, type: room.type },
      };
    }

    // ---- 关闭房间 ----
    case 'close_room': {
      if (!roomId) {
        return { type: 'error', roomId: null, payload: { message: '缺少 roomId' } };
      }

      const sendNotify = (device, msg) => sendToDevice(device, msg, getWsByDeviceUuid);
      signaling.closeRoom(roomId, sendNotify);
      roomManager.removeRoom(roomId);

      return { type: 'room_closed', roomId, payload: { reason: 'user_close' } };
    }

    // ---- 心跳 ----
    case 'ping':
      return { type: 'pong', roomId: null, payload: { timestamp: Date.now() } };

    default:
      return { type: 'error', roomId: roomId || null, payload: { message: `未知消息类型: ${message.type}` } };
  }
}

module.exports = { handleMessage };
