/**
 * 临时文件清理服务
 *
 * 定期清理过期临时文件（HTTP 上传的文件分片等）。
 * 默认每小时执行一次，清理超过1小时的临时文件。
 */

const fs = require('fs');
const path = require('path');
const logger = require('../../utils/logger');

/** @type {NodeJS.Timeout|null} 定时器引用 */
let schedulerTimer = null;

/** 临时文件目录 */
const TEMP_DIR = path.join(__dirname, '..', '..', 'temp');

/**
 * 启动定时清理任务
 * @param {number} [intervalMs=3600000] - 清理间隔（毫秒），默认1小时
 */
function startScheduler(intervalMs = 3600000) {
  if (schedulerTimer) {
    logger.warn('[TempCleanup] 定时清理任务已在运行');
    return;
  }

  logger.info(`[TempCleanup] 启动定时清理，间隔: ${intervalMs}ms`);

  // 立即执行一次
  cleanup();

  // 周期性执行
  schedulerTimer = setInterval(() => {
    cleanup();
  }, intervalMs);
}

/**
 * 停止定时清理任务
 */
function stopScheduler() {
  if (schedulerTimer) {
    clearInterval(schedulerTimer);
    schedulerTimer = null;
    logger.info('[TempCleanup] 定时清理任务已停止');
  }
}

/**
 * 清理过期临时文件
 * @param {number} [maxAgeMs=3600000] - 文件最大存活时间（毫秒），默认1小时
 * @returns {number} 清理的文件数
 */
function cleanup(maxAgeMs = 3600000) {
  if (!fs.existsSync(TEMP_DIR)) {
    return 0;
  }

  const now = Date.now();
  let cleaned = 0;

  try {
    const files = fs.readdirSync(TEMP_DIR);

    for (const file of files) {
      const filePath = path.join(TEMP_DIR, file);
      try {
        const stat = fs.statSync(filePath);
        if (stat.isFile() && (now - stat.mtimeMs) > maxAgeMs) {
          fs.unlinkSync(filePath);
          cleaned++;
        }
      } catch (err) {
        logger.debug(`[TempCleanup] 清理文件失败 ${file}: ${err.message}`);
      }
    }

    if (cleaned > 0) {
      logger.info(`[TempCleanup] 已清理 ${cleaned} 个过期临时文件`);
    }
  } catch (err) {
    logger.warn(`[TempCleanup] 扫描临时目录失败: ${err.message}`);
  }

  return cleaned;
}

module.exports = { startScheduler, stopScheduler, cleanup };
