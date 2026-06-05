/**
 * 代码执行器
 *
 * 完整的代码执行流程:
 * createSandbox → executeCode → destroySandbox → return result
 *
 * 超时保护: config.sandbox.timeoutSec
 */

const dockerManager = require('./dockerManager');
const { generateShortId } = require('../../utils/uid');
const config = require('../../config');
const logger = require('../../utils/logger');

/**
 * 执行代码（完整流程）
 * @param {string} sessionId - 会话标识
 * @param {string} code - 代码内容
 * @param {string} language - 编程语言 (python/javascript)
 * @returns {Promise<{stdout: string, stderr: string, exitCode: number, executionTimeMs: number}>}
 */
async function execute(sessionId, code, language) {
  const startTime = Date.now();
  let containerId = null;

  try {
    // 1. 创建沙箱
    containerId = await dockerManager.createSandbox(sessionId);

    // 2. 执行代码（带超时保护）
    const timeoutMs = config.sandbox.timeoutSec * 1000;

    const result = await Promise.race([
      dockerManager.executeCode(containerId, code, language),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`代码执行超时 (${config.sandbox.timeoutSec}s)`)), timeoutMs)
      ),
    ]);

    // 3. 计算执行时间
    const executionTimeMs = Date.now() - startTime;

    // 4. 销毁沙箱
    await dockerManager.destroySandbox(containerId);
    containerId = null;

    logger.info(`[CodeExecutor] 执行完成 session=${sessionId} lang=${language} time=${executionTimeMs}ms exit=${result.exitCode}`);

    return {
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
      executionTimeMs,
    };
  } catch (err) {
    // 确保清理容器
    if (containerId) {
      try {
        await dockerManager.destroySandbox(containerId);
      } catch (cleanupErr) {
        logger.warn(`[CodeExecutor] 清理失败: ${cleanupErr.message}`);
      }
    }

    const executionTimeMs = Date.now() - startTime;
    logger.error(`[CodeExecutor] 执行失败 session=${sessionId}: ${err.message}`);

    return {
      stdout: '',
      stderr: err.message,
      exitCode: 1,
      executionTimeMs,
    };
  }
}

module.exports = { execute };
