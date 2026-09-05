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
        case 'long_press':
          return _handleLongPress(command);
        case 'swipe':
          return _handleSwipe(command);
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
        case 'volume_up':
          return _handleVolumeAdjust(1);
        case 'volume_down':
          return _handleVolumeAdjust(-1);
        case 'screenshot':
          return _performGlobalAction('screenshot');
        case 'power':
          return _performGlobalAction('power');
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
    final x = (command['x'] as num?)?.toDouble();
    final y = (command['y'] as num?)?.toDouble();
    if (x == null || y == null) {
      _rcLog('缺少坐标参数', level: LogLevel.warn);
      return false;
    }

    _rcLog('执行点击: (${(x * 100).round()}%, ${(y * 100).round()}%)');
    return _dispatchTap(x, y);
  }

  /// 长按：Web 端在 pointerdown 后启动计时器，位移未超阈值且达到时长即触发
  Future<bool> _handleLongPress(Map<String, dynamic> command) async {
    final x = (command['x'] as num?)?.toDouble();
    final y = (command['y'] as num?)?.toDouble();
    final duration = (command['duration'] as num?)?.toInt() ?? 600;
    if (x == null || y == null) {
      _rcLog('长按指令缺少坐标参数', level: LogLevel.warn);
      return false;
    }

    _rcLog(
      '执行长按: (${(x * 100).round()}%, ${(y * 100).round()}%), ${duration}ms',
    );
    return _dispatchLongPress(x, y, duration);
  }

  Future<bool> _handleSwipe(Map<String, dynamic> command) async {
    final startX = (command['startX'] as num?)?.toDouble();
    final startY = (command['startY'] as num?)?.toDouble();
    final endX = (command['endX'] as num?)?.toDouble();
    final endY = (command['endY'] as num?)?.toDouble();
    final duration = (command['duration'] as num?)?.toInt() ?? 300;
    if (startX == null || startY == null || endX == null || endY == null) {
      _rcLog('滑动指令缺少坐标参数', level: LogLevel.warn);
      return false;
    }

    _rcLog(
      '执行滑动: (${(startX * 100).round()}%, ${(startY * 100).round()}%) -> '
      '(${(endX * 100).round()}%, ${(endY * 100).round()}%), ${duration}ms',
    );
    try {
      final result = await _channel.invokeMethod<bool>('dispatchSwipe', {
        'startX': startX,
        'startY': startY,
        'endX': endX,
        'endY': endY,
        'duration': duration.clamp(50, 2000),
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchSwipe失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _handleTouchStart(Map<String, dynamic> command) async {
    final x = (command['x'] as num?)?.toDouble();
    final y = (command['y'] as num?)?.toDouble();
    if (x == null || y == null) return false;

    _rcLog('触摸开始: ($x, $y)');
    return _dispatchTouchStart(x, y);
  }

  Future<bool> _handleTouchMove(Map<String, dynamic> command) async {
    final x = (command['x'] as num?)?.toDouble();
    final y = (command['y'] as num?)?.toDouble();
    if (x == null || y == null) return false;

    _rcLog('触摸移动: ($x, $y)');
    return _dispatchTouchMove(x, y);
  }

  Future<bool> _handleTouchEnd(Map<String, dynamic> command) async {
    final x = (command['x'] as num?)?.toDouble();
    final y = (command['y'] as num?)?.toDouble();
    if (x == null || y == null) return false;

    _rcLog('触摸结束: ($x, $y)');
    return _dispatchTouchEnd(x, y);
  }

  Future<bool> _handleScroll(Map<String, dynamic> command) async {
    final x = (command['x'] as num?)?.toDouble();
    final y = (command['y'] as num?)?.toDouble();
    final deltaX = (command['deltaX'] as num?)?.toDouble() ?? 0;
    final deltaY = (command['deltaY'] as num?)?.toDouble() ?? 0;

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

  /// 音量调节：direction>0 增大，<0 减小（经 Kotlin AudioManager 调整媒体音量）
  Future<bool> _handleVolumeAdjust(int direction) async {
    _rcLog('执行音量调节: ${direction > 0 ? '+' : '-'}');
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchVolumeAdjust',
        {'direction': direction},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchVolumeAdjust失败: ${e.message}', level: LogLevel.error);
      return false;
    }
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

  Future<bool> _dispatchLongPress(
    double xPercent,
    double yPercent,
    int durationMs,
  ) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'dispatchLongPress',
        {
          'x': xPercent,
          'y': yPercent,
          'duration': durationMs.clamp(500, 3000).toInt(),
        },
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _rcLog('dispatchLongPress失败: ${e.message}', level: LogLevel.error);
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
      _rcLog(
        '无障碍服务检测结果: ${_isEnabled ? "已开启" : "未开启"}',
        level: _isEnabled ? LogLevel.info : LogLevel.warn,
      );
      return _isEnabled;
    } on PlatformException catch (e) {
      _rcLog('检查服务状态失败: ${e.message}', level: LogLevel.error);
      return false;
    } on MissingPluginException catch (e) {
      _rcLog('原生通道不可用: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  /// 采集一份状态快照，供上层通过 DataChannel 上报给 Web 端做 UI 提示
  Future<Map<String, dynamic>> getStatus() async {
    final enabled = await checkServiceEnabled();
    return <String, dynamic>{
      'accessibilityEnabled': enabled,
      'platform': defaultTargetPlatform.name,
    };
  }

  /// 投屏结束时释放原生手势运行态（未抬起的触点等）
  Future<void> clearGestureState() async {
    try {
      await _channel.invokeMethod<void>('clearGestureState');
    } on PlatformException catch (e) {
      _rcLog('清理手势状态失败: ${e.message}', level: LogLevel.warn);
    } on MissingPluginException catch (e) {
      _rcLog('原生通道不可用: ${e.message}', level: LogLevel.warn);
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
