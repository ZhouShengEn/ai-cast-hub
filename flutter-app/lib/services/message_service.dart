import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../models/chat_message.dart';
import 'websocket_service.dart';
import 'webrtc_service.dart';

/// 安全截取 ID 用于日志
String _safeId(String? id) {
  if (id == null || id.isEmpty) return '(空)';
  if (id.length <= 8) return id;
  return '${id.substring(0, 8)}...';
}

class MessageService {
  final WebSocketService _ws = WebSocketService.instance;
  final WebrtcService _webrtc = WebrtcService();

  StreamSubscription? _wsSub;
  String? _roomId;
  bool _connected = false;

  Completer<void>? _dcOpenCompleter;

  final StreamController<ChatMessage> _incomingCtl = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get onIncoming => _incomingCtl.stream;

  final StreamController<Map<String, dynamic>> _progressCtl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onProgress => _progressCtl.stream;

  /// 连接断开回调（通知 provider 更新状态）
  void Function()? onDisconnected;

  bool get isConnected => _connected;

  Future<void> connect(String pcDeviceId) async {
    if (_connected) return;
    debugPrint('[Msg] 连接消息通道...');

    if (_ws.connectionState != WsConnectionState.connected) {
      await _ws.connect().timeout(const Duration(seconds: 10), onTimeout: () {
        throw Exception('WebSocket 连接超时');
      });
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
      debugPrint('[Msg] DC 状态: $state');
      if (state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
        if (_dcOpenCompleter != null && !_dcOpenCompleter!.isCompleted) {
          _dcOpenCompleter!.complete();
        }
      } else if (state == webrtc.RTCDataChannelState.RTCDataChannelClosed) {
        debugPrint('[Msg] DC 已关闭，断开连接');
        _connected = false;
        _dcOpenCompleter = null;
        onDisconnected?.call();
      }
    };

    // 创建房间
    final roomCompleter = Completer<String>();
    _wsSub = _ws.messages.listen((msg) {
      final t = msg['type'] as String?;
      if (t == 'room_created' && !roomCompleter.isCompleted) {
        roomCompleter.complete(msg['roomId'] as String);
      }
    });

    _ws.send({
      'type': 'create_room',
      'payload': {'targetDeviceUuid': pcDeviceId, 'type': 'message'},
    });

    _roomId = await roomCompleter.future.timeout(const Duration(seconds: 15), onTimeout: () {
      throw Exception('房间创建超时，请确认 PC 端已打开消息页面');
    });

    // 等待 PC 加入房间 (peer_joined)
    debugPrint('[Msg] 等待 PC 加入房间 (peer_joined)...');
    await _wsSub?.cancel();
    final peerJoinedCompleter = Completer<void>();
    _wsSub = _ws.messages.listen((msg) {
      final t = msg['type'] as String?;
      if (t == 'peer_joined') {
        debugPrint('[Msg] peer_joined 收到 ✓');
        if (!peerJoinedCompleter.isCompleted) peerJoinedCompleter.complete();
      }
    });

    await peerJoinedCompleter.future.timeout(const Duration(seconds: 15), onTimeout: () {
      throw Exception('等待 PC 加入房间超时\n请确认 PC 端已打开消息页面');
    });

    // 创建并发送 offer
    debugPrint('[Msg] 创建并发送 offer...');
    final offer = await _webrtc.createOffer();
    _ws.send({
      'type': 'signal', 'roomId': _roomId!,
      'payload': {'signalType': 'offer', 'sdp': offer.sdp},
    });

    // 切换到正式消息监听
    await _wsSub?.cancel();
    _wsSub = _ws.messages.listen(_onMsg);

    // 等待 DataChannel 真正打开
    try {
      await _dcOpenCompleter!.future.timeout(const Duration(seconds: 15));
      _connected = true;
      debugPrint('[Msg] 通道已建立 (DC open)');
    } catch (e) {
      debugPrint('[Msg] DC open 超时: $e');
      final dc2 = _webrtc.dataChannel;
      if (dc2 != null && dc2.state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
        _connected = true;
        debugPrint('[Msg] DC 已打开，标记已连接');
      } else {
        _connected = true;
        debugPrint('[Msg] 标记已连接（DC 可能未完全打开，sendText 会重试）');
      }
    }
  }

