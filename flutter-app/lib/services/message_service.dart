import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../models/chat_message.dart';
import 'websocket_service.dart';
import 'webrtc_service.dart';
import 'debug_service.dart';

/// 安全截取 ID 用于日志
String _safeId(String? id) {
  if (id == null || id.isEmpty) return '(空)';
  if (id.length <= 8) return id;
  return '${id.substring(0, 8)}...';
}

/// 消息服务日志（输出到 debugPrint + 悬浮球 console）
void _msgLog(String msg, {LogLevel level = LogLevel.debug}) {
  final text = '[Msg] $msg';
  debugPrint(text);
  DebugService().log(text, level: level);
}

/// 待发送文件（中断后保留以便续传）
class _PendingSend {
  final String id;
  final String fileName;
  final int fileSize;
  final String fileMimeType;
  final int totalChunks;
  final Uint8List bytes;
  Timer? timeoutTimer;
  _PendingSend({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.fileMimeType,
    required this.totalChunks,
    required this.bytes,
  });
}

class MessageService {
  final WebSocketService _ws = WebSocketService.instance;
  final WebrtcService _webrtc = WebrtcService();

  StreamSubscription? _wsSub;
  String? _roomId;
  bool _connected = false;

  /// 缓冲早到的 ICE 候选（remote description 设置前到达）
  final List<Map<String, dynamic>> _pendingIceCandidates = [];
  bool _remoteDescSet = false;

  Completer<void>? _dcOpenCompleter;

  /// 用于 connect() 流程中的异步等待（不再覆盖 _wsSub）
  Completer<String>? _roomCreatedCompleter;
  Completer<void>? _peerJoinedCompleter;

  final StreamController<ChatMessage> _incomingCtl = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get onIncoming => _incomingCtl.stream;

  final StreamController<Map<String, dynamic>> _progressCtl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onProgress => _progressCtl.stream;

  /// 连接断开回调（通知 provider 更新状态）
  void Function()? onDisconnected;

  /// 连接建立回调（PC端主动连接时通知UI）
  void Function()? onConnected;

  bool get isConnected => _connected;

  StreamSubscription? _wsStateSub;

  // ---- 断点续传：待发送文件缓存（中断后保留） ----
  final Map<String, _PendingSend> _pendingSends = {};

  // ---- 传输超时计时器（30 分钟） ----
  final Map<String, Timer> _fileTransferTimers = {};

  /// 传输超时：30 分钟
  static const Duration _transferTimeout = Duration(minutes: 30);

  /// resume_state 响应超时：10 秒
  static const Duration _resumeStateTimeout = Duration(seconds: 10);

  /// 启动监听（被动接收PC端连接邀请）
  Future<void> startListening() async {
    if (_ws.connectionState != WsConnectionState.connected) {
      await _ws.connect().timeout(const Duration(seconds: 10), onTimeout: () {
        _msgLog('WebSocket 连接超时，稍后重试');
        return;
      });
    }

    // 监听WebSocket连接状态变化，重连后自动重新注册监听
    if (_wsStateSub == null) {
      _wsStateSub = _ws.connectionStateStream.listen((state) {
        if (state == WsConnectionState.connected) {
          _msgLog('WebSocket重连成功，重新注册消息监听');
          if (_wsSub != null) {
            _wsSub?.cancel();
            _wsSub = null;
          }
          _wsSub = _ws.messages.listen(_onMsg);
          // 如果之前是连接状态，重连后尝试恢复连接
          if (_connected) {
            _msgLog('重连后尝试恢复消息连接');
            _connected = false;
            onDisconnected?.call();
          }
          // 检查是否有中断的文件传输需要恢复
          if (_pendingSends.isNotEmpty || _fileMetas.isNotEmpty) {
            _msgLog('检测到 ${_pendingSends.length + _fileMetas.length} 个中断的文件传输');
          }
        }
      });
    }

    if (_wsSub != null) return;

    _msgLog('启动消息通道监听（被动模式）');
    _wsSub = _ws.messages.listen(_onMsg);
  }

