/**
 * AES-256-GCM 加解密服务
 *
 * - 对 API Key 使用 AES-256-GCM 加密后存库
 * - 加密输出: base64(IV 12字节 + authTag 16字节 + ciphertext)
 * - 密钥来自 config.encryptionKey（64位 hex → 32字节 Buffer）
 */

const crypto = require('crypto');
const config = require('../config');
const logger = require('../utils/logger');

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;  // GCM 推荐 12 字节 IV
const TAG_LENGTH = 16; // GCM auth tag 长度

/**
 * 获取加密密钥 Buffer（32字节）
 * @returns {Buffer} 加密密钥
 */
function getKeyBytes() {
  return Buffer.from(config.encryptionKey, 'hex');
}

/**
 * 使用 AES-256-GCM 加密明文
 * @param {string} plaintext - 明文
 * @returns {string} base64 编码的加密结果 (IV + authTag + ciphertext)
 */
function encryptApiKey(plaintext) {
  const key = getKeyBytes();
  const iv = crypto.randomBytes(IV_LENGTH);

  const cipher = crypto.createCipheriv(ALGORITHM, key, iv, { authTagLength: TAG_LENGTH });

  const encrypted = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);

  const authTag = cipher.getAuthTag();

  // 拼接: IV (12) + authTag (16) + ciphertext
  const combined = Buffer.concat([iv, authTag, encrypted]);
  return combined.toString('base64');
}

/**
 * 使用 AES-256-GCM 解密
 * @param {string} encryptedBase64 - base64 编码的加密数据
 * @returns {string} 解密后的明文
 */
function decryptApiKey(encryptedBase64) {
  const key = getKeyBytes();
  const combined = Buffer.from(encryptedBase64, 'base64');

  const iv = combined.subarray(0, IV_LENGTH);
  const authTag = combined.subarray(IV_LENGTH, IV_LENGTH + TAG_LENGTH);
  const ciphertext = combined.subarray(IV_LENGTH + TAG_LENGTH);

  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv, { authTagLength: TAG_LENGTH });
  decipher.setAuthTag(authTag);

  const decrypted = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]);

  return decrypted.toString('utf8');
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

module.exports = { encryptApiKey, decryptApiKey, generateTransferKey };
