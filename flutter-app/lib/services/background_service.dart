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
}
