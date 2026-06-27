import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cast_service.dart';

/// 投屏状态
class CastState {
  final bool isCasting;
  final String connectionState; // 'disconnected' | 'connecting' | 'connected' | 'error'
  final String? roomId;
  final String? error;

  const CastState({
    this.isCasting = false,
    this.connectionState = 'disconnected',
    this.roomId,
    this.error,
  });

  CastState copyWith({
    bool? isCasting,
    String? connectionState,
    String? roomId,
    String? error,
  }) {
    return CastState(
      isCasting: isCasting ?? this.isCasting,
      connectionState: connectionState ?? this.connectionState,
      roomId: roomId ?? this.roomId,
      error: error,
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

    state = state.copyWith(
      isCasting: true,
      connectionState: 'connecting',
      error: null,
    );

    _service = CastService();
    _service!.onStatusChanged = (status) {
      if (state.isCasting) {
        state = state.copyWith(connectionState: status);
      }
    };

    try {
      final session = await _service!.createCastSession(pcDeviceId);
      state = state.copyWith(
        roomId: session.roomId,
        connectionState: session.status,
      );
    } catch (e) {
      state = state.copyWith(
        isCasting: false,
        connectionState: 'error',
        error: '投屏失败: $e',
      );
    }
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
