/**
 * 数据库配置
 *
 * 当前使用内存模式（开发环境）
 * 如需持久化存储，可切换到 MySQL 或 SQLite
 */

const config = require('./index');

/** MySQL 连接池缓存 */
let mysqlPool = null;

/**
 * 获取 MySQL 连接池（懒初始化 + 缓存）
 * @returns {Promise<mysql.Pool>} MySQL 连接池实例
 */
async function getMySQLPool() {
  if (mysqlPool) {
    return mysqlPool;
  }

  const mysql = require('mysql2/promise');

  mysqlPool = mysql.createPool({
    host: config.db.mysql.host,
    port: config.db.mysql.port,
    user: config.db.mysql.user,
    password: config.db.mysql.password,
    database: config.db.mysql.database,
    waitForConnections: config.db.mysql.waitForConnections,
    connectionLimit: config.db.mysql.connectionLimit,
    queueLimit: config.db.mysql.queueLimit,
    charset: config.db.mysql.charset,
  });

  // 验证连接
  const connection = await mysqlPool.getConnection();
  await connection.ping();
  connection.release();

  console.log('[DB] MySQL 连接池初始化完成');
  return mysqlPool;
}

/**
 * 初始化数据库连接（仅 MySQL）
 * @returns {Promise<void>}
 */
async function initDatabases() {
  // 初始化 MySQL（可选）
  try {
    await getMySQLPool();
    console.log('[DB] MySQL 连接成功');
  } catch (err) {
    console.warn(`[DB] MySQL 连接失败: ${err.message}`);
    console.warn('[DB] 当前使用内存模式运行，数据不会持久化');
  }
  
  // 内存模式提示
  console.log('[DB] ✅ 使用内存模式启动');
}

/**
 * 关闭所有数据库连接
 * @returns {Promise<void>}
 */
async function closeDatabases() {
  if (mysqlPool) {
    try {
      await mysqlPool.end();
      mysqlPool = null;
      console.log('[DB] MySQL 连接池已关闭');
    } catch (err) {
      console.error(`[DB] MySQL 连接池关闭失败: ${err.message}`);
    }
  }
  
  console.log('[DB] 所有连接已关闭');
}

module.exports = {
  getMySQLPool,
  initDatabases,
  closeDatabases,
};
