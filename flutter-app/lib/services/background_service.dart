import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 后台连接保持服务
///
/// 启动前台服务保持 WebSocket 连接，防止 Android 系统休眠后断开连接
class BackgroundService {
  static const MethodChannel _channel = MethodChannel('ai_cast_hub/background');

  /// 启动前台服务
  static Future<bool> startService() async {
    try {
      final result = await _channel.invokeMethod<bool>('startService');
      return result ?? false;
    } catch (e) {
      print('[BackgroundService] 启动服务失败: $e');
      return false;
    }
  }

  /// 停止前台服务
  static Future<bool> stopService() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopService');
      return result ?? false;
    } catch (e) {
      print('[BackgroundService] 停止服务失败: $e');
      return false;
    }
  }

  /// 更新通知内容
  static Future<void> updateNotification(String title, String content) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': title,
        'content': content,
      });
    } catch (e) {
      print('[BackgroundService] 更新通知失败: $e');
    }
  }

  /// 启动 MediaProjection 前台服务（仅 Android 14+ 需要）
  ///
  /// Android 14+ (API 34+) 要求调用 MediaProjection.createVirtualDisplay() 时，
  /// 必须有一个 foregroundServiceType="mediaProjection" 的前台服务正在运行，
  /// 否则会抛出 SecurityException 导致应用崩溃。
  ///
  /// 必须在 App 处于前台且用户已授予 MediaProjection 权限后调用，
  /// 并等待原生服务确认进入前台后才能调用 getDisplayMedia()。
  static Future<bool> startMediaProjectionService() async {
    if (kIsWeb) return true;
    try {
      final result =
          await _channel.invokeMethod<bool>('startMediaProjectionService');
      return result ?? false;
    } catch (e) {
      print('[BackgroundService] 启动 MediaProjection 服务失败: $e');
      return false;
    }
  }

  /// 停止 MediaProjection 前台服务
  static Future<bool> stopMediaProjectionService() async {
    if (kIsWeb) return true;
    try {
      final result =
          await _channel.invokeMethod<bool>('stopMediaProjectionService');
      return result ?? false;
    } catch (e) {
      print('[BackgroundService] 停止 MediaProjection 服务失败: $e');
      return false;
    }
  }
}
