/**
 * 服务器监控模块 — Git 代码版本检测与运维
 *
 * 多维度状态判定（精准不笼统）：
 *  - up_to_date: 已是最新
 *  - dirty: 本地存在未提交修改
 *  - behind: 远程存在新版本可拉取
 *  - no_repo: 非 Git 仓库
 *  - error: 连接 / 密钥 / 网络异常
 *
 * 一键运维：git pull（可选 rebase），流式输出。
 */

const commandRunner = require('./commandRunner');
const { GIT_STATUS } = require('./constants');
const config = require('./config');
const logger = require('../../utils/logger');

const TIMEOUT = config.get().commandTimeoutSec * 1000;

/**
 * 获取 Git 状态。
 * @param {string} projectPath
 * @returns {Promise<object>}
 */
async function getStatus(projectPath) {
  const run = (args) => commandRunner.run({ bin: 'git', args, cwd: projectPath }, {}, TIMEOUT);
  try {
    // 1) 是否 git 仓库
    const inside = await run(['rev-parse', '--is-inside-work-tree']);
    if (inside.code !== 0) {
      return { status: GIT_STATUS.NO_REPO, message: '非 Git 仓库' };
    }

    const branchR = await run(['rev-parse', '--abbrev-ref', 'HEAD']);
    const branch = branchR.code === 0 ? branchR.stdout.trim() : 'unknown';

    // 2) 本地脏代码
    const statusR = await run(['status', '--porcelain']);
    const dirty = statusR.code === 0 && statusR.stdout.trim().length > 0;

    // 3) 远程差异（先 fetch，再比较）
    let ahead = 0;
    let behind = 0;
    let remoteError = null;
    try {
      await run(['fetch', '--quiet']);
      const upR = await run(['rev-parse', '--abbrev-ref', 'HEAD@{upstream}']);
      if (upR.code === 0) {
        const aheadR = await run(['rev-list', '--count', 'HEAD@{upstream}..HEAD']);
        const behindR = await run(['rev-list', '--count', 'HEAD..HEAD@{upstream}']);
        ahead = aheadR.code === 0 ? parseInt(aheadR.stdout.trim() || '0', 10) : 0;
        behind = behindR.code === 0 ? parseInt(behindR.stdout.trim() || '0', 10) : 0;
      }
    } catch (e) {
      remoteError = e.message;
    }

    let status = GIT_STATUS.UP_TO_DATE;
    let message = '已是最新版本';
    if (dirty) {
      status = GIT_STATUS.DIRTY;
      message = `本地存在未提交修改（${countDirty(statusR.stdout)} 处）`;
    } else if (behind > 0) {
      status = GIT_STATUS.BEHIND;
      message = `远程存在 ${behind} 个新提交可拉取`;
    } else if (remoteError) {
      status = GIT_STATUS.ERROR;
      message = `远程连接异常: ${remoteError}`;
    }

    return {
      status,
      message,
      branch,
      dirty,
      ahead,
      behind,
      hasUpstream: ahead + behind >= 0,
    };
  } catch (err) {
    return { status: GIT_STATUS.ERROR, message: 'Git 检测异常: ' + err.message };
  }
}

function countDirty(porcelain) {
  return porcelain.split('\n').filter((l) => l.trim().length > 0).length;
}

/**
 * 拉取最新代码（git pull）。
 * @param {string} projectPath
 * @param {object} [opts] { rebase?:boolean, onLine?:(line,level)=>void }
 */
async function pull(projectPath, opts = {}) {
  const emit = (chunk, level) => { if (opts.onLine) opts.onLine(chunk, level); };
  try {
    // 拉取前再次校验是否有未提交修改（防止覆盖丢失）
    const st = await getStatus(projectPath);
    if (st.dirty) {
      emit('⚠️ 本地存在未提交修改，pull 可能导致冲突或覆盖。', 'WARN');
    }
    const args = opts.rebase ? ['pull', '--rebase'] : ['pull'];
    const result = await commandRunner.run(
      { bin: 'git', args, cwd: projectPath },
      { onStdout: (c) => emit(c, 'INFO'), onStderr: (c) => emit(c, 'ERROR') },
      TIMEOUT
    );
    if (result.code !== 0) {
      emit('❌ 拉取失败: ' + result.stderr.slice(0, 300), 'ERROR');
      throw new Error('git pull 失败: ' + result.stderr.slice(0, 300));
    }
    emit('✅ 拉取完成', 'INFO');
    return { code: 0, output: result.stdout + result.stderr };
  } catch (err) {
    logger.error(`[Monitor] git pull 失败 ${projectPath}: ${err.message}`);
    throw err;
  }
}

module.exports = { getStatus, pull };
