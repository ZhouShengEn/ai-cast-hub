import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cast_service.dart';
import '../services/debug_service.dart';

/// 投屏状态
class CastState {
  final bool isCasting;
  final String connectionState; // 'disconnected' | 'connecting' | 'connected' | 'error'
  final String? roomId;
  final String? error;
  final String captureMode; // 'screen' | 'camera'
  final bool frontCamera; // true=前置, false=后置

  const CastState({
    this.isCasting = false,
    this.connectionState = 'disconnected',
    this.roomId,
    this.error,
    this.captureMode = 'screen',
    this.frontCamera = true,
  });

  CastState copyWith({
    bool? isCasting,
    String? connectionState,
    String? roomId,
    String? error,
    String? captureMode,
    bool? frontCamera,
  }) {
    return CastState(
      isCasting: isCasting ?? this.isCasting,
      connectionState: connectionState ?? this.connectionState,
      roomId: roomId ?? this.roomId,
      error: error,
      captureMode: captureMode ?? this.captureMode,
      frontCamera: frontCamera ?? this.frontCamera,
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

    try {
      final session = await _service!.createCastSession(
        pcDeviceId,
        captureMode: mode,
        frontCamera: frontCamera,
      );
      state = state.copyWith(
        roomId: session.roomId,
        connectionState: session.status,
      );
    } catch (e) {
      DebugService().error('[CastProvider] 投屏失败: $e');
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

  /// 停止投屏
  Future<void> stopCasting() async {
    try {
      await _service?.endCastSession();
    } catch (_) {
      // 忽略停止时的错误
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
    super.dispose();
  }
}

/// 投屏 Provider
final castProvider = StateNotifierProvider<CastNotifier, CastState>((ref) {
  return CastNotifier();
});
