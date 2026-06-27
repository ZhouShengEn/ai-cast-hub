import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'websocket_service.dart';
import 'webrtc_service.dart';
import '../models/cast_session.dart';

/// 安全截取 ID 用于日志（避免 substring RangeError）
String _safeId(String? id) {
  if (id == null || id.isEmpty) return '(空)';
  if (id.length <= 8) return id;
  return '${id.substring(0, 8)}...';
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

  StreamSubscription? _wsSubscription;
  CastSession? _currentSession;
  bool _isDisposed = false;

  /// 用于等待 room_created 消息
  Completer<String>? _roomCreatedCompleter;
  /// 用于等待 peer_joined 消息
  Completer<void>? _peerJoinedCompleter;

  /// 状态变化回调
  void Function(String status)? onStatusChanged;
  /// 错误回调
  void Function(String error)? onError;

  /// 当前投屏会话
  CastSession? get currentSession => _currentSession;

  // ---- 投屏会话管理 ----

  /// 创建投屏会话
  /// [pcDeviceId] 目标 PC 设备的 UUID
  Future<CastSession> createCastSession(String pcDeviceId) async {
    debugPrint('═══════════════════════════════════════════');
    debugPrint('[Cast] 开始创建投屏会话');
    debugPrint('[Cast] 目标 PC 设备: ${_safeId(pcDeviceId)}');
    _isDisposed = false;

    // 0. 确保 WebSocket 已连接
    debugPrint('[Cast] 步骤0: 确保 WebSocket 已连接...');
    await _ensureWebSocketConnected();
    debugPrint('[Cast] 步骤0: WebSocket 已连接 ✓');

    // 1. 创建 WebRTC PeerConnection
    debugPrint('[Cast] 步骤1: 创建 PeerConnection...');
    await _webrtc.createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    debugPrint('[Cast] 步骤1: PeerConnection 已创建 ✓');

    // 2. 设置 ICE 候选回调
    debugPrint('[Cast] 步骤2: 设置 ICE 候选回调');
    _webrtc.onIceCandidate((candidate) {
      if (_currentSession == null || _isDisposed) return;
      final candStr = candidate.candidate ?? '';
      final candShort = candStr.length > 40 ? '${candStr.substring(0, 40)}...' : candStr;
      debugPrint('[Cast] ICE 候选: $candShort');
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

    // 3. 开始监听 WS 消息（在发送 create_room 之前）
    debugPrint('[Cast] 步骤3: 开始监听 WS 消息');
    _wsSubscription = _ws.messages.listen(_handleMessage);

    // 4. 发送 create_room，等待 room_created 响应
    debugPrint('[Cast] 步骤4: 发送 create_room...');
    _roomCreatedCompleter = Completer<String>();

    final sent = _ws.send({
      'type': 'create_room',
      'payload': {
        'targetDeviceUuid': pcDeviceId,
        'type': 'cast',
      },
    });
    debugPrint('[Cast] 步骤4: create_room 发送${sent ? "成功" : "失败"}，等待 room_created...');

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

    debugPrint('[Cast] 步骤4: 收到 room_created, roomId=$roomId ✓');

    _currentSession = CastSession(
      roomId: roomId,
      pcDeviceId: pcDeviceId,
      status: 'connecting',
    );

    // 5. 等待 PC 加入房间 (peer_joined)
    debugPrint('[Cast] 步骤5: 等待 PC 加入房间 (peer_joined)...');
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
    debugPrint('[Cast] 步骤5: peer_joined ✓');

    // 6. 捕获屏幕
    debugPrint('[Cast] 步骤6: 开始屏幕捕获...');
    onStatusChanged?.call('capturing');
    final stream = await _webrtc.startScreenCapture();
    debugPrint('[Cast] 步骤6: 屏幕捕获完成, tracks=${stream.getTracks().length} ✓');

    // 7. 将屏幕轨道添加到 PeerConnection
    debugPrint('[Cast] 步骤7: 添加轨道到 PeerConnection...');
    await _webrtc.addStream(stream);
    debugPrint('[Cast] 步骤7: 轨道已添加 ✓');

    // 8. 创建 offer 并发送
    debugPrint('[Cast] 步骤8: 创建并发送 offer...');
    final offer = await _webrtc.createOffer();
    _ws.send({
      'type': 'signal',
      'roomId': roomId,
      'payload': {
        'signalType': 'offer',
        'sdp': offer.sdp,
      },
    });
    debugPrint('[Cast] 步骤8: offer 已发送 ✓');
    debugPrint('═══════════════════════════════════════════');

    return _currentSession!;
  }

  /// 结束投屏会话
  Future<void> endCastSession() async {
    debugPrint('[Cast] 结束投屏会话');
    _isDisposed = true;

    if (_currentSession != null) {
      _ws.send({
        'type': 'close_room',
        'roomId': _currentSession!.roomId,
      });
    }

    await _wsSubscription?.cancel();
    _wsSubscription = null;
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
    debugPrint('[Cast] 收到 WS 消息: type=$type');

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
        _onRoomClosed(message);
        break;
    }
  }

  // ---- 内部方法 ----

  /// 确保 WebSocket 已连接
  Future<void> _ensureWebSocketConnected() async {
    if (_ws.connectionState != WsConnectionState.connected) {
      await _ws.connect().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          'WebSocket 连接超时，请检查服务器是否在 http://localhost:3000 运行',
        ),
      );
    }
  }

  void _onRoomCreated(Map<String, dynamic> message) {
    final roomId = message['roomId'] as String?;
    debugPrint('[Cast] room_created: roomId=$roomId');
    if (roomId != null && _roomCreatedCompleter != null && !_roomCreatedCompleter!.isCompleted) {
      _roomCreatedCompleter!.complete(roomId);
    }
  }

  void _onPeerJoined(Map<String, dynamic> message) {
    debugPrint('[Cast] peer_joined');
    if (_peerJoinedCompleter != null && !_peerJoinedCompleter!.isCompleted) {
      _peerJoinedCompleter!.complete();
    }
  }

  void _onSignal(Map<String, dynamic> message) {
    final roomId = message['roomId'] as String?;
    if (roomId != _currentSession?.roomId) {
      debugPrint('[Cast] signal roomId 不匹配: $roomId != ${_currentSession?.roomId}');
      return;
    }

    final payload = message['payload'] as Map<String, dynamic>?;
    if (payload == null) return;

    final signalType = payload['signalType'] as String? ?? payload['type'] as String?;
    debugPrint('[Cast] signal: $signalType');

    switch (signalType) {
      case 'answer':
        _webrtc.handleAnswer(payload['sdp'] as String);
        _updateSessionStatus('connected');
        debugPrint('[Cast] 投屏连接已建立 ✓');
        break;
      case 'ice_candidate':
        _webrtc.handleIceCandidate(payload['candidate'] as Map<String, dynamic>);
        break;
    }
  }

  void _onRoomClosed(Map<String, dynamic> message) {
    debugPrint('[Cast] room_closed');
    _updateSessionStatus('disconnected');
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
    _webrtc.dispose();
  }
}
