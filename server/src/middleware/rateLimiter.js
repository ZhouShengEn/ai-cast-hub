/**
 * 分级频率限制中间件
 *
 * - 全局: express-rate-limit, 默认 100 req / 15 min
 * - AI 对话: 20 req / min（更严格）
 */

const rateLimit = require('express-rate-limit');

/**
 * 全局频率限制
 * 100 次请求 / 15 分钟
 */
const globalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 分钟
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    code: 429,
    data: null,
    message: '请求过于频繁，请稍后再试',
  },
});

/**
 * AI 对话接口频率限制
 * 20 次请求 / 1 分钟
 */
const chatLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 分钟
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    code: 429,
    data: null,
    message: '消息发送过于频繁，请稍后再试',
  },
});

module.exports = { globalLimiter, chatLimiter };
