import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_service.dart';
import 'local_storage.dart';
import 'location_service.dart';
import 'websocket_service.dart';

/// 防盗运行状态（对 UI 暴露）
class AntiTheftStatus {
  final bool alarmRinging;
  final bool locationSharing;
  final bool lostMode;
  final String? lastError;

  const AntiTheftStatus({
    this.alarmRinging = false,
    this.locationSharing = false,
    this.lostMode = false,
    this.lastError,
  });

  AntiTheftStatus copyWith({
    bool? alarmRinging,
    bool? locationSharing,
    bool? lostMode,
    String? lastError,
  }) {
    return AntiTheftStatus(
      alarmRinging: alarmRinging ?? this.alarmRinging,
      locationSharing: locationSharing ?? this.locationSharing,
      lostMode: lostMode ?? this.lostMode,
      lastError: lastError,
    );
  }

  bool get isIdle => !alarmRinging && !locationSharing && !lostMode;
}

/// 设备防盗服务（合规版）
///
/// 处理来自**已配对** PC 的防盗指令（服务端已做配对校验，此处只执行）：
///  - start_alarm / stop_alarm   ：可见响铃（原生前台服务 + 常驻通知，随时可停）
///  - start_location_track / stop_location_track：位置共享（前台通知可见，周期上报）
///  - lock_device / unlock_device：丢失模式（App 内可见提示，需本机或 Web 解除）
///
/// 合规约束：不做熄屏静默定位、不做 WakeLock 强行保活；
/// 每次远程指令都会写入本地操作日志，用户可在「设备防盗」页查看。
class AntiTheftService {
  AntiTheftService() {
    _initWsListener();
  }

  static const MethodChannel _channel = MethodChannel('ai_cast_hub/anti_theft');

  /// 用于把 App 从后台唤醒到前台（远程响铃/定位时，让用户立刻看到界面并停止）
  static const MethodChannel _appChannel = MethodChannel('ai_cast_hub/app');

  /// 位置上报间隔
  static const Duration locationReportInterval = Duration(seconds: 30);

  /// 操作日志最多保留条数
  static const int maxLogEntries = 100;

  final LocalStorage _storage = LocalStorage.instance;
  final LocationService _locationService = LocationService();

  StreamSubscription<Map<String, dynamic>>? _wsSubscription;
  Timer? _locationTimer;

  final StreamController<AntiTheftStatus> _statusController =
      StreamController<AntiTheftStatus>.broadcast();

  /// 状态变化流（供 UI / Provider 订阅）
  Stream<AntiTheftStatus> get status => _statusController.stream;

  AntiTheftStatus _status = const AntiTheftStatus();

  /// 当前状态快照
  AntiTheftStatus get currentStatus => _status;

  /// 位置共享 / 回执的目标设备（已配对 PC 的 UUID）
  String? _targetDeviceUuid;

  void _initWsListener() {
    _wsSubscription =
        WebSocketService.instance.messages.listen(_onWsMessage);
  }

  void _onWsMessage(Map<String, dynamic> msg) {
    if (msg['type'] != 'anti_theft_command') return;
    unawaited(_handleCommand(msg));
  }

  Future<void> _handleCommand(Map<String, dynamic> msg) async {
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};
    final action = payload['action'] as String?;
    final fromUuid =
        (msg['fromDeviceUuid'] ?? payload['fromDeviceUuid']) as String?;

    if (action == null) return;
    DebugService().info('[AntiTheft] 收到指令: $action (from=$fromUuid)');

    // 记录指令来源，用于回执与日志
    _targetDeviceUuid = fromUuid;