  Future<void> connect(String pcDeviceId) async {
    if (_connected) return;
    _msgLog('连接消息通道...', level: LogLevel.info);

    _pendingIceCandidates.clear();
    _remoteDescSet = false;

    if (_ws.connectionState != WsConnectionState.connected) {
      await _ws.connect().timeout(const Duration(seconds: 10), onTimeout: () {
        throw Exception('WebSocket 连接超时');
      });
    }

    // 确保 _wsSub 已设置（全局监听，不覆盖）
    if (_wsSub == null) {
      _wsSub = _ws.messages.listen(_onMsg);
    }

    await _webrtc.createPeerConnection({
      'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
    });

    _webrtc.onIceCandidate((c) {
      if (_roomId == null) return;
      _ws.send({
        'type': 'signal', 'roomId': _roomId!,
        'payload': {'signalType': 'ice_candidate', 'candidate': {
          'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex,
        }},
      });
    });

    _dcOpenCompleter = Completer<void>();
    final dc = await _webrtc.createDataChannel('message');
    dc.onMessage = (webrtc.RTCDataChannelMessage msg) => _onDC(msg);
    dc.onDataChannelState = (webrtc.RTCDataChannelState state) {
      _msgLog('DC 状态: $state');
      if (state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
        if (_dcOpenCompleter != null && !_dcOpenCompleter!.isCompleted) {
          _dcOpenCompleter!.complete();
        }
        // 重连后恢复中断的传输
        if (_pendingSends.isNotEmpty || _fileMetas.isNotEmpty) {
          _onReconnected();
        }
      } else if (state == webrtc.RTCDataChannelState.RTCDataChannelClosed) {
        _msgLog('DC 已关闭，断开连接');
        _connected = false;
        _dcOpenCompleter = null;
        onDisconnected?.call();
      }
    };

    // 创建房间（通过 _onMsg 收到 room_created 后完成 completer）
    _roomCreatedCompleter = Completer<String>();
    _ws.send({
      'type': 'create_room',
      'payload': {'targetDeviceUuid': pcDeviceId, 'type': 'message'},
    });

    _roomId = await _roomCreatedCompleter!.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _roomCreatedCompleter = null;
      throw Exception('房间创建超时，请确认 PC 端已打开消息页面');
    });
    _roomCreatedCompleter = null;

    // 等待 PC 加入房间 (peer_joined)（通过 _onMsg 收到 peer_joined 后完成 completer）
    _msgLog('等待 PC 加入房间 (peer_joined)...', level: LogLevel.info);
    _peerJoinedCompleter = Completer<void>();
    await _peerJoinedCompleter!.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _peerJoinedCompleter = null;
      throw Exception('等待 PC 加入房间超时\n请确认 PC 端已打开消息页面');
    });
    _peerJoinedCompleter = null;

    // 创建并发送 offer
    _msgLog('创建并发送 offer...');
    final offer = await _webrtc.createOffer();
    _ws.send({
      'type': 'signal', 'roomId': _roomId!,
      'payload': {'signalType': 'offer', 'sdp': offer.sdp},
    });

    // 等待 DataChannel 真正打开
    try {
      await _dcOpenCompleter!.future.timeout(const Duration(seconds: 15));
      _connected = true;
      _msgLog('通道已建立 (DC open)');
    } catch (e) {
      _msgLog('DC open 超时: $e');
      final dc2 = _webrtc.dataChannel;
      if (dc2 != null && dc2.state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
        _connected = true;
        _msgLog('DC 已打开，标记已连接');
      } else {
        _connected = true;
        _msgLog('标记已连接（DC 可能未完全打开，sendText 会重试）');
      }
    }
  }

  void _onMsg(Map<String, dynamic> msg) {
    final t = msg['type'] as String?;

    // 处理 connect() 流程中的异步等待（不覆盖 _wsSub）
    if (t == 'room_created') {
      if (_roomCreatedCompleter != null && !_roomCreatedCompleter!.isCompleted) {
        _roomCreatedCompleter!.complete(msg['roomId'] as String);
      }
      return;
    }
    if (t == 'peer_joined') {
      _msgLog('peer_joined 收到 ✓');
      if (_peerJoinedCompleter != null && !_peerJoinedCompleter!.isCompleted) {
        _peerJoinedCompleter!.complete();
      }
      return;
    }

    switch (t) {
      case 'signal':
        _onSignal(msg);
        break;
      case 'room_invitation':
        _onRoomInvitation(msg);
        break;
      case 'room_closed':
      case 'peer_disconnected':
        disconnect();
        break;
    }
  }

  /// 处理来自PC端的房间邀请
  void _onRoomInvitation(Map<String, dynamic> msg) {
    final roomId = msg['roomId'] as String?;
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};
    final roomType = payload['type'] as String?;
    final fromDeviceUuid = payload['fromDeviceUuid'] as String?;

    if (roomId == null || roomType != 'message') {
      _msgLog('忽略无效房间邀请: type=$roomType roomId=$roomId');
      return;
    }

    if (_connected) {
      _msgLog('已有活跃连接，忽略房间邀请');
      return;
    }

    _msgLog('收到PC端房间邀请: roomId=${_safeId(roomId)} from=${_safeId(fromDeviceUuid)}');
    _acceptRoomInvitation(roomId, fromDeviceUuid);
  }

  /// 接受房间邀请（PC端主动发起时，App端作为被动方）
  Future<void> _acceptRoomInvitation(String roomId, String? fromDeviceUuid) async {
    if (_connected) return;

    _pendingIceCandidates.clear();
    _remoteDescSet = false;

    try {
      await _webrtc.createPeerConnection({
        'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
      });

      _webrtc.onIceCandidate((c) {
        if (_roomId == null) return;
        _ws.send({
          'type': 'signal', 'roomId': _roomId!,
          'payload': {'signalType': 'ice_candidate', 'candidate': {
            'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex,
          }},
        });
      });

      _dcOpenCompleter = Completer<void>();
      final dc = await _webrtc.createDataChannel('message');
      dc.onMessage = (webrtc.RTCDataChannelMessage msg) => _onDC(msg);
      dc.onDataChannelState = (webrtc.RTCDataChannelState state) {
        _msgLog('DC 状态: $state');
        if (state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          if (_dcOpenCompleter != null && !_dcOpenCompleter!.isCompleted) {
            _dcOpenCompleter!.complete();
          }
          // 重连后恢复中断的传输
          if (_pendingSends.isNotEmpty || _fileMetas.isNotEmpty) {
            _onReconnected();
          }
        } else if (state == webrtc.RTCDataChannelState.RTCDataChannelClosed) {
          _msgLog('DC 已关闭，断开连接');
          _connected = false;
          _dcOpenCompleter = null;
          onDisconnected?.call();
        }
      };

      _roomId = roomId;

      _msgLog('发送 join_room 响应邀请');
      _ws.send({'type': 'join_room', 'roomId': roomId});

      // 确保 _wsSub 已设置（全局监听，不覆盖）
      if (_wsSub == null) {
        _wsSub = _ws.messages.listen(_onMsg);
      }

      try {
        await _dcOpenCompleter!.future.timeout(const Duration(seconds: 15));
        _connected = true;
        _msgLog('通道已建立 (DC open) - 响应PC邀请');
        onConnected?.call();
      } catch (e) {
        _msgLog('DC open 超时: $e');
        final dc2 = _webrtc.dataChannel;
        if (dc2 != null && dc2.state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          _connected = true;
          _msgLog('DC 已打开，标记已连接');
          onConnected?.call();
        } else {
          _connected = true;
          _msgLog('标记已连接（DC 可能未完全打开）');
          onConnected?.call();
        }
      }
    } catch (e) {
      _msgLog('接受房间邀请失败: $e');
    }
  }

  void _onSignal(Map<String, dynamic> msg) async {
    final p = msg['payload'] as Map<String, dynamic>? ?? {};
    final st = p['signalType'] as String? ?? p['type'];
    _msgLog('_onSignal: $st');

    if (st == 'offer') {
      // PC 端发来 offer（被动接受邀请流程）
      _msgLog('收到PC的offer，设置远程SDP并创建answer');
      try {
        final answer = await _webrtc.handleOffer(p['sdp'] as String);
        _remoteDescSet = true;
        if (_roomId != null) {
          _ws.send({
            'type': 'signal', 'roomId': _roomId!,
            'payload': {'signalType': 'answer', 'sdp': answer.sdp},
          });
        }
        _flushIceCandidates();
      } catch (e) {
        _msgLog('处理offer失败: $e');
      }
    } else if (st == 'answer') {
      // PC 端发来 answer（主动连接流程）
      _msgLog('收到PC的answer，设置远程SDP');
      try {
        await _webrtc.handleAnswer(p['sdp'] as String);
        _remoteDescSet = true;
        _flushIceCandidates();
      } catch (e) {
        _msgLog('处理answer失败: $e');
      }
    } else if (st == 'ice_candidate') {
      if (_remoteDescSet) {
        try {
          await _webrtc.handleIceCandidate(p['candidate'] as Map<String, dynamic>);
        } catch (e) {
          _msgLog('ICE候选添加失败（非致命）: $e');
        }
      } else {
        _msgLog('缓冲ICE候选（remote description未设置）');
        _pendingIceCandidates.add(p['candidate'] as Map<String, dynamic>);
      }
    }
  }

  /// 刷新缓冲的 ICE 候选（在 setRemoteDescription 后调用）
  void _flushIceCandidates() {
    if (_pendingIceCandidates.isEmpty) return;
    _msgLog('刷新${_pendingIceCandidates.length}个缓冲的ICE候选');
    for (final c in _pendingIceCandidates) {
      try {
        _webrtc.handleIceCandidate(c);
      } catch (e) {
        _msgLog('缓冲ICE候选添加失败: $e');
      }
    }
    _pendingIceCandidates.clear();
  }

  void _onDC(webrtc.RTCDataChannelMessage msg) {
    if (msg.isBinary) {
      // 二进制消息 = 文件 chunk（新协议）
      _handleBinaryChunk(msg.binary);
      return;
    }
    try {
      final data = jsonDecode(msg.text) as Map<String, dynamic>;
      _msgLog('DC 收到: ${data['type']}');
      switch (data['type']) {
        case 'text':
          _incomingCtl.add(ChatMessage(
            id: data['id'] as String, roomId: _roomId ?? '', type: MessageType.text,
            status: MessageStatus.received, text: data['text'] as String, isFromMe: false,
            readStatus: ReadStatus.unread,
            timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
          ));
          break;
        case 'file_start':
          _msgLog('RECV file_start: id=${_safeId(data['id'])} file=${data['fileName']} chunks=${data['totalChunks']}');
          _handleFileStart(data);
          break;
        case 'file_chunk':
          // 兼容旧协议（JSON/base64），新协议用二进制通道
          _handleChunk(data);
          break;
        case 'file_end':
          _handleFileEnd(data);
          break;
        case 'cancel':
          _cancelReceive(data['id'] as String);
          break;
        case 'resume_state':
          _handleResumeState(data);
          break;
        case 'read_all':
          _msgLog('PC 端已读所有消息');
          _incomingCtl.add(ChatMessage(
            id: 'read_all_${DateTime.now().millisecondsSinceEpoch}', roomId: _roomId ?? '',
            type: MessageType.text, status: MessageStatus.sent,
            readStatus: ReadStatus.read, text: '', isFromMe: true,
            timestamp: DateTime.now(),
          ));
          break;
      }
    } catch (e) { _msgLog('DC error: $e'); }
  }

  /// 解析二进制 chunk: [1b idLen][idLen b fileId][4b seq BE][4b total BE][data]
  void _handleBinaryChunk(Uint8List packet) {
    if (packet.length < 9) {
      _msgLog('RECV 二进制包太小: ${packet.length}B');
      return;
    }

    final idLen = packet[0];
    final headerSize = 1 + idLen + 4 + 4;
    if (packet.length < headerSize) {
      _msgLog('RECV 二进制包头不完整: packet=${packet.length} header=$headerSize idLen=$idLen');
      return;
    }

    final id = utf8.decode(packet.sublist(1, 1 + idLen));
    final header = ByteData.sublistView(packet);
    final seq = header.getUint32(1 + idLen, Endian.big);
    final total = header.getUint32(1 + idLen + 4, Endian.big);

    final chunkData = packet.sublist(headerSize);
    final meta = _fileMetas[id];

    if (meta == null) {
      _msgLog('RECV ⚠ 收到未知文件 chunk: id=${_safeId(id)} seq=$seq/$total size=${chunkData.length}');
      return;
    }

    // 每 10 个 chunk 或首尾打日志
    if (seq == 0 || seq == total - 1 || seq % 10 == 0) {
      _msgLog('RECV chunk $seq/$total size=${chunkData.length}B received=${meta['chunksReceived']}');
    }

    _handleChunk({
      'id': id, 'seq': seq, 'total': total,
      'data': base64Encode(chunkData),
    });
  }

  // ---- 发送（Text + File，带流控） ----

  Future<ChatMessage> sendText(String text) async {
    final msg = ChatMessage(
      id: 'm_${DateTime.now().millisecondsSinceEpoch}', roomId: _roomId ?? '',
      type: MessageType.text, status: MessageStatus.sending,
      text: text, timestamp: DateTime.now(),
    );
    final dc = _webrtc.dataChannel;
    if (dc == null) return msg.copyWith(status: MessageStatus.failed);

    if (dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      _msgLog('DC 未打开 (${dc.state})，等待...');
      if (_dcOpenCompleter == null || _dcOpenCompleter!.isCompleted) {
        _dcOpenCompleter = Completer<void>();
      }
      try {
        await _dcOpenCompleter!.future.timeout(const Duration(seconds: 5));
        if (_webrtc.dataChannel?.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          return msg.copyWith(status: MessageStatus.failed);
        }
      } catch (_) {
        return msg.copyWith(status: MessageStatus.failed);
      }
    }
    try {
      final sendDc = _webrtc.dataChannel;
      if (sendDc == null || sendDc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
        return msg.copyWith(status: MessageStatus.failed);
      }
      sendDc.send(webrtc.RTCDataChannelMessage(jsonEncode({
        'type': 'text', 'id': msg.id, 'text': text,
        'timestamp': msg.timestamp.millisecondsSinceEpoch,
      })));
      _msgLog('文本已发送: $text');
      return msg.copyWith(status: MessageStatus.sent);
    } catch (e) {
      _msgLog('发送失败: $e');
      return msg.copyWith(status: MessageStatus.failed);
    }
  }

  /// 发送文件（流控：二进制 DataChannel + 动态流控）
  /// 支持断点续传：中断后保留文件数据，重连后可恢复
  Future<ChatMessage?> sendFile() async {
    final pick = await FilePicker.platform.pickFiles(allowMultiple: false, withData: true);
    if (pick == null || pick.files.isEmpty) return null;
    final f = pick.files.first;
    final bytes = f.bytes;
    if (bytes == null) throw Exception('无法读取文件');

    final dc = _webrtc.dataChannel;
    if (dc == null || dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      throw Exception('未连接');
    }

    final msg = ChatMessage(
      id: 'f_${DateTime.now().millisecondsSinceEpoch}', roomId: _roomId ?? '',
      type: MessageType.file, status: MessageStatus.sending,
      fileName: f.name, fileSize: f.size,
      fileMimeType: _mime(f.name), timestamp: DateTime.now(),
    );

    const cs = 16384; // 16KB per chunk
    final total = (bytes.length + cs - 1) ~/ cs;

    // 创建待发送记录（用于断点续传）
    _pendingSends[msg.id] = _PendingSend(
      id: msg.id, fileName: f.name, fileSize: f.size,
      fileMimeType: _mime(f.name), totalChunks: total, bytes: bytes,
    );
    _startFileTimer(msg.id);

    // 立即通知 UI：文件消息已创建，开始发送
    _progressCtl.add({
      'id': msg.id, 'progress': 0.0, 'start': true,
      'fileName': f.name, 'fileSize': f.size,
      'fileMimeType': _mime(f.name), 'isFromMe': true,
    });

    return _startSendingFile(msg, bytes, total, dc);
  }

  /// 执行文件发送（chunk 循环）
  Future<ChatMessage> _startSendingFile(
    ChatMessage msg, Uint8List bytes, int total, webrtc.RTCDataChannel dc,
  ) async {
    const cs = 16384;

    // 发送 file_start（JSON 文本）
    // 如果是续传，加 resume 标记
    final alreadySent = _getReceivedCount(msg.id);
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({
      'type': 'file_start', 'id': msg.id, 'fileName': msg.fileName,
      'fileSize': msg.fileSize, 'totalChunks': total,
      'fileMimeType': msg.fileMimeType,
      if (alreadySent > 0) 'resume': true,
    })));

    // 预编码 file_id 为 UTF-8 字节（头信息复用）
    final idBytes = utf8.encode(msg.id);
    final idLen = idBytes.length;

    // 二进制流控发送每个 chunk
    _msgLog('SEND 开始发送文件 $total 个chunk, 文件大小=${msg.fileSize}, DC状态=${dc.state}');
    for (int i = 0; i < total; i++) {
      // 动态等待 DataChannel 缓冲区释放（防止溢出断开）
      var retryCount = 0;
      int? ba = dc.bufferedAmount;
      while (ba != null && ba > cs * 8) {
        await Future.delayed(const Duration(milliseconds: 10));
        retryCount++;
        if (retryCount > 500) {
          _msgLog('SEND 文件传输超时：DC 缓冲区持续满载 ba=$ba');
          _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total, 'interrupted': true});
          throw Exception('连接超时');
        }
        if (dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          _msgLog('SEND 文件传输中断：DC 状态变为 ${dc.state}');
          _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total, 'interrupted': true});
          throw Exception('连接中断');
        }
        ba = dc.bufferedAmount;
      }

      final s = i * cs;
      if (s >= bytes.length) break;
      final e = (s + cs).clamp(0, bytes.length);
      final chunkData = bytes.sublist(s, e);

      // 构造二进制头: [1b idLen][idLen b fileId][4b seq BE][4b total BE][data]
      final header = ByteData(1 + idLen + 4 + 4);
      header.setUint8(0, idLen);
      for (int j = 0; j < idLen; j++) { header.setUint8(1 + j, idBytes[j]); }
      header.setUint32(1 + idLen, i, Endian.big);
      header.setUint32(1 + idLen + 4, total, Endian.big);

      final packet = Uint8List(header.lengthInBytes + chunkData.length);
      packet.setRange(0, header.lengthInBytes, header.buffer.asUint8List(0, header.lengthInBytes));
      packet.setRange(header.lengthInBytes, header.lengthInBytes + chunkData.length, chunkData);

      try {
        dc.send(webrtc.RTCDataChannelMessage.fromBinary(packet));
        if (i == 0 || i == total - 1 || i % 10 == 0) {
          _msgLog('SEND chunk $i/$total ba=${dc.bufferedAmount} size=${packet.length}');
        }
      } catch (sendErr) {
        _msgLog('SEND 发送 chunk $i/$total 失败: $sendErr');
        _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total, 'interrupted': true});
        throw Exception('发送chunk失败: $sendErr');
      }
      _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total});

      await Future.delayed(const Duration(milliseconds: 5));
    }

    _msgLog('SEND 所有chunk发送完毕，发送 file_end, id=${_safeId(msg.id)}');
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({'type': 'file_end', 'id': msg.id})));
    _progressCtl.add({'id': msg.id, 'progress': 1.0, 'sent': true});

    // 发送成功，清理待发送记录
    _cancelFileTimer(msg.id);
    _pendingSends.remove(msg.id);

    return msg.copyWith(status: MessageStatus.sent, progress: 1.0);
  }

  /// 获取接收端已确认的分片数（通过 _fileMetas 查询——仅限本地也缓存了的情况）
  /// 实际由 resume_state 协议提供准确数据
  int _getReceivedCount(String fileId) {
    // 返回 0 表示全新发送；续传时由 resume_state 确定跳过哪些 chunk
    return 0;
  }

  /// 按已接收列表续传文件
  Future<void> _resumeSendFile(String fileId, List<int> receivedChunks) async {
    final pending = _pendingSends[fileId];
    if (pending == null) {
      _msgLog('SEND ⚠ 续传请求但无待发送数据: id=${_safeId(fileId)}');
      return;
    }

    final dc = _webrtc.dataChannel;
    if (dc == null || dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      _msgLog('SEND ⚠ 续传失败：DC 未就绪');
      return;
    }

    final receivedSet = receivedChunks.toSet();
    _msgLog('SEND 续传文件: ${pending.fileName}, 已收 ${receivedChunks.length}/${pending.totalChunks}, 需发 ${pending.totalChunks - receivedChunks.length} 个chunk');

    _progressCtl.add({
      'id': fileId, 'progress': receivedChunks.length / pending.totalChunks, 'resumed': true,
      'fileName': pending.fileName, 'fileSize': pending.fileSize,
    });

    // 发送 file_start（带 resume 标记）
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({
      'type': 'file_start', 'id': fileId, 'fileName': pending.fileName,
      'fileSize': pending.fileSize, 'totalChunks': pending.totalChunks,
      'fileMimeType': pending.fileMimeType, 'resume': true,
    })));

    final idBytes = utf8.encode(fileId);
    final idLen = idBytes.length;
    const cs = 16384;

    int sentCount = receivedChunks.length;
    for (int i = 0; i < pending.totalChunks; i++) {
      if (receivedSet.contains(i)) continue; // 跳过已收到的

      // 流控等待
      var retryCount = 0;
      int? ba = dc.bufferedAmount;
      while (ba != null && ba > cs * 8) {
        await Future.delayed(const Duration(milliseconds: 10));
        retryCount++;
        if (retryCount > 500 || dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          _msgLog('SEND 续传中断 at chunk $i');
          _progressCtl.add({'id': fileId, 'progress': sentCount / pending.totalChunks, 'interrupted': true});
          return;
        }
        ba = dc.bufferedAmount;
      }

      final s = i * cs;
      final e = (s + cs).clamp(0, pending.bytes.length);
      final chunkData = pending.bytes.sublist(s, e);

      final header = ByteData(1 + idLen + 4 + 4);
      header.setUint8(0, idLen);
      for (int j = 0; j < idLen; j++) { header.setUint8(1 + j, idBytes[j]); }
      header.setUint32(1 + idLen, i, Endian.big);
      header.setUint32(1 + idLen + 4, pending.totalChunks, Endian.big);

      final packet = Uint8List(header.lengthInBytes + chunkData.length);
      packet.setRange(0, header.lengthInBytes, header.buffer.asUint8List(0, header.lengthInBytes));
      packet.setRange(header.lengthInBytes, header.lengthInBytes + chunkData.length, chunkData);

      try {
        dc.send(webrtc.RTCDataChannelMessage.fromBinary(packet));
        sentCount++;
        if (i == 0 || i == pending.totalChunks - 1 || i % 10 == 0) {
          _msgLog('SEND resume chunk $i/${pending.totalChunks} ba=${dc.bufferedAmount}');
        }
      } catch (sendErr) {
        _msgLog('SEND 续传chunk $i 失败: $sendErr');
        _progressCtl.add({'id': fileId, 'progress': sentCount / pending.totalChunks, 'interrupted': true});
        return;
      }
      _progressCtl.add({'id': fileId, 'progress': sentCount / pending.totalChunks});

      await Future.delayed(const Duration(milliseconds: 5));
    }

    _msgLog('SEND 续传完成，发送 file_end, id=${_safeId(fileId)}');
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({'type': 'file_end', 'id': fileId})));
    _progressCtl.add({'id': fileId, 'progress': 1.0, 'sent': true});

    _cancelFileTimer(fileId);
    _pendingSends.remove(fileId);
  }

  void cancelSend(String id) {
    final dc = _webrtc.dataChannel;
    if (dc != null) dc.send(webrtc.RTCDataChannelMessage(jsonEncode({'type': 'cancel', 'id': id})));
  }

  void sendReadAll() {
    final dc = _webrtc.dataChannel;
    if (dc != null && dc.state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      dc.send(webrtc.RTCDataChannelMessage(jsonEncode({
        'type': 'read_all',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      })));
      _msgLog('发送 read_all 给 PC');
    }
  }

  // ---- 接收文件（含自动下载触发） ----
  final Map<String, Map<String, dynamic>> _fileMetas = {};

  void _handleFileStart(Map<String, dynamic> d) {
    final id = d['id'] as String;
    final totalChunks = d['totalChunks'] as int;
    final isResume = d['resume'] == true;

    // 如果是续传且已有缓冲，复用现有缓冲
    if (isResume && _fileMetas.containsKey(id)) {
      final existing = _fileMetas[id]!;
      final existingBuf = existing['buffer'] as List<Uint8List?>;
      if (existingBuf.length < totalChunks) {
        final newBuf = List<Uint8List?>.filled(totalChunks, null);
        for (int i = 0; i < existingBuf.length; i++) {
          newBuf[i] = existingBuf[i];
        }
        existing['buffer'] = newBuf;
      }
      existing['totalChunks'] = totalChunks;
      _msgLog('RECV 续传: id=${_safeId(id)} 保留 ${existing['chunksReceived']} 个已有分片');
      _progressCtl.add({
        'id': id, 'progress': (existing['chunksReceived'] as int) / totalChunks, 'resumed': true,
      });
      _startFileTimer(id);
      return;
    }

    _fileMetas[id] = {
      'buffer': List<Uint8List?>.filled(totalChunks, null),
      'fileName': d['fileName'] as String? ?? 'file',
      'fileSize': d['fileSize'] as int,
      'totalChunks': totalChunks,
      'mimeType': d['fileMimeType'] as String? ?? 'application/octet-stream',
      'chunksReceived': 0,
    };
    _startFileTimer(id);
    _incomingCtl.add(ChatMessage(
      id: id, roomId: _roomId ?? '',
      type: MessageType.file, status: MessageStatus.receiving,
      fileName: d['fileName'] as String? ?? 'file',
      fileSize: d['fileSize'] as int,
      isFromMe: false, timestamp: DateTime.now(),
    ));
    _progressCtl.add({
      'id': id, 'progress': 0.0, 'start': true,
      'fileName': d['fileName'] as String?,
      'fileSize': d['fileSize'] as int,
      'fileMimeType': d['fileMimeType'] as String?,
      'isFromMe': false,
    });
  }

  void _handleChunk(Map<String, dynamic> d) {
    final id = d['id'] as String;
    final meta = _fileMetas[id];
    if (meta == null) {
      _msgLog('RECV ⚠ chunk 无对应 meta: id=${_safeId(id)}');
      return;
    }
    final buf = meta['buffer'] as List<Uint8List?>;
    final seq = d['seq'] as int;
    final total = d['total'] as int;
    // 跳过已接收的分片（用于断点续传去重）
    if (buf[seq] != null) {
      return;
    }
    buf[seq] = base64Decode(d['data'] as String);
    meta['chunksReceived'] = (meta['chunksReceived'] as int) + 1;

    // 活动重置超时
    _startFileTimer(id);

    final rcvd = meta['chunksReceived'] as int;
    if (seq % 10 == 0 || rcvd >= total) {
      _msgLog('RECV chunk进度: $rcvd/$total');
    }

    // 通知进度更新
    final progress = rcvd / total;
    _progressCtl.add({'id': id, 'progress': progress});

    // 检查是否全部接收完毕
    if (rcvd >= total) {
      _msgLog('RECV ✅ 所有chunk收齐，组装文件 id=${_safeId(id)}');
      _assembleFile(id);
    }
  }

  void _handleFileEnd(Map<String, dynamic> d) {
    _msgLog('RECV file_end: id=${_safeId(d['id'])}');
    // 兜底：如果 chunks 因某种原因未触发组装，file_end 确保完成
    _assembleFile(d['id'] as String);
  }

  /// 组装文件并触发下载
  void _assembleFile(String id) {
    _cancelFileTimer(id);
    final meta = _fileMetas.remove(id);
    if (meta == null) return;
    final buf = meta['buffer'] as List<Uint8List?>;
    final fileName = meta['fileName'] as String;

    int totalBytes = 0;
    for (final c in buf) {
      if (c != null) totalBytes += c.length;
    }
    if (totalBytes == 0) return;

    final merged = Uint8List(totalBytes);
    int off = 0;
    for (final c in buf) {
      if (c != null) {
        merged.setRange(off, off + c.length, c);
        off += c.length;
      }
    }

    _msgLog('RECV 文件接收完成: $fileName (${merged.length} bytes)，触发下载');

    // 触发下载（Web 端浏览器下载 / 移动端保存到本地）
    // 注意：不通过 _incomingCtl 重复添加消息，_handleFileStart 已添加过；
    // message_provider 通过 onProgress 的 completed 事件将状态更新为 received
    _progressCtl.add({
      'id': id, 'progress': 1.0, 'completed': true,
      'bytes': merged, 'fileName': fileName, 'mimeType': meta['mimeType'],
    });
  }

  // ---- 断点续传：resume_state 协议 ----

  /// 发送 resume_state：告知发送方我已收到哪些分片
  void _sendResumeState(String fileId) {
    final meta = _fileMetas[fileId];
    if (meta == null) return;
    final buf = meta['buffer'] as List<Uint8List?>;
    final receivedChunks = <int>[];
    for (int i = 0; i < buf.length; i++) {
      if (buf[i] != null) receivedChunks.add(i);
    }
    final dc = _webrtc.dataChannel;
    if (dc == null || dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) return;

    _msgLog('RECV 发送 resume_state: id=${_safeId(fileId)} received=${receivedChunks.length}/${buf.length}');
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({
      'type': 'resume_state', 'id': fileId, 'receivedChunks': receivedChunks,
    })));
  }

  /// 处理 resume_state：接收方告知我已收到哪些分片
  void _handleResumeState(Map<String, dynamic> data) {
    final id = data['id'] as String;
    final receivedChunks = (data['receivedChunks'] as List).map((e) => e as int).toList();
    _msgLog('SEND 收到 resume_state: id=${_safeId(id)} received=${receivedChunks.length}');
    _cancelFileTimer(id); // 收到响应，停止等待超时
    _resumeSendFile(id, receivedChunks);
  }

  /// 重连后恢复所有中断的传输
  void _onReconnected() {
    _msgLog('重连后检查中断的传输...');
    int resumed = 0;

    // 对于接收中的文件：发送 resume_state 请求续传
    for (final entry in _fileMetas.entries) {
      final id = entry.key;
      _sendResumeState(id);
      _startFileTimer(id);
      resumed++;
    }

    // 对于发送中的文件：等待接收方发来 resume_state
    for (final entry in _pendingSends.entries) {
      final id = entry.key;
      _startFileTimer(id);
      // 设置 10 秒超时：如果收不到 resume_state，从头发送
      Future.delayed(_resumeStateTimeout, () {
        if (_pendingSends.containsKey(id) && _webrtc.dataChannel?.state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          _msgLog('SEND resume_state 响应超时，从头发送: id=${_safeId(id)}');
          final pending = _pendingSends[id]!;
          final dc = _webrtc.dataChannel!;
          _startSendingFile(
            ChatMessage(
              id: id, roomId: _roomId ?? '', type: MessageType.file,
              status: MessageStatus.sending, fileName: pending.fileName,
              fileSize: pending.fileSize, fileMimeType: pending.fileMimeType,
              timestamp: DateTime.now(),
            ),
            pending.bytes, pending.totalChunks, dc,
          );
        }
      });
      resumed++;
    }

    _msgLog('重连检查完成: $resumed 个传输待恢复');
  }

  // ---- 超时管理 ----

  /// 启动传输超时计时器
  void _startFileTimer(String fileId) {
    _cancelFileTimer(fileId);
    _fileTransferTimers[fileId] = Timer(_transferTimeout, () {
      _msgLog('传输超时: ${_safeId(fileId)}');
      _pendingSends.remove(fileId);
      _fileMetas.remove(fileId);
      _fileTransferTimers.remove(fileId);
    });
  }

  /// 取消传输超时计时器
  void _cancelFileTimer(String fileId) {
    _fileTransferTimers[fileId]?.cancel();
    _fileTransferTimers.remove(fileId);
  }

  void _cancelReceive(String id) {
    _cancelFileTimer(id);
    _pendingSends.remove(id);
    _fileMetas.remove(id);
    _incomingCtl.add(ChatMessage(
      id: id, roomId: _roomId ?? '', type: MessageType.file,
      status: MessageStatus.cancelled, fileName: '', isFromMe: false,
      timestamp: DateTime.now(),
    ));
  }

  String _mime(String n) {
    const m = {
      'pdf': 'application/pdf', 'png': 'image/png', 'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg', 'zip': 'application/zip', 'mp4': 'video/mp4',
      'txt': 'text/plain', 'json': 'application/json', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    };
    return m[n.split('.').last.toLowerCase()] ?? 'application/octet-stream';
  }

  void disconnect() {
    if (_roomId != null) _ws.send({'type': 'close_room', 'roomId': _roomId!});
    // 取消未完成的 completer
    if (_roomCreatedCompleter != null && !_roomCreatedCompleter!.isCompleted) {
      _roomCreatedCompleter!.completeError('连接已断开');
    }
    _roomCreatedCompleter = null;
    if (_peerJoinedCompleter != null && !_peerJoinedCompleter!.isCompleted) {
      _peerJoinedCompleter!.completeError('连接已断开');
    }
    _peerJoinedCompleter = null;
    _wsSub?.cancel();
    _wsSub = null;
    _wsStateSub?.cancel();
    _wsStateSub = null;
    _webrtc.close();
    _roomId = null;
    _connected = false;
    _dcOpenCompleter = null;
    _pendingIceCandidates.clear();
    _remoteDescSet = false;
    // 注意：不清理 _fileMetas、_pendingSends、_fileTransferTimers
    // 这些数据保留以便重连后断点续传
    onDisconnected?.call();
    _msgLog('已断开（保留文件传输状态以便续传）');
  }

  void dispose() {
    disconnect();
    // 清理所有文件传输状态
    for (final timer in _fileTransferTimers.values) {
      timer.cancel();
    }
    _fileTransferTimers.clear();
    _pendingSends.clear();
    _fileMetas.clear();
    _incomingCtl.close();
    _progressCtl.close();
  }
}
