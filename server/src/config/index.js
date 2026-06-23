const crypto = require('crypto');

/**
 * 全局配置模块
 * 读取全部环境变量并导出为配置对象，校验必需的环境变量
 */

const config = {
  /** 服务端口 */
  port: parseInt(process.env.PORT, 10) || 3000,

  /** 运行环境 */
  nodeEnv: process.env.NODE_ENV || 'development',

  /** 加密密钥（32字节hex字符串，用于设备认证加解密） */
  encryptionKey: process.env.ENCRYPTION_KEY || '',

  /** 数据库配置 */
  db: {
    mysql: {
      host: process.env.DB_MYSQL_HOST || 'localhost',
      port: parseInt(process.env.DB_MYSQL_PORT, 10) || 3306,
      user: process.env.DB_MYSQL_USER || 'ai_cast',
      password: process.env.DB_MYSQL_PASSWORD || 'ai_cast_pass',
      database: process.env.DB_MYSQL_DATABASE || 'ai_cast_hub',
      waitForConnections: true,
      connectionLimit: 10,
      queueLimit: 0,
      charset: 'utf8mb4',
    },
    // 当前使用内存模式存储设备数据
    // 如需持久化，可启用 MySQL 或添加 SQLite 支持
  },

  /** TURN/STUN 服务器配置 */
  turn: {
    server: process.env.TURN_SERVER || 'turn:localhost:3478',
    username: process.env.TURN_USERNAME || 'ai_cast',
    credential: process.env.TURN_CREDENTIAL || 'ai_cast_turn',
  },

  /** Docker 沙箱配置 */
  sandbox: {
    image: process.env.SANDBOX_IMAGE || 'ai-cast-sandbox:latest',
    timeoutSec: parseInt(process.env.SANDBOX_TIMEOUT_SEC, 10) || 120,
    memoryMb: parseInt(process.env.SANDBOX_MEMORY_MB, 10) || 512,
    cpuCount: parseInt(process.env.SANDBOX_CPU_COUNT, 10) || 1,
  },

  /** SSL 配置 */
  ssl: {
    certPath: process.env.SSL_CERT_PATH || '/etc/nginx/ssl/cert.pem',
    keyPath: process.env.SSL_KEY_PATH || '/etc/nginx/ssl/key.pem',
  },

  /** 设备认证白名单路由（不需要 X-Device-UUID 头） */
  authWhitelist: [
    '/api/v1/health',
    '/api/v1/device/bind',
  ],
};

/**
 * 校验必需的环境变量
 * 在应用启动时调用，确保关键配置存在
 */
function validateConfig() {
  const errors = [];

  if (!config.encryptionKey || config.encryptionKey.length === 0) {
    errors.push('ENCRYPTION_KEY 环境变量未设置，请设置一个32字节的hex密钥');
  }

  // 尝试将 hex 密钥转为 Buffer 以验证格式
  if (config.encryptionKey && config.encryptionKey.length > 0) {
    try {
      const keyBuffer = Buffer.from(config.encryptionKey, 'hex');
      if (keyBuffer.length !== 32) {
        errors.push(`ENCRYPTION_KEY 长度必须为32字节（64个hex字符），当前为 ${keyBuffer.length} 字节`);
      }
    } catch {
      errors.push('ENCRYPTION_KEY 格式无效，必须为hex字符串');
    }
  }

  if (errors.length > 0) {
    throw new Error(`配置校验失败:\n${errors.map(e => `  - ${e}`).join('\n')}`);
  }

  return true;
}

module.exports = config;
module.exports.validateConfig = validateConfig;
