import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'websocket_service.dart';
import 'webrtc_service.dart';
import 'screen_capture_service.dart';
import 'camera_capture_service.dart';
import 'api_client.dart';
import 'debug_service.dart';
import '../models/cast_session.dart';

/// 安全截取 ID 用于日志（避免 substring RangeError）
String _safeId(String? id) {
  if (id == null || id.isEmpty) return '(空)';
  if (id.length <= 8) return id;
  return '${id.substring(0, 8)}...';
}

/// 投屏调试日志
void _castLog(String msg, {LogLevel level = LogLevel.debug}) {
  debugPrint('[Cast] $msg');
  DebugService().log('[Cast] $msg', level: level);
}

/// 投屏服务
///
/// 管理投屏会话生命周期：房间创建、屏幕捕获、WebRTC 信令、房间管理。
///
/// 信令流程:
/// 1. App 发送 create_room → 服务器创建房间并通知 PC (room_invitation)
/// 2. App 收到 room_created（含真实 roomId）
/// 3. PC 收到 room_invitation → 发送 join_room → 服务器通知 App (peer_joined)
/// 4. App 收到 peer_joined → 捕获屏幕 → 添加轨道 → 创建 offer → 发送 offer
/// 5. PC 收到 offer → 创建 answer → 发送 answer
/// 6. 双方交换 ICE 候选 → 连接建立
class CastService {
  final WebSocketService _ws = WebSocketService.instance;
  final WebrtcService _webrtc = WebrtcService();
  final ScreenCaptureService _screenCapture = ScreenCaptureService();
  final CameraCaptureService _cameraCapture = CameraCaptureService();

  StreamSubscription? _wsSubscription;
  CastSession? _currentSession;
  bool _isDisposed = false;
  String _captureMode = 'screen'; // 'screen' | 'camera'
  bool _cameraFacing = true; // true=前置, false=后置

  /// 用于等待 room_created 消息
  Completer<String>? _roomCreatedCompleter;
  /// 用于等待 peer_joined 消息
  Completer<void>? _peerJoinedCompleter;

  /// 状态变化回调
  void Function(String status)? onStatusChanged;
  /// 错误回调
  void Function(String error)? onError;
  /// 远程控制指令回调
  void Function(Map<String, dynamic> command)? onControlCommand;

  /// 当前投屏会话
  CastSession? get currentSession => _currentSession;

  StreamSubscription? _dcSubscription;

  // ---- 投屏会话管理 ----