    switch (action) {
      case 'start_alarm':
        // 远程响铃：先把 App 唤醒到前台，用户可立即看到界面并停止
        await _bringToFront();
        await startAlarm(sourceUuid: fromUuid);
        break;
      case 'stop_alarm':
        await stopAlarm(sourceUuid: fromUuid);
        break;
      case 'start_location_track':
        await _bringToFront();
        await startLocationTrack(sourceUuid: fromUuid);
        break;
      case 'stop_location_track':
        await stopLocationTrack(sourceUuid: fromUuid);
        break;
      case 'lock_device':
        await enterLostMode(sourceUuid: fromUuid);
        break;
      case 'unlock_device':
        await exitLostMode(sourceUuid: fromUuid);
        break;
      default:
        DebugService().warn('[AntiTheft] 未知动作: $action');
        _sendAck(action, false, '未知动作');
    }
  }

  // ---- 响铃 ----

  /// 启动响铃（用户可见：常驻通知 + App 内停止入口，5 分钟自动停止）
  Future<void> startAlarm({String? sourceUuid}) async {
    final ok = await _platformInvoke('startAlarm');
    if (!ok) {
      _emit(_status.copyWith(lastError: '响铃启动失败（需 Android 平台）'));
      _sendAck('start_alarm', false, '平台不支持或启动失败');
      await _log('start_alarm', sourceUuid, '启动失败');
      return;
    }
    _emit(_status.copyWith(alarmRinging: true, lastError: null));
    _sendAck('start_alarm', true, '设备开始响铃');
    await _log('start_alarm', sourceUuid, '已开始响铃（可随时停止）');
  }

  /// 停止响铃并恢复原始音量
  Future<void> stopAlarm({String? sourceUuid}) async {
    await _platformInvoke('stopAlarm');
    _emit(_status.copyWith(alarmRinging: false));
    _sendAck('stop_alarm', true, '响铃已停止');
    await _log('stop_alarm', sourceUuid, '响铃已停止，音量已恢复');
  }

  // ---- 位置共享 ----

  /// 开启位置共享（前台通知可见，周期上报坐标）
  Future<void> startLocationTrack({String? sourceUuid}) async {
    final hasPermission = await _locationService.ensurePermission();
    if (!hasPermission) {
      _emit(_status.copyWith(
          lastError: '未获得定位权限，请在系统设置中授权后重试'));
      _sendAck('start_location_track', false, '未获得定位权限');
      await _log('start_location_track', sourceUuid, '失败：无定位权限');
      return;
    }

    await _platformInvoke('startLocationSharing');
    _emit(_status.copyWith(locationSharing: true, lastError: null));
    _sendAck('start_location_track', true, '位置共享已开启');

    // 立即上报一次，随后按固定间隔持续上报
    unawaited(_reportLocation());
    _locationTimer?.cancel();
    _locationTimer =
        Timer.periodic(locationReportInterval, (_) => _reportLocation());

    await _log('start_location_track', sourceUuid,
        '位置共享已开启（每 ${locationReportInterval.inSeconds}s 上报）');
  }

  /// 停止位置共享
  Future<void> stopLocationTrack({String? sourceUuid}) async {
    _locationTimer?.cancel();
    _locationTimer = null;
    await _platformInvoke('stopLocationSharing');
    _emit(_status.copyWith(locationSharing: false));
    _sendAck('stop_location_track', true, '位置共享已停止');
    await _log('stop_location_track', sourceUuid, '位置共享已停止');
  }

  /// 上报一次坐标给已配对的 PC
  Future<void> _reportLocation() async {
    final position = await _locationService.getCurrentPosition();
    if (position == null) {
      DebugService().warn('[AntiTheft] 获取坐标失败，跳过本次上报');
      return;
    }
    WebSocketService.instance.send({
      'type': 'device_location_update',
      if (_targetDeviceUuid != null) 'targetDeviceUuid': _targetDeviceUuid,
      'payload': {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'speed': position.speed,
        'heading': position.heading,
        'timestamp':
            (position.timestamp ?? DateTime.now()).toIso8601String(),
      },
    });
  }

  // ---- 丢失模式 ----

  /// 进入丢失模式：App 内显示「设备已标记丢失」提示，需本机或 Web 解除
  Future<void> enterLostMode({String? sourceUuid}) async {
    _emit(_status.copyWith(lostMode: true));
    _sendAck('lock_device', true, '设备已标记为丢失');
    await _log('lock_device', sourceUuid, '已进入丢失模式');
  }

  /// 退出丢失模式
  Future<void> exitLostMode({String? sourceUuid}) async {
    _emit(_status.copyWith(lostMode: false));
    _sendAck('unlock_device', true, '丢失模式已解除');
    await _log('unlock_device', sourceUuid, '丢失模式已解除');
  }

  // ---- 本机手动控制（供 UI 调用）----

  /// 一键停止所有防盗行为（响铃 + 位置共享）
  Future<void> stopAll({String? sourceUuid}) async {
    _locationTimer?.cancel();
    _locationTimer = null;
    await _platformInvoke('stopAll');
    _emit(const AntiTheftStatus());
    await _log('stop_all', sourceUuid, '本机手动停止全部防盗行为');
  }

  /// 读取本地操作日志（最新的在前）
  List<Map<String, dynamic>> getLogs() => _storage.getAntiTheftLogs();

  /// 清空操作日志
  Future<void> clearLogs() async => _storage.saveAntiTheftLogs([]);

  // ---- 内部方法 ----

  void _emit(AntiTheftStatus next) {
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  /// 收到远程指令时把 App 从后台唤醒到前台（仅 Android）
  ///
  /// 即便 App 处于后台，原生前台服务仍会响铃/定位；但把界面也拉到前台，
  /// 用户能立刻看到「设备防盗」页并手动停止，体验更直观。
  Future<void> _bringToFront() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;
    try {
      await _appChannel.invokeMethod('bringToFront');
    } catch (e) {
      DebugService().warn('[AntiTheft] 唤醒前台失败: $e');
    }
  }

  /// 调用 Android 原生能力；非 Android 平台直接返回 false
  Future<bool> _platformInvoke(String method) async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>(method);
      return result ?? false;
    } on PlatformException catch (e) {
      DebugService().error('[AntiTheft] $method 调用失败: ${e.message}');
      return false;
    } catch (e) {
      DebugService().error('[AntiTheft] $method 异常: $e');
      return false;
    }
  }

  /// 发送执行回执给发起指令的 PC
  void _sendAck(String action, bool success, String message) {
    WebSocketService.instance.send({
      'type': 'anti_theft_ack',
      if (_targetDeviceUuid != null) 'targetDeviceUuid': _targetDeviceUuid,
      'payload': {
        'action': action,
        'success': success,
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
      },
    });
  }

  /// 写入操作日志（用户可见）
  Future<void> _log(String action, String? sourceUuid, String note) async {
    try {
      final logs = _storage.getAntiTheftLogs();
      logs.insert(0, {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'action': action,
        'sourceDeviceUuid': sourceUuid ?? '',
        'timestamp': DateTime.now().toIso8601String(),
        'note': note,
      });
      if (logs.length > maxLogEntries) {
        logs.removeRange(maxLogEntries, logs.length);
      }
      await _storage.saveAntiTheftLogs(logs);
    } catch (e) {
      DebugService().error('[AntiTheft] 写入操作日志失败: $e');
    }
  }

  void dispose() {
    _locationTimer?.cancel();
    _locationTimer = null;
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _statusController.close();
  }
}