  void _onMsg(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'signal':
        _onSignal(msg);
        break;
      case 'room_closed':
      case 'peer_disconnected':
        disconnect();
        break;
    }
  }

  void _onSignal(Map<String, dynamic> msg) {
    final p = msg['payload'] as Map<String, dynamic>? ?? {};
    final st = p['signalType'] as String? ?? p['type'];
    if (st == 'answer') _webrtc.handleAnswer(p['sdp'] as String);
    else if (st == 'ice_candidate') _webrtc.handleIceCandidate(p['candidate'] as Map<String, dynamic>);
  }

  void _onDC(webrtc.RTCDataChannelMessage msg) {
    if (msg.isBinary) {
      // 二进制消息 = 文件 chunk（新协议）
      _handleBinaryChunk(msg.binary);
      return;
    }
    try {
      final data = jsonDecode(msg.text) as Map<String, dynamic>;
      debugPrint('[Msg] DC 收到: ${data['type']}');
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
          debugPrint('[Msg RECV] file_start: id=${_safeId(data['id'])} file=${data['fileName']} chunks=${data['totalChunks']}');
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
        case 'read_all':
          debugPrint('[Msg] PC 端已读所有消息');
          _incomingCtl.add(ChatMessage(
            id: 'read_all_${DateTime.now().millisecondsSinceEpoch}', roomId: _roomId ?? '',
            type: MessageType.text, status: MessageStatus.sent,
            readStatus: ReadStatus.read, text: '', isFromMe: true,
            timestamp: DateTime.now(),
          ));
          break;
      }
    } catch (e) { debugPrint('[Msg] DC error: $e'); }
  }

  /// 解析二进制 chunk: [1b idLen][idLen b fileId][4b seq BE][4b total BE][data]
  void _handleBinaryChunk(Uint8List packet) {
    if (packet.length < 9) {
      debugPrint('[Msg RECV] 二进制包太小: ${packet.length}B');
      return;
    }

    final idLen = packet[0];
    final headerSize = 1 + idLen + 4 + 4;
    if (packet.length < headerSize) {
      debugPrint('[Msg RECV] 二进制包头不完整: packet=${packet.length} header=$headerSize idLen=$idLen');
      return;
    }

    final id = utf8.decode(packet.sublist(1, 1 + idLen));
    final header = ByteData.sublistView(packet);
    final seq = header.getUint32(1 + idLen, Endian.big);
    final total = header.getUint32(1 + idLen + 4, Endian.big);

    final chunkData = packet.sublist(headerSize);
    final meta = _fileMetas[id];

    if (meta == null) {
      debugPrint('[Msg RECV] ⚠ 收到未知文件 chunk: id=${_safeId(id)} seq=$seq/$total size=${chunkData.length}');
      return;
    }

    // 每 10 个 chunk 或首尾打日志
    if (seq == 0 || seq == total - 1 || seq % 10 == 0) {
      debugPrint('[Msg RECV] chunk $seq/$total size=${chunkData.length}B received=${meta['chunksReceived']}');
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
      debugPrint('[Msg] DC 未打开 (${dc.state})，等待...');
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
      debugPrint('[Msg] 文本已发送: $text');
      return msg.copyWith(status: MessageStatus.sent);
    } catch (e) {
      debugPrint('[Msg] 发送失败: $e');
      return msg.copyWith(status: MessageStatus.failed);
    }
  }

  /// 发送文件（流控：二进制 DataChannel + 动态流控）
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

    // 立即通知 UI：文件消息已创建，开始发送
    _progressCtl.add({
      'id': msg.id, 'progress': 0.0, 'start': true,
      'fileName': f.name, 'fileSize': f.size,
      'fileMimeType': _mime(f.name), 'isFromMe': true,
    });

    const cs = 16384; // 16KB per chunk
    final total = (bytes.length + cs - 1) ~/ cs; // 整数除法，避免浮点精度问题

    // 发送 file_start（JSON 文本）
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({
      'type': 'file_start', 'id': msg.id, 'fileName': f.name,
      'fileSize': f.size, 'totalChunks': total,
      'fileMimeType': _mime(f.name),
    })));

    // 预编码 file_id 为 UTF-8 字节（头信息复用）
    final idBytes = utf8.encode(msg.id);
    final idLen = idBytes.length;

    // 二进制流控发送每个 chunk
    debugPrint('[Msg SEND] 开始发送文件 $total 个chunk, 文件大小=${f.size}, DC状态=${dc.state}');
    for (int i = 0; i < total; i++) {
      // 动态等待 DataChannel 缓冲区释放（防止溢出断开）
      var retryCount = 0;
      int? ba = dc.bufferedAmount;
      while (ba != null && ba > cs * 8) {
        await Future.delayed(const Duration(milliseconds: 10));
        retryCount++;
        if (retryCount > 500) {
          debugPrint('[Msg SEND] 文件传输超时：DC 缓冲区持续满载 ba=$ba');
          _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total, 'failed': true});
          throw Exception('连接超时');
        }
        if (dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
          debugPrint('[Msg SEND] 文件传输中断：DC 状态变为 ${dc.state}');
          _progressCtl.add({'id': msg.id, 'progress': 0, 'failed': true});
          throw Exception('连接中断');
        }
        ba = dc.bufferedAmount;
      }

      final s = i * cs;
      if (s >= bytes.length) break; // 兜底：文件已发完
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
        // 每 10 个 chunk 或首尾打日志
        if (i == 0 || i == total - 1 || i % 10 == 0) {
          debugPrint('[Msg SEND] chunk $i/$total ba=${dc.bufferedAmount} size=${packet.length}');
        }
      } catch (sendErr) {
        debugPrint('[Msg SEND] 发送 chunk $i/$total 失败: $sendErr');
        _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total, 'failed': true});
        throw Exception('发送chunk失败: $sendErr');
      }
      _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total});

      // 每个 chunk 后短延迟，让缓冲区有时间排出
      await Future.delayed(const Duration(milliseconds: 5));
    }

    debugPrint('[Msg SEND] 所有chunk发送完毕，发送 file_end, id=${_safeId(msg.id)}');
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({'type': 'file_end', 'id': msg.id})));
    _progressCtl.add({'id': msg.id, 'progress': 1.0, 'sent': true});
    return msg.copyWith(status: MessageStatus.sent, progress: 1.0);
  }

  void cancelSend(String id) {
    final dc = _webrtc.dataChannel;
    if (dc != null) dc.send(webrtc.RTCDataChannelMessage(jsonEncode({'type': 'cancel', 'id': id})));
  }

  // ---- 接收文件（含自动下载触发） ----
  final Map<String, Map<String, dynamic>> _fileMetas = {};

  void _handleFileStart(Map<String, dynamic> d) {
    final id = d['id'] as String;
    final totalChunks = d['totalChunks'] as int;
    _fileMetas[id] = {
      'buffer': List<Uint8List?>.filled(totalChunks, null),
      'fileName': d['fileName'] as String? ?? 'file',
      'fileSize': d['fileSize'] as int,
      'totalChunks': totalChunks,
      'mimeType': d['fileMimeType'] as String? ?? 'application/octet-stream',
      'chunksReceived': 0,
    };
    _incomingCtl.add(ChatMessage(
      id: id, roomId: _roomId ?? '',
      type: MessageType.file, status: MessageStatus.receiving,
      fileName: d['fileName'] as String? ?? 'file',
      fileSize: d['fileSize'] as int,
      isFromMe: false, timestamp: DateTime.now(),
    ));
  }

  void _handleChunk(Map<String, dynamic> d) {
    final id = d['id'] as String;
    final meta = _fileMetas[id];
    if (meta == null) {
      debugPrint('[Msg RECV] ⚠ chunk 无对应 meta: id=${_safeId(id)}');
      return;
    }
    final buf = meta['buffer'] as List<Uint8List?>;
    final seq = d['seq'] as int;
    final total = d['total'] as int;
    buf[seq] = base64Decode(d['data'] as String);
    meta['chunksReceived'] = (meta['chunksReceived'] as int) + 1;

    final rcvd = meta['chunksReceived'] as int;
    if (seq % 10 == 0 || rcvd >= total) {
      debugPrint('[Msg RECV] chunk进度: $rcvd/$total');
    }

    // 检查是否全部接收完毕
    if (rcvd >= total) {
      debugPrint('[Msg RECV] ✅ 所有chunk收齐，组装文件 id=${_safeId(id)}');
      _assembleFile(id);
    }
  }

  void _handleFileEnd(Map<String, dynamic> d) {
    debugPrint('[Msg RECV] file_end: id=${_safeId(d['id'])}');
    // 兜底：如果 chunks 因某种原因未触发组装，file_end 确保完成
    _assembleFile(d['id'] as String);
  }

  /// 组装文件并触发下载
  void _assembleFile(String id) {
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

    debugPrint('[Msg RECV] 文件接收完成: $fileName (${merged.length} bytes)，触发下载');

    // 触发下载（Web 端浏览器下载 / 移动端保存到本地）
    // 注意：不通过 _incomingCtl 重复添加消息，_handleFileStart 已添加过；
    // message_provider 通过 onProgress 的 completed 事件将状态更新为 received
    _progressCtl.add({
      'id': id, 'progress': 1.0, 'completed': true,
      'bytes': merged, 'fileName': fileName, 'mimeType': meta['mimeType'],
    });
  }

  void _cancelReceive(String id) {
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
    _wsSub?.cancel();
    _webrtc.close();
    _roomId = null;
    _connected = false;
    _dcOpenCompleter = null;
    onDisconnected?.call();
    debugPrint('[Msg] 已断开');
  }

  void dispose() { disconnect(); _incomingCtl.close(); _progressCtl.close(); }
}
