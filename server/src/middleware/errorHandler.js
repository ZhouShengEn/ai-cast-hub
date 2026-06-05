/**
 * 统一错误处理中间件
 *
 * - 捕获所有未处理异常
 * - ZodError 特殊处理，返回校验失败详情
 * - 开发环境附加 stack trace
 */

const { ZodError } = require('zod');
const logger = require('../utils/logger');

/**
 * Express 全局错误处理中间件
 * @param {Error} err - 错误对象
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function errorHandler(err, req, res, _next) {
  // Zod 校验错误
  if (err instanceof ZodError) {
    const errors = err.errors.map(e => ({
      field: e.path.join('.'),
      message: e.message,
    }));

    logger.warn(`[ErrorHandler] 参数校验失败: ${JSON.stringify(errors)}`);

    return res.status(400).json({
      code: 400,
      data: { errors },
      message: '参数校验失败',
    });
  }

  // 已知的业务错误（带状态码）
  if (err.statusCode) {
    return res.status(err.statusCode).json({
      code: err.statusCode,
      data: null,
      message: err.message,
    });
  }

  // 未知错误
  logger.error(`[ErrorHandler] 未处理错误: ${err.message}`, {
    stack: err.stack,
    path: req.path,
    method: req.method,
  });

  const isDev = process.env.NODE_ENV === 'development';

  res.status(500).json({
    code: 500,
    data: isDev ? { stack: err.stack } : null,
    message: isDev ? err.message : 'Internal Server Error',
  });
}

module.exports = errorHandler;
