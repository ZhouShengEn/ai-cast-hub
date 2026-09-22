import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/conversation.dart';
import '../models/message.dart';

/// 本地存储服务
///
/// 使用 shared_preferences 存储简单键值对，使用 sqflite 缓存对话和消息历史。
class LocalStorage {
  static LocalStorage? _instance;
  late SharedPreferences _prefs;
  Database? _db;

  LocalStorage._();

  static LocalStorage get instance {
    _instance ??= LocalStorage._();
    return _instance!;
  }

  /// 初始化本地存储（SharedPreferences + sqflite）
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      _db = await _initDatabase();
    } catch (_) {
      // sqflite not available (e.g., Web), skip database initialization
    }
  }

  // ============ SharedPreferences 操作 ============

  /// 获取设备 UUID
  String? getDeviceUuid() => _prefs.getString('device_uuid');

  /// 保存设备 UUID
  Future<bool> saveDeviceUuid(String uuid) =>
      _prefs.setString('device_uuid', uuid);

  /// 获取传输密钥
  String? getTransferKey() => _prefs.getString('transfer_key');

  /// 保存传输密钥
  Future<bool> saveTransferKey(String key) =>
      _prefs.setString('transfer_key', key);

  /// 线上服务器地址（韩国云服务器，cast.zhoushengen.xyz 反代）
  static const String _prodServerUrl = 'https://cast.zhoushengen.xyz/api/v1';

  /// 获取服务器地址
  ///
  /// 优先级：用户自定义设置 > 平台默认值
  /// - Web: http://localhost:3000/api/v1
  /// - 真机/其他: https://cast.zhoushengen.xyz/api/v1
  String getServerUrl() {
    final saved = _prefs.getString('server_url');
    if (saved != null && saved.isNotEmpty) {
      // Web 环境下，如果保存的是 Android 模拟器地址，自动修正
      if (kIsWeb && saved.contains('10.0.2.2')) {
        return 'http://localhost:3000/api/v1';
      }
      return saved;
    }

    // 根据平台返回默认地址
    if (kIsWeb) {
      return 'http://localhost:3000/api/v1';
    }
    // 真机默认直连线上服务器，无需先在同一局域网内配对
    // 局域网调试时可在「设置 → 服务器地址」改回 http://<PC 内网 IP>:3000/api/v1
    return _prodServerUrl;
  }

  /// 保存服务器地址
  Future<bool> saveServerUrl(String url) =>
      _prefs.setString('server_url', url);

  /// 获取最近使用的模型列表
  List<String> getRecentModels() {
    final raw = _prefs.getStringList('recent_models');
    return raw ?? [];
  }

  /// 获取调试悬浮球开关
  bool getDebugBallEnabled() => _prefs.getBool('debug_ball_enabled') ?? false;

  /// 获取对话模式: 'server' | 'local'
  String getChatMode() => _prefs.getString('chat_mode') ?? 'server';

  /// 保存对话模式
  Future<bool> saveChatMode(String mode) =>
      _prefs.setString('chat_mode', mode);

  // ============ 本地对话持久化 ============

  /// 获取本地对话列表
  List<Map<String, dynamic>> getLocalConversations() {
    final raw = _prefs.getString('local_conversations');
    if (raw == null) return [];
    return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// 保存本地对话列表
  Future<bool> saveLocalConversations(List<Map<String, dynamic>> data) =>
      _prefs.setString('local_conversations', jsonEncode(data));

  /// 获取本地对话消息（按对话 ID 分组）
  Map<String, List<Map<String, dynamic>>> getLocalMessages() {
    final raw = _prefs.getString('local_messages');
    if (raw == null) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) =>
        MapEntry(k, (v as List<dynamic>).cast<Map<String, dynamic>>()));
  }

  /// 保存本地对话消息
  Future<bool> saveLocalMessages(Map<String, List<Map<String, dynamic>>> data) =>
      _prefs.setString('local_messages', jsonEncode(data));

  /// 获取背景风格
  String getBackgroundStyle() => _prefs.getString('background_style') ?? 'day';

  /// 保存背景风格
  Future<bool> saveBackgroundStyle(String style) =>
      _prefs.setString('background_style', style);

  /// 保存调试悬浮球开关
  Future<bool> saveDebugBallEnabled(bool enabled) =>
      _prefs.setBool('debug_ball_enabled', enabled);

  /// 保存最近使用的模型列表
  Future<bool> saveRecentModels(List<String> models) =>
      _prefs.setStringList('recent_models', models);

  // ============ 设备防盗操作日志 ============

  /// 获取防盗操作日志（用户可见：记录每次远程指令的动作、时间与来源设备）
  ///
  /// 每条结构：{id, action, sourceDeviceUuid, timestamp, note}
  List<Map<String, dynamic>> getAntiTheftLogs() {
    final raw = _prefs.getString('anti_theft_logs');
    if (raw == null) return [];
    return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// 保存防盗操作日志
  Future<bool> saveAntiTheftLogs(List<Map<String, dynamic>> logs) =>
      _prefs.setString('anti_theft_logs', jsonEncode(logs));

  /// 上一次互动的已配对 PC 设备 UUID。
  /// 用于 App 连接 Web 后「自动上报一次定位」：冷启动时无来源指令也能向该 PC 回传坐标。
  String? getLastAntiTheftTarget() => _prefs.getString('anti_theft_target');

  /// 保存上一次互动的已配对 PC 设备 UUID
  Future<bool> setLastAntiTheftTarget(String uuid) =>
      _prefs.setString('anti_theft_target', uuid);

  /// 获取 API Key 列表 [{provider, key}]
  List<Map<String, String>> getApiKeys() {
    final raw = _prefs.getString('api_keys');
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => Map<String, String>.from(e as Map))
        .toList();
  }

  /// 保存 API Key 列表
  Future<bool> saveApiKeys(List<Map<String, String>> keys) =>
      _prefs.setString('api_keys', jsonEncode(keys));

  // ============ sqflite 数据库操作 ============

  /// 初始化数据库
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'ai_cast_hub.db');

    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createV1Tables(db);
        await _createHttpRecordsTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 → v2：新增 HTTP 接口调试请求记录表
        if (oldVersion < 2) {
          await _createHttpRecordsTable(db);
        }
      },
    );
  }

  /// v1 既有表：对话 + 消息
  Future<void> _createV1Tables(Database db) async {
    // 对话表
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        device_id TEXT,
        title TEXT NOT NULL DEFAULT '新对话',
        model_provider TEXT NOT NULL DEFAULT '',
        model_name TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // 消息表
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        input_tokens INTEGER,
        output_tokens INTEGER,
        model_name TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
      )
    ''');

    // 索引加速查询
    await db.execute(
      'CREATE INDEX idx_messages_conv_id ON messages(conversation_id)',
    );
    await db.execute(
      'CREATE INDEX idx_conversations_updated ON conversations(updated_at DESC)',
    );
  }

  /// v2 新增表：HTTP 接口调试的请求记录
  ///
  /// headers / response_headers 以 JSON 字符串存 `[{"key":..,"value":..}]`。
  Future<void> _createHttpRecordsTable(Database db) async {
    await db.execute('''
      CREATE TABLE http_records (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        method TEXT NOT NULL DEFAULT 'GET',
        url TEXT NOT NULL DEFAULT '',
        timeout_sec INTEGER NOT NULL DEFAULT 10,
        headers TEXT NOT NULL DEFAULT '[]',
        body TEXT NOT NULL DEFAULT '',
        status_code INTEGER,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        response_headers TEXT NOT NULL DEFAULT '[]',
        response_body TEXT NOT NULL DEFAULT '',
        error TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_http_records_created ON http_records(created_at DESC)',
    );
  }

  /// 确保数据库已初始化
  Future<Database> get db async {
    _db ??= await _initDatabase();
    return _db!;
  }

  // ---- HTTP 接口调试请求记录 ----

  /// Web 等无 sqflite 环境下的兜底存储 key
  static const String _httpRecordsFallbackKey = 'http_records_fallback';

  /// 最多保留的请求记录条数
  static const int httpRecordsLimit = 100;

  /// 新增 / 更新一条请求记录
  ///
  /// sqflite 不可用（如 Web）时自动降级为 SharedPreferences 存储。
  Future<void> saveHttpRecord(Map<String, dynamic> record) async {
    final database = _db;
    if (database == null) {
      final list = _prefs.getStringList(_httpRecordsFallbackKey) ?? <String>[];
      final id = record['id'];
      list.removeWhere((e) {
        try {
          return (jsonDecode(e) as Map)['id'] == id;
        } catch (_) {
          return false;
        }
      });
      list.insert(0, jsonEncode(record));
      if (list.length > httpRecordsLimit) {
        list.removeRange(httpRecordsLimit, list.length);
      }
      await _prefs.setStringList(_httpRecordsFallbackKey, list);
      return;
    }
    await database.insert(
      'http_records',
      record,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取请求记录（按创建时间倒序）
  Future<List<Map<String, dynamic>>> getHttpRecords() async {
    final database = _db;
    if (database == null) {
      final list = _prefs.getStringList(_httpRecordsFallbackKey) ?? <String>[];
      return list
          .map((e) => Map<String, dynamic>.from(jsonDecode(e) as Map))
          .toList();
    }
    return database.query('http_records', orderBy: 'created_at DESC');
  }

  /// 删除单条请求记录
  Future<void> deleteHttpRecord(String id) async {
    final database = _db;
    if (database == null) {
      final list = _prefs.getStringList(_httpRecordsFallbackKey) ?? <String>[];
      list.removeWhere((e) {
        try {
          return (jsonDecode(e) as Map)['id'] == id;
        } catch (_) {
          return false;
        }
      });
      await _prefs.setStringList(_httpRecordsFallbackKey, list);
      return;
    }
    await database.delete('http_records', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空全部请求记录
  Future<void> clearHttpRecords() async {
    final database = _db;
    if (database == null) {
      await _prefs.remove(_httpRecordsFallbackKey);
      return;
    }
    await database.delete('http_records');
  }

  // ---- 对话缓存 ----

  /// 缓存对话列表
  Future<void> cacheConversations(List<Conversation> conversations) async {
    final database = await db;
    final batch = database.batch();
    for (final c in conversations) {
      batch.insert(
        'conversations',
        _conversationToDb(c),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 读取缓存的对话列表（按更新时间倒序）
  Future<List<Conversation>> getCachedConversations() async {
    final database = await db;
    final rows = await database.query(
      'conversations',
      orderBy: 'updated_at DESC',
    );
    return rows.map(_conversationFromDb).toList();
  }

  /// 缓存单条对话
  Future<void> cacheConversation(Conversation conv) async {
    final database = await db;
    await database.insert(
      'conversations',
      _conversationToDb(conv),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除缓存的对话
  Future<void> deleteCachedConversation(String id) async {
    final database = await db;
    await database.delete('conversations', where: 'id = ?', whereArgs: [id]);
    await database.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
  }

  // ---- 消息缓存 ----

  /// 缓存消息列表（按创建时间正序）
  Future<void> cacheMessages(List<Message> messages) async {
    final database = await db;
    final batch = database.batch();
    for (final m in messages) {
      batch.insert(
        'messages',
        _messageToDb(m),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 读取缓存的对话消息（按创建时间正序）
  Future<List<Message>> getCachedMessages(String conversationId) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_messageFromDb).toList();
  }

  /// 缓存单条消息
  Future<void> cacheMessage(Message message) async {
    final database = await db;
    await database.insert(
      'messages',
      _messageToDb(message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---- 内部转换方法 ----

  Map<String, dynamic> _conversationToDb(Conversation c) {
    return {
      'id': c.id,
      'device_id': c.deviceId,
      'title': c.title,
      'model_provider': c.modelProvider,
      'model_name': c.modelName,
      'created_at': c.createdAt.toIso8601String(),
      'updated_at': c.updatedAt.toIso8601String(),
    };
  }

  Conversation _conversationFromDb(Map<String, dynamic> row) {
    return Conversation(
      id: row['id'] as String,
      deviceId: row['device_id'] as String?,
      title: row['title'] as String? ?? '新对话',
      modelProvider: row['model_provider'] as String? ?? '',
      modelName: row['model_name'] as String? ?? '',
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  Map<String, dynamic> _messageToDb(Message m) {
    return {
      'id': m.id,
      'conversation_id': m.conversationId,
      'role': m.role,
      'content': m.content,
      'input_tokens': m.inputTokens,
      'output_tokens': m.outputTokens,
      'model_name': m.modelName,
      'created_at': m.createdAt.toIso8601String(),
    };
  }

  Message _messageFromDb(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      role: row['role'] as String,
      content: row['content'] as String? ?? '',
      inputTokens: row['input_tokens'] as int?,
      outputTokens: row['output_tokens'] as int?,
      modelName: row['model_name'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}
