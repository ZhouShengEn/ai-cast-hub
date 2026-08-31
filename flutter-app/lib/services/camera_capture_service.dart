import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:permission_handler/permission_handler.dart';

import 'debug_service.dart';

/// 摄像头捕获服务
///
/// 使用 getUserMedia 捕获前置/后置摄像头，以便投屏到 PC。
/// 与 ScreenCaptureService 并列，由 CastService 根据用户选择调用。
///
/// 音频说明：开启 [withAudio] 后，麦克风采集的音频轨会随视频轨一起
/// 加入同一条 MediaStream，WebRTC 会自动附加到 PeerConnection 上，
/// 对端（PC Web）即可听到手机声音。
class CameraCaptureService {
  bool _isCapturing = false;
  webrtc.MediaStream? _localStream;
  bool _isFrontCamera = true;
  /// 当前是否开启了音频采集（切换摄像头时保持该设置）
  bool _withAudio = true;

  bool get isCapturing => _isCapturing;
  bool get isFrontCamera => _isFrontCamera;
  bool get isAudioEnabled => _withAudio;

  /// 开始摄像头捕获
  ///
  /// [frontCamera] true=前置摄像头(默认), false=后置摄像头
  /// [withAudio]   true=同时采集麦克风音频并同步到对端(默认开启)
  Future<webrtc.MediaStream> startCapture({
    bool frontCamera = true,
    bool withAudio = true,
  }) async {
    if (_isCapturing) {
      await stopCapture();
    }

    _isFrontCamera = frontCamera;
    _withAudio = withAudio;

    // 摄像头权限：缺失直接失败，没必要继续
    final cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      DebugService().error('[CameraCapture] 摄像头权限被拒绝');
      throw Exception('摄像头权限被拒绝，请在系统设置中开启后重试');
    }

    // 麦克风权限：被拒绝时降级为「仅画面」，不阻断投屏
    var audioEnabled = withAudio;
    if (audioEnabled) {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        audioEnabled = false;
        DebugService().warn('[CameraCapture] 麦克风权限被拒绝，本次仅传输画面');
      }
    }

    DebugService().log(
      '[CameraCapture] 启动${frontCamera ? "前置" : "后置"}摄像头, '
      '音频: ${audioEnabled ? "开" : "关"}',
    );

    try {
      final stream = await webrtc.navigator.mediaDevices.getUserMedia(
        <String, dynamic>{
          'audio': audioEnabled
              ? <String, dynamic>{
                  'echoCancellation': true,
                  'noiseSuppression': true,
                  'autoGainControl': true,
                }
              : false,
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
      final videoCount = tracks.where((t) => t.kind == 'video').length;
      final audioCount = tracks.where((t) => t.kind == 'audio').length;
      DebugService().log(
        '[CameraCapture] ${frontCamera ? "前置" : "后置"}摄像头捕获成功, '
        'tracks=${tracks.length} (video=$videoCount, audio=$audioCount)',
        level: LogLevel.info,
      );

      if (audioEnabled && audioCount == 0) {
        DebugService().warn('[CameraCapture] 已开启音频但未取到音频轨，对端将无声音');
      }

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
    // 保持原有的音频开关设置，避免切换镜头后声音丢失
    await startCapture(frontCamera: newFacing, withAudio: _withAudio);
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
