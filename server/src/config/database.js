const mysql = require('mysql2/promise');
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');
const config = require('./index');

/** MySQL 连接池缓存 */
let mysqlPool = null;

/** SQLite 实例缓存 */
let sqliteDb = null;

/**
 * 获取 MySQL 连接池（懒初始化 + 缓存）
 * @returns {Promise<mysql.Pool>} MySQL 连接池实例
 */
async function getMySQLPool() {
  if (mysqlPool) {
    return mysqlPool;
  }

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

  return mysqlPool;
}

/**
 * 获取 SQLite 实例（懒初始化 + 缓存）
 * @returns {Database.Database} better-sqlite3 数据库实例
 */
function getSQLite() {
  if (sqliteDb) {
    return sqliteDb;
  }

  // 确保数据目录存在
  const dbPath = config.db.sqlite.path;
  const dbDir = path.dirname(dbPath);
  if (!fs.existsSync(dbDir)) {
    fs.mkdirSync(dbDir, { recursive: true });
  }

  sqliteDb = new Database(dbPath);

  // 启用 WAL 模式以获得更好的并发性能
  sqliteDb.pragma('journal_mode = WAL');
  sqliteDb.pragma('foreign_keys = ON');

  return sqliteDb;
}

/**
 * 初始化所有数据库连接
 * @returns {Promise<void>}
 */
async function initDatabases() {
  // 初始化 MySQL
  try {
    await getMySQLPool();
    console.log('[DB] MySQL 连接池初始化完成');
  } catch (err) {
    console.warn(`[DB] MySQL 连接失败: ${err.message}，将仅使用 SQLite`);
    // MySQL 连接失败不阻止启动，降级到 SQLite
  }

  // 初始化 SQLite
  try {
    const db = getSQLite();
    console.log(`[DB] SQLite 初始化完成: ${config.db.sqlite.path}`);

    // 创建基础表结构
    db.exec(`
      CREATE TABLE IF NOT EXISTS devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_uuid TEXT NOT NULL UNIQUE,
        device_name TEXT NOT NULL DEFAULT '',
        platform TEXT NOT NULL DEFAULT 'unknown',
        transfer_key_encrypted TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );

      CREATE TABLE IF NOT EXISTS chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_uuid TEXT NOT NULL,
        role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system')),
        content TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (device_uuid) REFERENCES devices(device_uuid) ON DELETE CASCADE
      );

      CREATE TABLE IF NOT EXISTS file_transfers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transfer_id TEXT NOT NULL UNIQUE,
        device_uuid TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_size INTEGER NOT NULL DEFAULT 0,
        file_type TEXT NOT NULL DEFAULT '',
        transfer_key TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'transferring', 'completed', 'failed', 'cancelled')),
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (device_uuid) REFERENCES devices(device_uuid) ON DELETE CASCADE
      );
    `);
  } catch (err) {
    console.error(`[DB] SQLite 初始化失败: ${err.message}`);
    throw err;
  }
}

/**
 * 关闭所有数据库连接
 * @returns {Promise<void>}
 */
async function closeDatabases() {
  // 关闭 MySQL 连接池
  if (mysqlPool) {
    try {
      await mysqlPool.end();
      mysqlPool = null;
      console.log('[DB] MySQL 连接池已关闭');
    } catch (err) {
      console.error(`[DB] MySQL 连接池关闭失败: ${err.message}`);
    }
  }

  // 关闭 SQLite
  if (sqliteDb) {
    try {
      sqliteDb.close();
      sqliteDb = null;
      console.log('[DB] SQLite 连接已关闭');
    } catch (err) {
      console.error(`[DB] SQLite 关闭失败: ${err.message}`);
    }
  }
}

module.exports = {
  getMySQLPool,
  getSQLite,
  initDatabases,
  closeDatabases,
};
