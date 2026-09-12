import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/anti_theft_service.dart';
import '../utils/navigator_key.dart';

/// 设备防盗 UI 状态
class AntiTheftState {
  final bool alarmRinging;
  final bool locationSharing;
  final bool lostMode;
  final String? lastError;
  final List<Map<String, dynamic>> logs;

  const AntiTheftState({
    this.alarmRinging = false,
    this.locationSharing = false,
    this.lostMode = false,
    this.lastError,
    this.logs = const [],
  });

  AntiTheftState copyWith({
    bool? alarmRinging,
    bool? locationSharing,
    bool? lostMode,
    String? lastError,
    List<Map<String, dynamic>>? logs,
  }) {
    return AntiTheftState(
      alarmRinging: alarmRinging ?? this.alarmRinging,
      locationSharing: locationSharing ?? this.locationSharing,
      lostMode: lostMode ?? this.lostMode,
      lastError: lastError,
      logs: logs ?? this.logs,
    );
  }

  bool get isIdle => !alarmRinging && !locationSharing && !lostMode;
}

/// 设备防盗状态管理
///
/// 转发 [AntiTheftService] 的运行状态，并在响铃被远程触发时自动弹出
/// 「设备防盗」页，保证行为对设备持有者可见。
class AntiTheftNotifier extends StateNotifier<AntiTheftState> {
  late final AntiTheftService _service;
  StreamSubscription<AntiTheftStatus>? _statusSub;

  AntiTheftNotifier() : super(const AntiTheftState()) {
    _service = AntiTheftService();
    _statusSub = _service.status.listen(_onStatus);
    _refreshLogs();
  }

  void _onStatus(AntiTheftStatus s) {
    final wasRinging = state.alarmRinging;
    state = state.copyWith(
      alarmRinging: s.alarmRinging,
      locationSharing: s.locationSharing,
      lostMode: s.lostMode,
      lastError: s.lastError,
    );
    _refreshLogs();

    // 响铃被远程触发 → 自动弹出页面，让用户一眼看到并可立即停止
    if (s.alarmRinging && !wasRinging) {
      navigatorKey.currentState?.pushNamed('/anti-theft');
    }
  }

  void _refreshLogs() {
    state = state.copyWith(logs: _service.getLogs());
  }

  /// 停止响铃
  Future<void> stopAlarm() async {
    await _service.stopAlarm();
    _refreshLogs();
  }

  /// 停止位置共享
  Future<void> stopLocationTrack() async {
    await _service.stopLocationTrack();
    _refreshLogs();
  }

  /// 解除丢失模式
  Future<void> exitLostMode() async {
    await _service.exitLostMode();
    _refreshLogs();
  }

  /// 一键停止全部（响铃 + 位置共享）
  Future<void> stopAll() async {
    await _service.stopAll();
    _refreshLogs();
  }

  /// 清空操作日志
  Future<void> clearLogs() async {
    await _service.clearLogs();
    _refreshLogs();
  }

  @override
  void dispose() {
    // 仅取消本 Provider 对状态流的订阅；不销毁 AntiTheftService 单例，
    // 否则会切断全局后台 WS 指令监听（单例在 App 启动即开始监听，与 UI 解耦）。
    _statusSub?.cancel();
    _statusSub = null;
    super.dispose();
  }
}

/// 设备防盗 Provider
final antiTheftProvider =
    StateNotifierProvider<AntiTheftNotifier, AntiTheftState>((ref) {
  return AntiTheftNotifier();
});
