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
  final CastService _service = CastService();

  CastNotifier() : super(const CastState());

  /// 扫描二维码并开始投屏
  /// [pcDeviceId] 从二维码解析得到的目标设备 UUID
  Future<void> scanQRCode(String pcDeviceId) async {
    state = state.copyWith(error: null);
  }

  /// 开始投屏
  Future<void> startCasting(String pcDeviceId) async {
    if (state.isCasting) return;

    state = state.copyWith(
      isCasting: true,
      connectionState: 'connecting',
      error: null,
    );

    try {
      final session = await _service.createCastSession(pcDeviceId);

      // 开始屏幕捕获
      final track = await _service.startCapture();

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
      await _service.endCastSession();
      state = state.copyWith(
        isCasting: false,
        connectionState: 'disconnected',
        roomId: null,
      );
    } catch (e) {
      state = state.copyWith(error: '停止投屏失败: $e');
    }
  }
}

/// 投屏 Provider
final castProvider = StateNotifierProvider<CastNotifier, CastState>((ref) {
  return CastNotifier();
});
