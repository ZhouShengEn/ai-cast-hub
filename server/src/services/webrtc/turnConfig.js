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
    // TURN_SERVER 支持逗号分隔的多个传输方式，例如：
    //   TURN_SERVER=turn:host:3478?transport=udp,turn:host:3478?transport=tcp
    //
    // 企业/校园网络常单向封 UDP（只放行 80/443），此时 UDP 中继不可用，
    // 把 TCP（必要时再加 turns: TLS）一起下发能让 ICE 换条路走通。
    // 注意：客户端（Chrome / flutter_webrtc）都要求 urls 为数组，这里始终传数组。
    const turnUrls = String(config.turn.server)
      .split(',')
      .map((url) => url.trim())
      .filter(Boolean);

    const turnServer = {
      urls: turnUrls,
    };

    if (config.turn.username) {
      turnServer.username = config.turn.username;
    }
    if (config.turn.credential) {
      turnServer.credential = config.turn.credential;
    }

    iceServers.push(turnServer);
    logger.info(
      `[TURN] TURN 服务器已配置（${turnUrls.length} 个传输方式）: ${turnUrls.join(' , ')}`,
    );
  } else {
    logger.warn('[TURN] 未配置 TURN 服务器，NAT 穿透可能在某些网络环境下失败');
  }

  return { iceServers };
}

module.exports = { getTurnConfig };
