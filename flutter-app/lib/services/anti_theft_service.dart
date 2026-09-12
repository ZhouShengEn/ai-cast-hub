import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'websocket_service.dart';
import 'location_service.dart';

/// 设备防盗指令处理服务（全局单例）
///
/// 订阅设备 WebSocket 消息流，处理来自已配对 PC 的防盗指令：
///  - start_alarm / stop_alarm：经 MethodChannel 调用原生 AntiTheftService 播铃 / 停铃
///  - start_location_track / stop_location_track / request_location：使用 LocationService
///    获取高精度坐标并实时回传 Web 端
///
/// 所有指令均经服务端配对校验后才会下发到本机，本服务只负责执行与回执。
/// 服务必须与 UI 解耦、常驻后台：即便 App 不在前台，只要 WS 连接还在
/// （由 BackgroundConnectionService 持 WakeLock 保活），指令就能抵达并执行。
class AntiTheftService {
  static final AntiTheftService _instance = AntiTheftService._internal();

  factory AntiTheftService() => _instance;

  AntiTheftService._internal();

  final WebSocketService _ws = WebSocketService.instance;
  final LocationService _location = LocationService();
  static const MethodChannel _channel =
      MethodChannel('ai_cast_hub/anti_theft');

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _locationTimer;
  final Set<String> _tracking = {};

  /// 启动监听（App 启动后调用一次即可，幂等）
  void startListening() {
    if (_sub != null) return;
    _sub = _ws.messages.listen(_onMessage);
    debugPrint('[AntiTheft] 已开始监听防盗指令');
  }

  /// 停止监听并清理定时任务（一般无需调用）
  void stopListening() {
    _sub?.cancel();
    _sub = null;
    _stopLocationTimer();
    _tracking.clear();
  }

  void _onMessage(Map<String, dynamic> msg) {
    final type = msg['type'];
    if (type != 'anti_theft_command') return;
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};
    final action = payload['action'] as String?;
    final cmdId = payload['cmdId'] as String?;
    final from = msg['fromDeviceUuid'] as String?;
    if (action == null) return;
    _handle(action, cmdId, from);
  }

  Future<void> _handle(
    String action,
    String? cmdId,
    String? from,
  ) async {
    switch (action) {
      case 'start_alarm':
        await _execNative('startAlarm');
        _ack(action, cmdId, from,
            success: true, message: '已开始响铃');
        break;
      case 'stop_alarm':
        await _execNative('stopAlarm');
        _ack(action, cmdId, from,
            success: true, message: '已停止响铃');
        break;
      case 'start_location_track':
        _startTracking(from);
        _ack(action, cmdId, from,
            success: true, message: '已开始共享位置');
        break;
      case 'stop_location_track':
        _stopTracking(from);
        _ack(action, cmdId, from,
            success: true, message: '已停止共享位置');
        break;
      case 'request_location':
        final pos = await _location.getCurrentPosition();
        if (pos != null) {
          _sendLocation(
            from,
            pos.latitude,
            pos.longitude,
            pos.accuracy,
            pos.timestamp?.millisecondsSinceEpoch,
          );
          _ack(action, cmdId, from,
              success: true, message: '已上报位置');
        } else {
          _ack(action, cmdId, from,
              success: false,
              message: '获取位置失败（未授权或系统定位未开启）');
        }
        break;
      case 'lock_device':
      case 'unlock_device':
        _ack(action, cmdId, from,
            success: false, message: '当前版本不支持锁屏指令');
        break;
      default:
        _ack(action, cmdId, from,
            success: false, message: '不支持的指令: $action');
    }
  }

  Future<void> _execNative(String method) async {
    try {
      await _channel.invokeMethod<bool>(method);
    } catch (e) {
      debugPrint('[AntiTheft] 调用原生 $method 失败: $e');
    }
  }

  void _startTracking(String? from) {
    if (from != null) _tracking.add(from);
    if (_locationTimer != null) return;
    // 立即上报一次，之后每 10 秒刷新（实时同步）
    _tickLocation();
    _locationTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _tickLocation();
    });
  }

  Future<void> _tickLocation() async {
    final pos = await _location.getCurrentPosition();
    if (pos == null) return;
    // 回传给所有正在追踪本机的已配对 PC
    for (final t in _tracking.toList()) {
      _sendLocation(
        t,
        pos.latitude,
        pos.longitude,
        pos.accuracy,
        pos.timestamp?.millisecondsSinceEpoch,
      );
    }
  }

  void _stopTracking(String? from) {
    if (from != null) _tracking.remove(from);
    if (_tracking.isEmpty) _stopLocationTimer();
  }

  void _stopLocationTimer() {
    _locationTimer?.cancel();
    _locationTimer = null;
  }

  void _sendLocation(
    String? target,
    double lat,
    double lng,
    double? accuracy,
    int? ts,
  ) {
    _ws.send({
      'type': 'device_location_update',
      'targetDeviceUuid': target,
      'payload': {
        'latitude': lat,
        'longitude': lng,
        'accuracy': accuracy,
        'timestamp': ts ?? DateTime.now().millisecondsSinceEpoch,
      },
    });
  }

  void _ack(
    String action,
    String? cmdId,
    String? from, {
    required bool success,
    required String message,
  }) {
    _ws.send({
      'type': 'anti_theft_ack',
      'targetDeviceUuid': from,
      'payload': {
        'action': action,
        'cmdId': cmdId,
        'success': success,
        'message': message,
      },
    });
  }
}
