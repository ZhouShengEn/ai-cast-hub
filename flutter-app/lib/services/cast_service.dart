import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'websocket_service.dart';
import 'webrtc_service.dart';
import '../models/cast_session.dart';

/// 投屏服务
///
/// 管理投屏会话生命周期：权限申请、屏幕捕获、WebRTC 信令、房间管理。
class CastService {
  final WebSocketService _ws = WebSocketService.instance;
  final WebrtcService _webrtc = WebrtcService();

  StreamSubscription? _wsSubscription;

  CastSession? _currentSession;

  /// 当前投屏会话
  CastSession? get currentSession => _currentSession;

  // ---- 权限与捕获 ----

  /// 请求录屏权限（返回 true 表示已授权）
  Future<bool> requestPermission() async {
    // 注：Android MediaProjection 和 iOS ReplayKit 通过 platform channel 实现
    // 此处作为占位实现，实际项目需集成 screen_recording 插件或自定义 MethodChannel
    try {
      // 使用 permission_handler 检查麦克风权限（录屏通常伴随音频）
      // 实际录屏权限需要 platform-specific 实现
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 开始屏幕捕获
  /// 返回本地视频轨，如果权限未授予则返回 null
  Future<MediaStreamTrack?> startCapture() async {
    final granted = await requestPermission();
    if (!granted) return null;

    // 注：实际录屏需通过 platform channel 获取 MediaStreamTrack
    // 此处作为占位，返回 null 表示需要 platform-specific 实现
    return null;
  }

  /// 停止屏幕捕获
  Future<void> stopCapture() async {
    // 停止录屏（platform-specific）
  }

  // ---- 投屏会话管理 ----

  /// 创建投屏会话
  /// [pcDeviceId] 目标 PC 设备的 UUID
  Future<CastSession> createCastSession(String pcDeviceId) async {
    final roomId = 'room_${DateTime.now().millisecondsSinceEpoch}';

    _currentSession = CastSession(
      roomId: roomId,
      pcDeviceId: pcDeviceId,
      status: 'connecting',
    );

    // 通过 WebSocket 发送创建房间请求
    _ws.send({
      'type': 'create_room',
      'roomId': roomId,
      'pcDeviceId': pcDeviceId,
      'roomType': 'cast',
    });

    // 创建 WebRTC PeerConnection
    await _webrtc.createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    // 创建 offer 并发送
    final offer = await _webrtc.createOffer();
    _ws.send({
      'type': 'signal',
      'roomId': roomId,
      'payload': {
        'type': 'offer',
        'sdp': offer.sdp,
      },
    });

    // 监听 WebSocket 信令消息
    _wsSubscription = _ws.messages.listen(_handleSignal);

    return _currentSession!;
  }

  /// 结束投屏会话
  Future<void> endCastSession() async {
    if (_currentSession == null) return;

    _ws.send({
      'type': 'close_room',
      'roomId': _currentSession!.roomId,
    });

    await _wsSubscription?.cancel();
    await stopCapture();
    await _webrtc.close();

    _currentSession = CastSession(
      roomId: _currentSession!.roomId,
      pcDeviceId: _currentSession!.pcDeviceId,
      status: 'disconnected',
    );
  }

  /// 处理 WebSocket 信令消息
  void _handleSignal(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type != 'signal') return;

    final roomId = message['roomId'] as String?;
    if (roomId != _currentSession?.roomId) return;

    final payload = message['payload'] as Map<String, dynamic>?;
    if (payload == null) return;

    final signalType = payload['type'] as String?;

    switch (signalType) {
      case 'answer':
        _webrtc.handleAnswer(payload['sdp'] as String);
        _updateSessionStatus('connected');
        break;
      case 'ice_candidate':
        _webrtc.handleIceCandidate(payload);
        break;
    }
  }

  void _updateSessionStatus(String status) {
    if (_currentSession == null) return;
    _currentSession = _currentSession!.copyWith(status: status);
  }

  /// 释放资源
  void dispose() {
    _wsSubscription?.cancel();
    _webrtc.dispose();
  }
}
