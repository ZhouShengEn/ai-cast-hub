/**
 * Docker 容器管理服务
 *
 * 使用 dockerode 创建/管理代码执行沙箱容器。
 * 资源限制: memory + cpus 可配置
 * 镜像: ai-cast-sandbox
 */

const Docker = require('dockerode');
const config = require('../../config');
const logger = require('../../utils/logger');

/** @type {Docker|null} */
let docker = null;

/**
 * 获取 Docker 客户端实例（懒初始化）
 * @returns {Docker}
 */
function getDocker() {
  if (!docker) {
    docker = new Docker({
      socketPath: process.env.DOCKER_SOCKET || '/var/run/docker.sock',
    });
  }
  return docker;
}

/**
 * 创建代码执行沙箱容器
 * @param {string} sessionId - 会话标识
 * @returns {Promise<string>} containerId
 */
async function createSandbox(sessionId) {
  const d = getDocker();
  const containerName = `ai-cast-sandbox-${sessionId}`;

  logger.info(`[Docker] 创建沙箱容器: ${containerName}`);

  try {
    const container = await d.createContainer({
      name: containerName,
      Image: config.sandbox.image,
      Cmd: ['sleep', '3600'], // 保持容器运行
      WorkingDir: '/tmp/code',
      HostConfig: {
        Memory: config.sandbox.memoryMb * 1024 * 1024,
        CpuShares: config.sandbox.cpuCount * 1024,
        NetworkMode: 'none', // 禁止网络访问
        ReadonlyRootfs: false,
        AutoRemove: false,
      },
    });

    await container.start();
    logger.info(`[Docker] 沙箱容器已启动: ${container.id.substring(0, 12)}`);

    return container.id;
  } catch (err) {
    logger.error(`[Docker] 创建沙箱失败: ${err.message}`);
    throw new Error(`无法创建执行环境: ${err.message}`);
  }
}

/**
 * 在容器中执行代码
 * @param {string} containerId - 容器 ID
 * @param {string} code - 代码内容
 * @param {string} language - 编程语言 (python/javascript)
 * @returns {Promise<{stdout: string, stderr: string, exitCode: number}>}
 */
async function executeCode(containerId, code, language) {
  const d = getDocker();
  const container = d.getContainer(containerId);

  // 确定文件名和执行命令
  let fileName, execCmd;
  switch (language.toLowerCase()) {
    case 'python':
    case 'py':
      fileName = 'code.py';
      execCmd = ['python3', '/tmp/code/code.py'];
      break;
    case 'javascript':
    case 'js':
      fileName = 'code.js';
      execCmd = ['node', '/tmp/code/code.js'];
      break;
    default:
      throw new Error(`不支持的语言: ${language}`);
  }

  // 写入代码文件
  const base64Code = Buffer.from(code, 'utf-8').toString('base64');

  try {
    // 将代码写入容器
    const exec = await container.exec({
      Cmd: ['sh', '-c', `echo '${base64Code}' | base64 -d > /tmp/code/${fileName}`],
      AttachStdout: true,
      AttachStderr: true,
    });
    await exec.start({});

    // 执行代码
    const execRun = await container.exec({
      Cmd: execCmd,
      AttachStdout: true,
      AttachStderr: true,
    });

    const stream = await execRun.start({ hijack: true, Detach: false });

    let stdout = '';
    let stderr = '';

    await new Promise((resolve, reject) => {
      container.modem.demuxStream(stream, {
        write: (chunk) => { stdout += chunk.toString(); },
      }, {
        write: (chunk) => { stderr += chunk.toString(); },
      });

      stream.on('end', resolve);
      stream.on('error', reject);
    });

    // 检查退出码
    const inspect = await execRun.inspect();
    const exitCode = inspect.ExitCode || 0;

    return { stdout, stderr, exitCode };
  } catch (err) {
    logger.error(`[Docker] 代码执行失败: ${err.message}`);
    return { stdout: '', stderr: err.message, exitCode: 1 };
  }
}

/**
 * 销毁沙箱容器
 * @param {string} containerId - 容器 ID
 * @returns {Promise<void>}
 */
async function destroySandbox(containerId) {
  const d = getDocker();
  const container = d.getContainer(containerId);

  try {
    await container.stop({ t: 5 });
    await container.remove({ force: true });
    logger.debug(`[Docker] 沙箱容器已销毁: ${containerId.substring(0, 12)}`);
  } catch (err) {
    logger.warn(`[Docker] 销毁沙箱失败（可能已被清理）: ${err.message}`);
  }
}

/**
 * 清理空闲容器
 * 遍历所有 ai-cast-sandbox-* 容器，停止超过 idleTimeoutSec 的容器
 * @param {number} [idleTimeoutSec=600] - 空闲超时秒数
 * @returns {Promise<number>} 清理的容器数
 */
async function cleanupIdle(idleTimeoutSec = 600) {
  const d = getDocker();
  let cleaned = 0;

  try {
    const containers = await d.listContainers({
      filters: { name: ['ai-cast-sandbox-'] },
    });

    const now = Math.floor(Date.now() / 1000);

    for (const info of containers) {
      const created = info.Created;
      if (now - created > idleTimeoutSec) {
        try {
          const container = d.getContainer(info.Id);
          await container.stop({ t: 2 });
          await container.remove({ force: true });
          cleaned++;
        } catch (err) {
          logger.warn(`[Docker] 清理容器失败 ${info.Id.substring(0, 12)}: ${err.message}`);
        }
      }
    }

    if (cleaned > 0) {
      logger.info(`[Docker] 已清理 ${cleaned} 个空闲容器`);
    }
  } catch (err) {
    logger.warn(`[Docker] 清理空闲容器失败: ${err.message}`);
  }

  return cleaned;
}

module.exports = { createSandbox, executeCode, destroySandbox, cleanupIdle };
