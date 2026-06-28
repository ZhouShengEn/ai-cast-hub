import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'debug_service.dart';

/// 屏幕捕获服务
///
/// 跨平台屏幕捕获：
/// - Android: flutter_webrtc 内建 MediaProjection + ForegroundService
///   直接调用 getUserMedia(sourceId:'screen')，无需自定义 MethodChannel
/// - Web: 浏览器原生 getDisplayMedia
class ScreenCaptureService {
  bool _isCapturing = false;
  webrtc.MediaStream? _localStream;

  bool get isCapturing => _isCapturing;

  /// 开始屏幕捕获
  ///
  /// Android: flutter_webrtc 内部自动处理 MediaProjection 权限弹窗和 ForegroundService
  /// Web: 浏览器弹出屏幕选择器（标签页/窗口/整个屏幕）
  ///
  /// 返回包含视频轨和可选音频轨的 MediaStream
  Future<webrtc.MediaStream> startCapture() async {
    if (_isCapturing) {
      throw StateError('屏幕捕获已在进行中');
    }

    if (kIsWeb) {
      debugPrint('[ScreenCapture] Web: 使用 getDisplayMedia');
      final stream = await webrtc.navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{
          'video': <String, dynamic>{
            'mandatory': <String, dynamic>{
              'maxWidth': 1920,
              'maxHeight': 1080,
              'maxFrameRate': 30,
            },
          },
          'audio': true,
        },
      );
      _localStream = stream;
      _isCapturing = true;
      return stream;
    }

    // Android / iOS: 使用 flutter_webrtc 内建屏幕捕获
    // flutter_webrtc 自动处理 MediaProjection 权限 + ForegroundService
    debugPrint('[ScreenCapture] 平台: 使用 flutter_webrtc 内建屏幕捕获');
    try {
      final stream = await webrtc.navigator.mediaDevices.getUserMedia(
        <String, dynamic>{
          'audio': false,
          'video': <String, dynamic>{
            'sourceId': 'screen',
            'mandatory': <String, dynamic>{
              'maxWidth': 1920,
              'maxHeight': 1080,
              'maxFrameRate': 30,
            },
          },
        },
      );
      _localStream = stream;
      _isCapturing = true;
      debugPrint('[ScreenCapture] 屏幕捕获流已创建, tracks=${stream.getTracks().length}');
      DebugService().log('[ScreenCapture] 屏幕捕获流已创建, tracks=${stream.getTracks().length}');

      // 详细打印每个track的信息
      for (final track in stream.getTracks()) {
        final trackInfo = 'track: kind=${track.kind}, enabled=${track.enabled}, muted=${track.muted}, id=${track.id}';
        debugPrint('[ScreenCapture] $trackInfo');
        DebugService().log('[ScreenCapture] $trackInfo');
      }
      return stream;
    } catch (e) {
      debugPrint('[ScreenCapture] 捕获失败: $e');
      DebugService().log('[ScreenCapture] 捕获失败: $e', level: LogLevel.error);
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
    debugPrint('[ScreenCapture] 停止');
  }
}
