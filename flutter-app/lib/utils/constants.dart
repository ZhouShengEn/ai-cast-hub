import 'package:flutter/foundation.dart';

/// 应用全局常量
///
/// API 地址、超时时间、文件大小限制等配置。
class AppConstants {
  AppConstants._();

  /// API 基础 URL
  static String get apiBaseUrl =>
      kIsWeb ? 'http://localhost:3000/api/v1' : 'http://10.0.2.2:3000/api/v1';

  /// WebSocket 基础 URL
  static String get wsBaseUrl =>
      kIsWeb ? 'ws://localhost:3000' : 'ws://10.0.2.2:3000';

  /// 最大文件传输大小：2GB
  static const int maxFileSize = 2 * 1024 * 1024 * 1024;

  /// 文件分片大小：64KB
  static const int chunkSize = 64 * 1024;

  /// WebSocket 心跳间隔
  static const Duration wsHeartbeatInterval = Duration(seconds: 30);

  /// WebSocket 心跳超时（超过此时间未收到 pong 则重连）
  static const Duration wsHeartbeatTimeout = Duration(seconds: 60);

  /// SSE 超时时间
  static const Duration sseTimeout = Duration(seconds: 300);

  /// ICE 连接超时
  static const Duration iceTimeout = Duration(seconds: 30);

  /// HTTP 连接超时
  static const Duration httpConnectTimeout = Duration(seconds: 10);

  /// HTTP 接收超时
  static const Duration httpReceiveTimeout = Duration(seconds: 30);

  /// 文件分片 ACK 等待超时
  static const Duration chunkAckTimeout = Duration(seconds: 5);

  /// 设备在线判定阈值（5分钟）
  static const Duration deviceOnlineThreshold = Duration(minutes: 5);

  /// 应用版本号
  static const String appVersion = '1.0.0';

  /// 应用名称
  static const String appName = 'AI Cast Hub';
}
