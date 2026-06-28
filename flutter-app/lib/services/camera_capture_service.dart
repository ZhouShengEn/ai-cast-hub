import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'debug_service.dart';

/// 摄像头捕获服务
///
/// 使用 getUserMedia 捕获前置/后置摄像头，以便投屏到 PC。
/// 与 ScreenCaptureService 并列，由 CastService 根据用户选择调用。
class CameraCaptureService {
  bool _isCapturing = false;
  webrtc.MediaStream? _localStream;
  bool _isFrontCamera = true;

  bool get isCapturing => _isCapturing;
  bool get isFrontCamera => _isFrontCamera;

  /// 开始摄像头捕获
  ///
  /// [frontCamera] true=前置摄像头(默认), false=后置摄像头
  Future<webrtc.MediaStream> startCapture({bool frontCamera = true}) async {
    if (_isCapturing) {
      await stopCapture();
    }

    _isFrontCamera = frontCamera;

    DebugService().log('[CameraCapture] 启动${frontCamera ? "前置" : "后置"}摄像头');
    try {
      final stream = await webrtc.navigator.mediaDevices.getUserMedia(
        <String, dynamic>{
          'audio': false,
          'video': <String, dynamic>{
            'facingMode': frontCamera ? 'user' : 'environment',
            'mandatory': <String, dynamic>{
              'maxWidth': 1280,
              'maxHeight': 720,
              'maxFrameRate': 30,
            },
          },
        },
      );

      _localStream = stream;
      _isCapturing = true;

      final tracks = stream.getTracks();
      DebugService().log('[CameraCapture] ${frontCamera ? "前置" : "后置"}摄像头捕获成功, tracks=${tracks.length}', level: LogLevel.info);

      for (final track in tracks) {
        final info = 'track: kind=${track.kind}, enabled=${track.enabled}, muted=${track.muted}, id=${track.id}';
        DebugService().debug('[CameraCapture] $info');
      }
      return stream;
    } catch (e) {
      DebugService().error('[CameraCapture] 摄像头捕获失败: $e');
      rethrow;
    }
  }

  /// 切换前后摄像头（仅在捕获中有效）
  Future<void> toggleCamera() async {
    if (!_isCapturing) return;

    final newFacing = !_isFrontCamera;
    DebugService().log('[CameraCapture] 切换到${newFacing ? "前置" : "后置"}摄像头');
    await startCapture(frontCamera: newFacing);
  }

  /// 停止摄像头捕获
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    _isCapturing = false;
    DebugService().log('[CameraCapture] 摄像头捕获已停止');
  }

  /// 释放资源
  void dispose() {
    stopCapture();
  }
}
