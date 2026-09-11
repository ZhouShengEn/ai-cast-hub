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

  /// 远程控制诊断信息：connected / settingsEnabled / state / 屏幕尺寸
  ///
  /// connected 表示无障碍服务实例已绑定到本进程，是「能否真正派发手势」的唯一判据；
  /// settingsEnabled 只表示用户在系统设置里打开了开关。二者常常不一致。
  Future<Map<String, dynamic>> getControlDiagnostics() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getControlDiagnostics',
      );
      if (result == null) return <String, dynamic>{};
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      _rcLog('获取控制诊断失败: ${e.message}', level: LogLevel.warn);
      return <String, dynamic>{};
    } on MissingPluginException catch (e) {
      _rcLog('原生通道不可用: ${e.message}', level: LogLevel.warn);
      return <String, dynamic>{};
    }
  }

  /// 无障碍服务实例是否已绑定（决定能否真正派发手势）
  Future<bool> checkServiceConnected() async {
    final diag = await getControlDiagnostics();
    return diag['connected'] == true;
  }

  /// 仅在系统设置中已启用本服务（不代表实例已绑定、也不代表能派发手势）
  Future<bool> isEnabledInSettings() async {
    final diag = await getControlDiagnostics();
    return diag['settingsEnabled'] == true;
  }

  /// 无障碍服务真实状态快照
  ///
  /// - [connectedOrSettings]: 服务实例已绑定（可用）或仅系统设置已开启
  /// - [accessibilityEnabled] 严格取「实例已绑定(connected)」——只有它为真时
  ///   dispatchGesture 才可能派发成功，避免 Web 端显示「已开启」却点了没反应。
  /// - 分辨率绝不为 0：原生取不到时用 Flutter 窗口物理像素兜底，
  ///   否则 Web 端按 0 宽高换算坐标会全部落在 (0,0)，看起来像「触控失效」。
  Future<Map<String, dynamic>> getStatus() async {
    final diag = await getControlDiagnostics();
    var connected = diag['connected'] == true;
    var width = (diag['screenWidth'] as num?)?.toInt() ?? 0;
    var height = (diag['screenHeight'] as num?)?.toInt() ?? 0;

    if (width <= 0 || height <= 0) {
      final fallback = _fallbackScreenSize();
      width = fallback['width']!;
      height = fallback['height']!;
    }

    // 服务实例未绑定时，再补一次宽松探测（部分 ROM 的实例绑定有延迟），
    // 但 accessibilityEnabled 仍只认 connected，避免「已开启但未生效」的误报。
    if (!connected) {
      try {
        final enabledInSettings = await isEnabledInSettings();
        if (enabledInSettings) {
          final retry =
              await _channel.invokeMethod<Map<dynamic, dynamic>>(
            'getControlDiagnostics',
          );
          if (retry != null && retry['connected'] == true) {
            connected = true;
          }
        }
      } catch (_) {
        // 探测失败不影响本次上报
      }
    }

    _isEnabled = connected;
    _isServiceRunning = connected;
    return <String, dynamic>{
      'accessibilityEnabled': connected,
      'settingsEnabled': diag['settingsEnabled'] == true,
      'state': diag['state'] ?? 'unknown',
      'screenWidth': width,
      'screenHeight': height,
      'displayId': diag['displayId'] ?? -1,
      if ((diag['lastError'] as String?)?.isNotEmpty == true)
        'lastError': diag['lastError'],
      'platform': defaultTargetPlatform.name,
    };
  }

  /// 原生拿不到屏幕尺寸时的兜底：取 Flutter 窗口的物理像素
  Map<String, int> _fallbackScreenSize() {
    try {
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      final size = dispatcher.implicitView?.physicalSize ??
          (dispatcher.views.isNotEmpty ? dispatcher.views.first.physicalSize : null);
      if (size != null && size.width > 0 && size.height > 0) {
        return {'width': size.width.round(), 'height': size.height.round()};
      }
    } catch (_) {
      // 兜底失败则保持 0
    }
    return {'width': 0, 'height': 0};
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

  /// 无障碍服务三态，供 UI 直接展示：
  /// - enabled：服务实例已绑定，远程控制真正可用
  /// - settings_only：系统设置已开启，但实例未绑定（未生效）
  /// - disabled：未开启
  Future<String> accessibilityState() async {
    final diag = await getControlDiagnostics();
    if (diag['connected'] == true) return 'enabled';
    if (diag['settingsEnabled'] == true) return 'settings_only';
    return 'disabled';
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
