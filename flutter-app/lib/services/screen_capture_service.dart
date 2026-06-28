import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'debug_service.dart';

/// 屏幕捕获服务
///
/// 跨平台屏幕捕获：
/// - Android: getDisplayMedia → 内部调用 MediaProjectionManager，弹出系统授权弹窗，
///   用户授权后由 OrientationAwareScreenCapturer 捕获整机屏幕（非摄像头）。
/// - Web: 浏览器原生 getDisplayMedia（标签页/窗口/整个屏幕选择器）
///
/// 注意：flutter_webrtc 的 getUserMedia 在 Android 上始终返回摄像头。
/// 屏幕捕获必须使用 getDisplayMedia。
class ScreenCaptureService {
  bool _isCapturing = false;
  webrtc.MediaStream? _localStream;

  bool get isCapturing => _isCapturing;

  /// 开始屏幕捕获
  ///
  /// Android: getDisplayMedia → MediaProjection 系统弹窗 → 整机屏幕视频轨
  /// Web:      getDisplayMedia → 浏览器屏幕选择器
  Future<webrtc.MediaStream> startCapture() async {
    if (_isCapturing) {
      // 已在捕获中，先停止再重启
      await stopCapture();
    }

    final isNative = !kIsWeb;
    DebugService().log(
      '[ScreenCapture] 开始屏幕捕获 (平台: ${isNative ? "Android/iOS" : "Web"}, '
      'API: getDisplayMedia)',
      level: LogLevel.info,
    );

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

      final tracks = stream.getTracks();
      DebugService().log(
        '[ScreenCapture] 屏幕捕获成功, tracks=${tracks.length}',
        level: LogLevel.info,
      );

      for (final track in tracks) {
        final info = 'track: kind=${track.kind}, enabled=${track.enabled}, '
            'muted=${track.muted}, id=${track.id}, label=${track.label}';
        DebugService().debug('[ScreenCapture] $info');
      }

      // 验证捕获到视频轨道
      final videoTracks = tracks.where((t) => t.kind == 'video').toList();
      if (videoTracks.isEmpty) {
        throw Exception('屏幕捕获失败：未获取到视频轨道，请确认已授权屏幕录制权限');
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
