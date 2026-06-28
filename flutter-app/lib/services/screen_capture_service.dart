import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'debug_service.dart';

/// 屏幕捕获服务
///
/// 跨平台屏幕捕获：
/// - Android: getDisplayMedia（flutter_webrtc MediaProjection 内建支持）
/// - Web: 浏览器原生 getDisplayMedia
class ScreenCaptureService {
  bool _isCapturing = false;
  webrtc.MediaStream? _localStream;
  String? _lastCaptureSource; // 'screen' | 'camera:front' | 'camera:back'

  bool get isCapturing => _isCapturing;
  String? get lastCaptureSource => _lastCaptureSource;

  /// 开始屏幕捕获
  ///
  /// 统一使用 getDisplayMedia：
  /// - Android: flutter_webrtc 处理后启动 MediaProjection 系统弹窗
  /// - Web: 浏览器弹出屏幕选择器（标签页/窗口/整个屏幕）
  ///
  /// 返回包含视频轨和可选音频轨的 MediaStream
  Future<webrtc.MediaStream> startCapture() async {
    if (_isCapturing) {
      throw StateError('屏幕捕获已在进行中');
    }

    DebugService().log('[ScreenCapture] 使用 getDisplayMedia 进行屏幕捕获 (平台: ${kIsWeb ? "Web" : "Native"})');
    try {
      final stream = await webrtc.navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{
          'video': <String, dynamic>{
            'mandatory': <String, dynamic>{
              'maxWidth': 1920,
              'maxHeight': 1080,
              'maxFrameRate': 30,
            },
          },
          'audio': false,
        },
      );
      _localStream = stream;
      _isCapturing = true;
      _lastCaptureSource = 'screen';

      final tracks = stream.getTracks();
      DebugService().log('[ScreenCapture] 屏幕捕获成功, tracks=${tracks.length}', level: LogLevel.info);

      // 详细打印每个track的信息
      for (final track in tracks) {
        final trackInfo = 'track: kind=${track.kind}, enabled=${track.enabled}, muted=${track.muted}, id=${track.id}';
        DebugService().debug('[ScreenCapture] $trackInfo');
      }
      return stream;
    } catch (e) {
      DebugService().error('[ScreenCapture] 屏幕捕获失败: $e');
      rethrow;
    }
  }

  /// 停止屏幕捕获
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    // 停止本地流的所有轨道
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    _isCapturing = false;
    DebugService().log('[ScreenCapture] 停止');
  }
}
