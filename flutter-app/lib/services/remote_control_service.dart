import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'debug_service.dart';

void _rcLog(String msg, {LogLevel level = LogLevel.debug}) {
  final text = '[RemoteControl] $msg';
  debugPrint(text);
  DebugService().log(text, level: level);
}

class RemoteControlService {
  static final RemoteControlService _instance = RemoteControlService._internal();
  factory RemoteControlService() => _instance;
  RemoteControlService._internal();

  bool _isEnabled = false;
  bool _isServiceRunning = false;

  bool get isEnabled => _isEnabled;
  bool get isServiceRunning => _isServiceRunning;

  Future<bool> executeCommand(Map<String, dynamic> command) async {
    final type = command['type'] as String?;
    if (type == null) {
      _rcLog('缺少指令类型', level: LogLevel.warn);
      return false;
    }

    try {
      switch (type) {
        case 'tap':
          return _handleTap(command);
        case 'touch_start':
          return _handleTouchStart(command);
        case 'touch_move':
          return _handleTouchMove(command);
        case 'touch_end':
          return _handleTouchEnd(command);
        case 'scroll':
          return _handleScroll(command);
        case 'home':
          return _handleHome();
        case 'back':
          return _handleBack();
        case 'recent':
          return _handleRecent();
        default:
          _rcLog('未知指令类型: $type', level: LogLevel.warn);
          return false;
      }
    } catch (e) {
      _rcLog('执行指令失败: $e', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _handleTap(Map<String, dynamic> command) async {
    final x = command['x'] as double?;
    final y = command['y'] as double?;
    if (x == null || y == null) {
      _rcLog('缺少坐标参数', level: LogLevel.warn);
      return false;
    }

    _rcLog('执行点击: (${(x * 100).round()}%, ${(y * 100).round()}%)');
    return _dispatchTap(x, y);
  }

  Future<bool> _handleTouchStart(Map<String, dynamic> command) async {
    final x = command['x'] as double?;
    final y = command['y'] as double?;
    if (x == null || y == null) return false;

    _rcLog('触摸开始: ($x, $y)');
    return _dispatchTouchStart(x, y);
  }

  Future<bool> _handleTouchMove(Map<String, dynamic> command) async {
    final x = command['x'] as double?;
    final y = command['y'] as double?;
    if (x == null || y == null) return false;

    _rcLog('触摸移动: ($x, $y)');
    return _dispatchTouchMove(x, y);
  }

  Future<bool> _handleTouchEnd(Map<String, dynamic> command) async {
    final x = command['x'] as double?;
    final y = command['y'] as double?;
    if (x == null || y == null) return false;

    _rcLog('触摸结束: ($x, $y)');
    return _dispatchTouchEnd(x, y);
  }

  Future<bool> _handleScroll(Map<String, dynamic> command) async {
    final x = command['x'] as double?;
    final y = command['y'] as double?;
    final deltaX = command['deltaX'] as double? ?? 0;
    final deltaY = command['deltaY'] as double? ?? 0;

    if (x == null || y == null) return false;

    _rcLog('执行滚动: ($x, $y) delta=($deltaX, $deltaY)');
    return _dispatchScroll(x, y, deltaX, deltaY);
  }

  Future<bool> _handleHome() async {
    _rcLog('执行Home键');
    return _performGlobalAction('home');
  }

  Future<bool> _handleBack() async {
    _rcLog('执行Back键');
    return _performGlobalAction('back');
  }

  Future<bool> _handleRecent() async {
    _rcLog('执行多任务键');
    return _performGlobalAction('recent');
  }

  Future<bool> _dispatchTap(double xPercent, double yPercent) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchTap',
        {'x': xPercent, 'y': yPercent},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchTap失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _dispatchTouchStart(double xPercent, double yPercent) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchTouchStart',
        {'x': xPercent, 'y': yPercent},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchTouchStart失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _dispatchTouchMove(double xPercent, double yPercent) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchTouchMove',
        {'x': xPercent, 'y': yPercent},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchTouchMove失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _dispatchTouchEnd(double xPercent, double yPercent) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchTouchEnd',
        {'x': xPercent, 'y': yPercent},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchTouchEnd失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _dispatchScroll(double xPercent, double yPercent, double deltaX, double deltaY) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchScroll',
        {'x': xPercent, 'y': yPercent, 'deltaX': deltaX, 'deltaY': deltaY},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchScroll失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _performGlobalAction(String action) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'performGlobalAction',
        {'action': action},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('performGlobalAction失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> checkServiceEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkAccessibilityEnabled');
      _isEnabled = result ?? false;
      return _isEnabled;
    } on PlatformException catch (e) {
      _rcLog('检查服务状态失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } on PlatformException catch (e) {
      _rcLog('打开无障碍设置失败: ${e.message}', level: LogLevel.error);
    }
  }

  static const MethodChannel _channel = MethodChannel('ai_cast_hub/remote_control');
}