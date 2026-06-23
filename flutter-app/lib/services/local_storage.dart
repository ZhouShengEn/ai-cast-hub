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

  /// 获取服务器地址
  ///
  /// 优先级：用户自定义设置 > 平台默认值
  /// - Web: http://localhost:3000/api/v1
  /// - Android 模拟器: http://10.0.2.2:3000/api/v1
  /// - 真机/其他: http://localhost:3000/api/v1
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
    // Android 模拟器专用地址（访问宿主机）
    return 'http://10.0.2.2:3000/api/v1';
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

  /// 保存调试悬浮球开关
  Future<bool> saveDebugBallEnabled(bool enabled) =>
      _prefs.setBool('debug_ball_enabled', enabled);

  /// 保存最近使用的模型列表
  Future<bool> saveRecentModels(List<String> models) =>
      _prefs.setStringList('recent_models', models);

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
      version: 1,
      onCreate: (db, version) async {
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
      },
    );
  }

  /// 确保数据库已初始化
  Future<Database> get db async {
    _db ??= await _initDatabase();
    return _db!;
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
