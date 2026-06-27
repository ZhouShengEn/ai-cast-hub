/**
 * API 路由聚合
 *
 * 挂载:
 * - /device → device.js (设备管理)
 * - /chat   → chat.js   (AI 对话)
 * - /model  → model.js  (模型管理)
 * - /file   → file.js   (文件传输)
 * - /stats  → stats.js  (用量统计)
 * - /health            (健康检查)
 */

const { Router } = require('express');
const os = require('os');

const deviceRoutes = require('./device');
const chatRoutes = require('./chat');
const modelRoutes = require('./model');
const fileRoutes = require('./file');
const statsRoutes = require('./stats');

const router = Router();

/**
 * 获取本机局域网 IPv4 地址
 * 优先返回真实局域网地址，跳过虚拟网卡（VMware/VirtualBox/Hyper-V 等）
 * @returns {string|null}
 */
function getLocalIpAddress() {
  const interfaces = os.networkInterfaces();
  // 虚拟网卡关键字，这些网卡的地址通常手机无法访问
  const virtualKeywords = ['vmware', 'virtualbox', 'vethernet', 'docker', 'wsl', 'vbox'];
  const candidates = [];

  for (const name of Object.keys(interfaces)) {
    const lowerName = name.toLowerCase();
    const isVirtual = virtualKeywords.some((kw) => lowerName.includes(kw));
    for (const iface of interfaces[name] || []) {
      // 跳过回环和 IPv6，只取 IPv4 局域网地址
      if (!iface.internal && iface.family === 'IPv4') {
        candidates.push({ address: iface.address, isVirtual, name });
      }
    }
  }

  // 优先返回非虚拟网卡的地址
  const real = candidates.find((c) => !c.isVirtual);
  if (real) return real.address;
  // 退而求其次，返回任意一个
  return candidates.length > 0 ? candidates[0].address : null;
}

// ---- 健康检查 ----
router.get('/health', (req, res) => {
  res.json({
    code: 0,
    data: {
      status: 'ok',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
    },
    message: 'ok',
  });
});

// ---- 服务器信息（供 PC 端获取局域网地址，用于生成二维码） ----
router.get('/server/info', (req, res) => {
  const port = process.env.PORT || 3000;
  const localIp = getLocalIpAddress();
  res.json({
    code: 0,
    data: {
      port,
      localIp,
      serverUrl: localIp ? `http://${localIp}:${port}` : null,
    },
    message: 'ok',
  });
});

// ---- WebRTC 配置（供客户端获取 ICE 服务器列表） ----
const { getTurnConfig } = require('../services/webrtc/turnConfig');
router.get('/webrtc/config', (req, res) => {
  const config = getTurnConfig();
  res.json({
    code: 0,
    data: config,
    message: 'ok',
  });
});

// ---- 子路由挂载 ----
router.use('/device', deviceRoutes);
router.use('/chat', chatRoutes);
router.use('/model', modelRoutes);
router.use('/file', fileRoutes);
router.use('/stats', statsRoutes);

module.exports = router;
