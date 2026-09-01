import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:permission_handler/permission_handler.dart';

import 'background_service.dart';
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
///
/// Android 14+ (API 34+) 注意：
/// flutter_webrtc 的 OrientationAwareScreenCapturer 内部直接调用
/// MediaProjection.createVirtualDisplay()，但不会启动前台服务。
/// Android 14+ 要求此时必须有一个 foregroundServiceType="mediaProjection"
/// 的前台服务正在运行，否则会抛出 SecurityException 导致应用崩溃。
/// 正确时序是先取得用户授权，再启动前台服务，最后创建 VirtualDisplay。
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

    final isAndroid = !kIsWeb && webrtc.WebRTC.platformIsAndroid;
    DebugService().log(
      '[ScreenCapture] 开始屏幕捕获 (平台: ${isAndroid ? "Android" : "非 Android"}, '
      'API: getDisplayMedia)',
      level: LogLevel.info,
    );

    webrtc.MediaStream? stream;
    try {
      if (isAndroid) {
        // Android 13+ 即使拒绝通知权限仍可启动前台服务，但通知不会显示在
        // 通知抽屉中。主动申请可让用户明确看到正在投屏的持续通知。
        if (await Permission.notification.isDenied) {
          DebugService().log(
            '[ScreenCapture] 请求通知权限...',
            level: LogLevel.info,
          );
          final notificationStatus = await Permission.notification.request();
          if (notificationStatus != PermissionStatus.granted) {
            DebugService().warn(
              '[ScreenCapture] 通知权限被拒绝，继续申请屏幕录制授权',
            );
          }
        }

        // flutter_webrtc 会缓存这次授权返回的 Intent。Android 14+ 要求每次
        // 投屏会话都重新授权，且必须在授权后才能启动 mediaProjection FGS。
        final granted = await webrtc.Helper.requestCapturePermission(
          fullScreenOnly: true,
        );
        if (!granted) {
          throw Exception('用户取消了屏幕录制授权');
        }
        DebugService().log(
          '[ScreenCapture] MediaProjection 用户授权成功',
          level: LogLevel.info,
        );

        final started = await BackgroundService.startMediaProjectionService();
        DebugService().log(
          '[ScreenCapture] MediaProjection 前台服务启动: $started',
          level: started ? LogLevel.info : LogLevel.error,
        );
        if (!started) {
          throw Exception(
            'MediaProjection 前台服务启动失败，请确认应用处于前台后重试',
          );
        }
      }

      stream = await webrtc.navigator.mediaDevices.getDisplayMedia(
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

      _localStream = stream;
      _isCapturing = true;
      return stream;
    } catch (e, stackTrace) {
      if (stream != null) {
        await _disposeStream(stream);
      }
      _localStream = null;
      _isCapturing = false;
      if (isAndroid) {
        await BackgroundService.stopMediaProjectionService();
      }
      DebugService().error(
        '[ScreenCapture] 屏幕捕获失败: $e\n$stackTrace',
      );
      rethrow;
    }
  }

  /// 停止屏幕捕获
  Future<void> stopCapture() async {
    final stream = _localStream;
    _localStream = null;
    _isCapturing = false;

    try {
      if (stream != null) {
        await _disposeStream(stream);
      }
    } finally {
      // 即使捕获在初始化中失败，也强制停止前台服务，防止通知和服务驻留。
      if (!kIsWeb && webrtc.WebRTC.platformIsAndroid) {
        await BackgroundService.stopMediaProjectionService();
      }
    }

    DebugService().log('[ScreenCapture] 停止');
  }

  Future<void> _disposeStream(webrtc.MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (e) {
        DebugService().warn('[ScreenCapture] 停止轨道失败: $e');
      }
    }
    try {
      await stream.dispose();
    } catch (e) {
      DebugService().warn('[ScreenCapture] 释放媒体流失败: $e');
    }
  }
}
