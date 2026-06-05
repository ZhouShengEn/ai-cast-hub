/**
 * ID 生成工具
 *
 * - generateUuid():  标准 UUID v4
 * - generateShortId(): 短 ID (alphanumeric, 用于房间号等)
 * - generateTransferKey(): 32位随机 alphanumeric
 */

const crypto = require('crypto');

/**
 * 生成标准 UUID v4
 * @returns {string} UUID v4 字符串
 */
function generateUuid() {
  return crypto.randomUUID();
}

/**
 * 生成指定长度的短 ID（仅包含字母和数字）
 * @param {number} [len=8] - ID 长度
 * @returns {string} 短 ID 字符串
 */
function generateShortId(len = 8) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  const bytes = crypto.randomBytes(len);
  let result = '';
  for (let i = 0; i < len; i++) {
    result += chars[bytes[i] % chars.length];
  }
  return result;
}

/**
 * 生成 32 位随机 alphanumeric 传输密钥
 * @returns {string} 32 位随机字符串
 */
function generateTransferKey() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const bytes = crypto.randomBytes(32);
  let result = '';
  for (let i = 0; i < 32; i++) {
    result += chars[bytes[i] % chars.length];
  }
  return result;
}

module.exports = { generateUuid, generateShortId, generateTransferKey };
