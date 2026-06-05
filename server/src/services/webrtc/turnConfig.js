/**
 * TURN/STUN 配置生成器
 *
 * 根据环境变量配置生成 WebRTC iceServers 配置。
 * 用于 WebRTC 连接在 NAT 穿透失败时通过 TURN 中继。
 */

const config = require('../../config');
const logger = require('../../utils/logger');

/**
 * 获取 TURN/STUN 配置
 * @returns {{ iceServers: Array<{ urls: string|Array<string>, username?: string, credential?: string }> }}
 */
function getTurnConfig() {
  const iceServers = [];

  // 默认 STUN 服务器（Google 公共 STUN）
  iceServers.push({
    urls: [
      'stun:stun.l.google.com:19302',
      'stun:stun1.l.google.com:19302',
    ],
  });

  // 自定义 TURN 服务器
  if (config.turn && config.turn.server) {
    const turnServer = {
      urls: [config.turn.server],
    };

    if (config.turn.username) {
      turnServer.username = config.turn.username;
    }
    if (config.turn.credential) {
      turnServer.credential = config.turn.credential;
    }

    iceServers.push(turnServer);
    logger.debug(`[TURN] TURN 服务器已配置: ${config.turn.server}`);
  } else {
    logger.warn('[TURN] 未配置 TURN 服务器，NAT 穿透可能在某些网络环境下失败');
  }

  return { iceServers };
}

module.exports = { getTurnConfig };
