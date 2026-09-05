import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_service.dart';

void _audioLog(String msg, {LogLevel level = LogLevel.debug}) {
  final text = '[SystemAudio] $msg';
  debugPrint(text);
  DebugService().log(text, level: level);
}

/// Android 系统内部音频采集（AudioPlaybackCapture）
///
/// 采集手机**正在播放的声音**（音乐、视频、游戏音效），不采集麦克风。
/// 依赖 Android 10(API 29)+；低版本 [isSupported] 返回 false，前端应禁用入口并提示。
///
/// PCM 格式固定为 16bit / 44.1kHz / 立体声，与原生
/// SystemAudioCaptureManager 中的常量保持一致。
class SystemAudioService {
  static final SystemAudioService _instance = SystemAudioService._internal();
  factory SystemAudioService() => _instance;
  SystemAudioService._internal();

  static const MethodChannel _channel = MethodChannel('ai_cast_hub/system_audio');
  static const EventChannel _pcmChannel =
      EventChannel('ai_cast_hub/system_audio/pcm');

  /// 采样率（需与原生 SystemAudioCaptureManager.SAMPLE_RATE 一致）
  static const int sampleRate = 44100;

  /// 声道数（需与原生 SystemAudioCaptureManager.CHANNEL_COUNT 一致）
  static const int channels = 2;

  /// 位深
  static const int bitsPerSample = 16;

  /// 单帧时长（毫秒）
  static const int frameMillis = 20;

  StreamSubscription<dynamic>? _pcmSubscription;
  final StreamController<Uint8List> _pcmController =
      StreamController<Uint8List>.broadcast();

  bool _isCapturing = false;
  bool _projectionGranted = false;

  bool get isCapturing => _isCapturing;

  /// 是否已取得 MediaProjection 令牌
  bool get projectionGranted => _projectionGranted;

  /// PCM 数据流（16bit / 44.1kHz / 立体声，小端）
  Stream<Uint8List> get pcmStream => _pcmController.stream;

  /// 当前设备是否支持系统内录（Android 10+）
  Future<bool> isSupported() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } on PlatformException catch (e) {
      _audioLog('isSupported 失败: ${e.message}', level: LogLevel.warn);
      return false;
    } on MissingPluginException catch (e) {
      _audioLog('原生通道不可用: ${e.message}', level: LogLevel.warn);
      return false;
    }
  }

  /// 申请独立的屏幕采集授权（用户会看到一次系统弹窗）
  Future<bool> requestProjection() async {
    try {
      final granted = await _channel.invokeMethod<bool>('requestProjection');
      _projectionGranted = granted ?? false;
      _audioLog(
        '屏幕采集授权: ${_projectionGranted ? "已授予" : "被拒绝"}',
        level: _projectionGranted ? LogLevel.info : LogLevel.warn,
      );
      return _projectionGranted;
    } on PlatformException catch (e) {
      _audioLog('申请屏幕采集授权失败: ${e.message}', level: LogLevel.error);
      return false;
    }
  }

  /// 开始采集系统音频
  Future<bool> start() async {
    if (_isCapturing) return true;

    if (!await isSupported()) {
      _audioLog('当前设备不支持系统内录（需要 Android 10+）', level: LogLevel.warn);
      return false;
    }

    // 令牌只需申请一次；已授予则不再打扰用户
    if (!_projectionGranted) {
      final granted = await requestProjection();
      if (!granted) return false;
    }

    // 先挂上 PCM 监听，再启动采集，避免丢掉起始帧
    _pcmSubscription ??= _pcmChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Uint8List && !_pcmController.isClosed) {
          _pcmController.add(event);
        }
      },
      onError: (Object error) {
        _audioLog('PCM 流异常: $error', level: LogLevel.warn);
      },
      cancelOnError: false,
    );

    try {
      final started = await _channel.invokeMethod<bool>('startCapture');
      _isCapturing = started ?? false;
      _audioLog(
        '系统内录启动: $_isCapturing',
        level: _isCapturing ? LogLevel.info : LogLevel.warn,
      );
      if (!_isCapturing) {
        await _releasePcmSubscription();
      }
      return _isCapturing;
    } on PlatformException catch (e) {
      _audioLog('启动系统内录失败: ${e.message}', level: LogLevel.error);
      await _releasePcmSubscription();
      return false;
    }
  }

  /// 停止采集并释放资源
  Future<void> stop() async {
    if (!_isCapturing) {
      await _releasePcmSubscription();
      return;
    }
    try {
      await _channel.invokeMethod<void>('stopCapture');
      _audioLog('系统内录已停止', level: LogLevel.info);
    } on PlatformException catch (e) {
      _audioLog('停止系统内录失败: ${e.message}', level: LogLevel.warn);
    } finally {
      _isCapturing = false;
      await _releasePcmSubscription();
    }
  }

  Future<void> _releasePcmSubscription() async {
    try {
      await _pcmSubscription?.cancel();
    } catch (e) {
      _audioLog('取消 PCM 监听失败: $e', level: LogLevel.warn);
    } finally {
      _pcmSubscription = null;
    }
  }

  /// 释放全部资源（投屏结束 / 服务销毁时调用）
  Future<void> dispose() async {
    await stop();
    if (!_pcmController.isClosed) {
      await _pcmController.close();
    }
  }
}