  /// 创建投屏会话
  /// [pcDeviceId] 目标 PC 设备的 UUID
  /// [captureMode] 'screen'（投屏）或 'camera'（手机摄像）
  /// [frontCamera] 摄像头模式下 true=前置, false=后置
  Future<CastSession> createCastSession(String pcDeviceId, {
    String captureMode = 'screen',
    bool frontCamera = true,
  }) async {
    _captureMode = captureMode;
    _cameraFacing = frontCamera;
    _castLog('═══════════════════════════════════════════');
    _castLog('开始创建投屏会话, 目标PC: ${_safeId(pcDeviceId)}, 模式: $_captureMode', level: LogLevel.info);
    _isDisposed = false;

    try {
      // 0. 确保 WebSocket 已连接
      _castLog('步骤0: 确保WebSocket已连接...');
      await _ensureWebSocketConnected();
      _castLog('步骤0: WebSocket已连接 ✓');

      // 1. 从服务器获取 ICE 配置（STUN/TURN）
      _castLog('步骤1: 获取ICE配置...');
      final iceServers = await _fetchIceServers();
      _castLog('步骤1: ICE配置已获取, servers=${iceServers.length}');

      // 2. 创建 WebRTC PeerConnection
      _castLog('步骤2: 创建PeerConnection...');
      await _webrtc.createPeerConnection({
        'iceServers': iceServers,
        // Android 硬件编码偏好：H.264 优先以降低功耗
        'sdpSemantics': 'unified-plan',
      });
      // 设置 H.264 视频编码偏好（Android 硬编码支持，降低功耗提升帧率）
      await _webrtc.setH264Preference();
      _castLog('步骤2: PeerConnection已创建 ✓');

      // 3. 设置 ICE 候选回调和断开回调
      _castLog('步骤3: 设置ICE回调');
      _webrtc.onIceDisconnected(() {
        _castLog('ICE连接断开，重置投屏状态', level: LogLevel.warn);
        _updateSessionStatus('disconnected');
      });
      _webrtc.onIceCandidate((candidate) {
        if (_currentSession == null || _isDisposed) return;
        final candStr = candidate.candidate ?? '';
        final candShort = candStr.length > 40 ? '${candStr.substring(0, 40)}...' : candStr;
        _castLog('ICE候选: $candShort', level: LogLevel.debug);
        _ws.send({
          'type': 'signal',
          'roomId': _currentSession!.roomId,
          'payload': {
            'signalType': 'ice_candidate',
            'candidate': {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
          },
        });
      });

      // 4. 开始监听 WS 消息（在发送 create_room 之前）
      _castLog('步骤4: 开始监听WS消息');
      _wsSubscription = _ws.messages.listen(_handleMessage);

      // 4.5. 监听远端DataChannel创建（PC端会创建control通道）
      _webrtc.onRemoteDataChannel.listen((channel) {
        _castLog('收到远端DataChannel: ${channel.label}，设置消息监听');
        // 远端DataChannel的消息会通过onDataChannelMessage传递
      });

      // 4.6. 监听 DataChannel 消息（远程控制指令）
      _dcSubscription = _webrtc.onDataChannelMessage.listen(_handleDataChannelMessage);

      // 5. 发送 create_room，等待 room_created 响应
      _castLog('步骤5: 发送create_room...');
      _roomCreatedCompleter = Completer<String>();

      final sent = _ws.send({
        'type': 'create_room',
        'payload': {
          'targetDeviceUuid': pcDeviceId,
          'type': 'cast',
        },
      });
      _castLog('步骤5: create_room发送${sent ? "成功" : "失败"}，等待room_created...');

      final roomId = await _roomCreatedCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          '等待 room_created 超时\n'
          '可能原因:\n'
          '1. 服务器收到 create_room 但 PC 端不在线\n'
          '2. 服务器没有正确响应\n'
          '请查看 Flutter 控制台的 [WS] 日志确认消息收发情况',
        ),
      );

      _castLog('步骤5: 收到room_created, roomId=$roomId ✓');

      _currentSession = CastSession(
        roomId: roomId,
        pcDeviceId: pcDeviceId,
        status: 'connecting',
      );

      // 6. 等待 PC 加入房间 (peer_joined)
      _castLog('步骤6: 等待PC加入房间(peer_joined)...');
      _peerJoinedCompleter = Completer<void>();
      await _peerJoinedCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          '等待 PC 加入房间超时\n'
          '可能原因:\n'
          '1. PC 端未打开投屏接收页面\n'
          '2. PC 端 WebSocket 未连接',
        ),
      );
      _castLog('步骤6: peer_joined ✓');

      // 7. 根据模式捕获画面（屏幕或摄像头）
      _castLog('步骤7: 开始$_captureMode捕获...', level: LogLevel.info);
      onStatusChanged?.call('capturing');
      webrtc.MediaStream stream;
      try {
        stream = _captureMode == 'camera'
            ? await _cameraCapture.startCapture(frontCamera: _cameraFacing)
            : await _screenCapture.startCapture();
      } catch (captureError) {
        _castLog('步骤7: 捕获失败: $captureError', level: LogLevel.error);
        throw Exception('屏幕捕获失败: $captureError\n\n'
            '常见原因：\n'
            '1. 未授予屏幕录制权限\n'
            '2. 应用在后台运行（需要在前台）\n'
            '3. 系统版本不支持（Android 5.0+）\n'
            '请返回重试或检查系统设置');
      }
      final tracks = stream.getTracks();
      _castLog('步骤7: $_captureMode捕获完成, tracks=${tracks.length}', level: LogLevel.info);
      for (final t in tracks) {
        _castLog('  track: kind=${t.kind}, enabled=${t.enabled}, muted=${t.muted}, id=${_safeId(t.id)}');
      }

      // 验证至少有一个视频轨道
      final videoTracks = tracks.where((t) => t.kind == 'video').toList();
      if (videoTracks.isEmpty) {
        _castLog('⚠ 未捕获到视频轨道，投屏将显示黑屏', level: LogLevel.error);
        throw Exception('屏幕捕获失败：未获取到视频轨道\n'
            '请确认已授权屏幕录制权限\n'
            '（Android: 需要开启「显示在其他应用上层」权限）');
      }

      // 8. 将屏幕轨道添加到 PeerConnection
      _castLog('步骤8: 添加轨道到PeerConnection (视频轨: ${videoTracks.length})...');
      await _webrtc.addStream(stream);
      _castLog('步骤8: 轨道已添加 ✓');

      // 9. 创建 offer 并发送
      _castLog('步骤9: 创建并发送offer...', level: LogLevel.info);
      final offer = await _webrtc.createOffer();
      _ws.send({
        'type': 'signal',
        'roomId': roomId,
        'payload': {
          'signalType': 'offer',
          'sdp': offer.sdp,
        },
      });
      _castLog('步骤9: offer已发送 ✓ SDP长度=${offer.sdp?.length ?? 0}', level: LogLevel.info);
      _castLog('═══════════════════════════════════════════', level: LogLevel.info);

      return _currentSession!;
    } catch (e) {
      // 失败时清理 WS 订阅、WebRTC 资源和捕获资源（含 MediaProjection 前台服务），避免泄漏
      _castLog('创建会话失败，清理资源: $e', level: LogLevel.error);
      await _wsSubscription?.cancel();
      _wsSubscription = null;
      await _dcSubscription?.cancel();
      _dcSubscription = null;
      // 清理屏幕/摄像头捕获资源（会停止 MediaProjection 前台服务）
      if (_captureMode == 'camera') {
        await _cameraCapture.stopCapture();
      } else {
        await _screenCapture.stopCapture();
      }
      await _webrtc.close();
      _roomCreatedCompleter = null;
      _peerJoinedCompleter = null;
      _currentSession = null;
      rethrow;
    }
  }

  /// 结束投屏会话
  Future<void> endCastSession() async {
    _castLog('结束投屏会话', level: LogLevel.info);
    _isDisposed = true;

    if (_currentSession != null) {
      _ws.send({
        'type': 'close_room',
        'roomId': _currentSession!.roomId,
      });
    }

    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await _dcSubscription?.cancel();
    _dcSubscription = null;
    if (_captureMode == 'camera') {
      await _cameraCapture.stopCapture();
    } else {
      await _screenCapture.stopCapture();
    }
    await _webrtc.close();

    if (_currentSession != null) {
      _currentSession = CastSession(
        roomId: _currentSession!.roomId,
        pcDeviceId: _currentSession!.pcDeviceId,
        status: 'disconnected',
      );
    }
  }

  // ---- WebSocket 消息处理 ----

  void _handleMessage(Map<String, dynamic> message) {
    if (_isDisposed) return;

    final type = message['type'] as String?;
    _castLog('收到WS消息: type=$type', level: LogLevel.debug);

    switch (type) {
      case 'room_created':
        _onRoomCreated(message);
        break;
      case 'peer_joined':
        _onPeerJoined(message);
        break;
      case 'signal':
        _onSignal(message);
        break;
      case 'room_closed':
      case 'peer_disconnected':
        _onRoomClosed(message);
        break;
    }
  }

  // ---- 内部方法 ----

  /// 从服务器获取 ICE 服务器配置（STUN/TURN）
  Future<List<Map<String, dynamic>>> _fetchIceServers() async {
    try {
      final data = await ApiClient.instance.get('/webrtc/config');
      if (data is Map<String, dynamic> && data.containsKey('iceServers')) {
        final servers = data['iceServers'] as List<dynamic>;
        _castLog('从服务器获取ICE配置: ${servers.length}个服务器');
        return servers.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      _castLog('获取ICE配置失败，使用默认STUN: $e', level: LogLevel.warn);
    }
    // 降级到 Google 公共 STUN
    return [
      {'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302']},
    ];
  }

  /// 确保 WebSocket 已连接
  Future<void> _ensureWebSocketConnected() async {
    if (_ws.connectionState != WsConnectionState.connected) {
      _castLog('WebSocket未连接，开始连接...');
      await _ws.connect().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          'WebSocket 连接超时，请检查服务器是否在 http://localhost:3000 运行',
        ),
      );
      _castLog('WebSocket连接成功');
    }
  }

  void _onRoomCreated(Map<String, dynamic> message) {
    final roomId = message['roomId'] as String?;
    _castLog('收到room_created: roomId=$roomId', level: LogLevel.info);
    if (roomId != null && _roomCreatedCompleter != null && !_roomCreatedCompleter!.isCompleted) {
      _roomCreatedCompleter!.complete(roomId);
    }
  }

  void _onPeerJoined(Map<String, dynamic> message) {
    _castLog('收到peer_joined', level: LogLevel.info);
    if (_peerJoinedCompleter != null && !_peerJoinedCompleter!.isCompleted) {
      _peerJoinedCompleter!.complete();
    }
  }

  void _onSignal(Map<String, dynamic> message) {
    final roomId = message['roomId'] as String?;
    if (roomId != _currentSession?.roomId) {
      _castLog('signal roomId不匹配: $roomId != ${_currentSession?.roomId}', level: LogLevel.warn);
      return;
    }

    final payload = message['payload'] as Map<String, dynamic>?;
    if (payload == null) return;

    final signalType = payload['signalType'] as String? ?? payload['type'] as String?;
    _castLog('收到signal: $signalType', level: LogLevel.debug);

    switch (signalType) {
      case 'answer':
        _castLog('收到PC的answer，设置远程SDP', level: LogLevel.info);
        _webrtc.handleAnswer(payload['sdp'] as String);
        _updateSessionStatus('connected');
        _castLog('✅ 投屏连接已建立!', level: LogLevel.info);
        break;
      case 'ice_candidate':
        _castLog('收到PC的ice_candidate', level: LogLevel.debug);
        _webrtc.handleIceCandidate(payload['candidate'] as Map<String, dynamic>);
        break;
      default:
        _castLog('未知signalType: $signalType', level: LogLevel.warn);
    }
  }

  void _onRoomClosed(Map<String, dynamic> message) {
    _castLog('收到room_closed, 投屏结束', level: LogLevel.warn);
    _updateSessionStatus('disconnected');
  }

  void _handleDataChannelMessage(webrtc.RTCDataChannelMessage message) {
    if (_isDisposed) return;
    try {
      final data = jsonDecode(message.text) as Map<String, dynamic>;
      final type = data['type'] as String?;
      _castLog('收到控制指令: $type', level: LogLevel.debug);
      onControlCommand?.call(data);
    } catch (e) {
      _castLog('DataChannel消息解析失败: $e', level: LogLevel.warn);
    }
  }

  void _updateSessionStatus(String status) {
    if (_currentSession == null) return;
    _currentSession = _currentSession!.copyWith(status: status);
    onStatusChanged?.call(status);
  }

  /// 释放资源
  void dispose() {
    _isDisposed = true;
    _wsSubscription?.cancel();
    _cameraCapture.dispose();
    _webrtc.dispose();
  }
}
