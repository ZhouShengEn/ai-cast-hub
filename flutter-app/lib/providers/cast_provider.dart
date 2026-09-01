import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cast_service.dart';
import '../services/debug_service.dart';
import '../services/remote_control_service.dart';

/// 投屏状态
class CastState {
  final bool isCasting;
  final String
      connectionState; // 'disconnected' | 'connecting' | 'connected' | 'error'
  final String? roomId;
  final String? error;
  final String captureMode; // 'screen' | 'camera'
  final bool frontCamera; // true=前置, false=后置
  /// 摄像头模式下是否同步采集麦克风音频
  final bool withAudio;

  const CastState({
    this.isCasting = false,
    this.connectionState = 'disconnected',
    this.roomId,
    this.error,
    this.captureMode = 'screen',
    this.frontCamera = true,
    this.withAudio = true,
  });

  CastState copyWith({
    bool? isCasting,
    String? connectionState,
    String? roomId,
    String? error,
    String? captureMode,
    bool? frontCamera,
    bool? withAudio,
  }) {
    return CastState(
      isCasting: isCasting ?? this.isCasting,
      connectionState: connectionState ?? this.connectionState,
      roomId: roomId ?? this.roomId,
      error: error,
      captureMode: captureMode ?? this.captureMode,
      frontCamera: frontCamera ?? this.frontCamera,
      withAudio: withAudio ?? this.withAudio,
    );
  }

  bool get isConnected => connectionState == 'connected';
}

/// 投屏状态管理
class CastNotifier extends StateNotifier<CastState> {
  CastService? _service;

  CastNotifier() : super(const CastState());

  /// 开始投屏
  Future<void> startCasting(String pcDeviceId) async {
    if (state.isCasting) return;

    final mode = state.captureMode;
    final frontCamera = state.frontCamera;
    final withAudio = state.withAudio;

    state = state.copyWith(
      isCasting: true,
      connectionState: 'connecting',
      error: null,
    );

    _service = CastService();
    _service!.onStatusChanged = (status) {
      if (status == 'disconnected') {
        // ICE断开或房间关闭，完全重置状态
        state = state.copyWith(
          connectionState: 'disconnected',
          isCasting: false,
          roomId: null,
        );
      } else if (state.isCasting) {
        state = state.copyWith(
          connectionState: status,
          isCasting: status != 'disconnected',
        );
      }
    };
    _service!.onControlCommand = (command) async {
      await RemoteControlService().executeCommand(command);
    };

    try {
      final session = await _service!.createCastSession(
        pcDeviceId,
        captureMode: mode,
        frontCamera: frontCamera,
        withAudio: withAudio,
      );
      state = state.copyWith(
        roomId: session.roomId,
        connectionState: session.status,
      );
    } catch (e) {
      DebugService().error('[CastProvider] 投屏失败: $e');
      _service?.dispose();
      _service = null;
      state = state.copyWith(
        isCasting: false,
        connectionState: 'error',
        error: '投屏失败: $e',
      );
    }
  }

  /// 切换到屏幕投屏模式
  void setScreenMode() {
    state = state.copyWith(captureMode: 'screen');
  }

  /// 切换到摄像头模式
  void setCameraMode() {
    state = state.copyWith(
      captureMode: 'camera',
      frontCamera: state.frontCamera, // 保持当前摄像头朝向
    );
  }

  /// 切换摄像头朝向（仅摄像头模式有效，即使在非投屏中也可预设）
  void toggleCamera() {
    state = state.copyWith(frontCamera: !state.frontCamera);
  }

  /// 开关麦克风音频同步（摄像头模式下生效，下次开始传输时应用）
  void toggleAudio() {
    state = state.copyWith(withAudio: !state.withAudio);
    DebugService().log(
      '[CastProvider] 音频同步: ${state.withAudio ? "开" : "关"}',
      level: LogLevel.info,
    );
  }

  /// 停止投屏
  Future<void> stopCasting() async {
    final service = _service;
    _service = null;
    try {
      await service?.endCastSession();
    } catch (_) {
      // 忽略停止时的错误
    } finally {
      service?.dispose();
    }
    state = state.copyWith(
      isCasting: false,
      connectionState: 'disconnected',
      roomId: null,
    );
  }

  @override
  void dispose() {
    _service?.dispose();
    _service = null;
    super.dispose();
  }
}

/// 投屏 Provider
final castProvider = StateNotifierProvider<CastNotifier, CastState>((ref) {
  return CastNotifier();
});
