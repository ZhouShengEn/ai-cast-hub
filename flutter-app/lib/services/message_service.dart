import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../models/chat_message.dart';
import '../utils/partial_file.dart';
import 'api_client.dart';
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

/// 速率采样点：某一时刻的累计字节数
class _RatePoint {
  final DateTime at;
  final int bytes;
  _RatePoint(this.at, this.bytes);
}

/// 消息服务（全局单例）
///
/// 必须是单例：消息通道要与 UI 解耦、常驻后台，
/// 若每个页面 new 一个实例，各自的 WS 监听会重复处理同一条 room_invitation，
/// 出现「两个 PeerConnection 抢同一个房间」的诡异故障。
class MessageService {
  static final MessageService _instance = MessageService._internal();

  factory MessageService() => _instance;

  MessageService._internal();

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

  // ---- 已取消的传输：取消后仍可能收到在途分片，必须丢弃而不是重建会话 ----
  final Set<String> _cancelledTransfers = {};

  // ---- 传输超时计时器（30 分钟） ----
  final Map<String, Timer> _fileTransferTimers = {};

  /// 传输超时：30 分钟
  static const Duration _transferTimeout = Duration(minutes: 30);

  /// resume_state 响应超时：10 秒
  static const Duration _resumeStateTimeout = Duration(seconds: 10);

  /// 分片大小 64KB（必须与 Web 端 CHUNK_SIZE 一致，否则分片会错位）。
  ///
  /// 原来是 16KB 且每片强制 sleep(5ms) —— 16KB/5ms 把吞吐硬锁在 ~3.2MB/s。
  /// 保留旧的「二进制包 + file_start/file_end」协议（无 base64 开销），
  /// 只放大分片并去掉固定休眠，速度可提升一个数量级。
  static const int _chunkSize = 64 * 1024;

  /// 发送缓冲水位上限（2MB）：只有超过才等待，不再每片固定休眠
  static const int _backlogLimit = 2 * 1024 * 1024;

  /// 速率采样间隔
  static const Duration _speedSampleInterval = Duration(milliseconds: 300);

  /// 启动监听（被动接收PC端连接邀请）
  ///
  /// 幂等：可重复调用；App 启动后即调用，令消息通道常驻后台，
  /// 使 Web 端在 App 处于首页 / 后台时也能主动建立消息连接（P1-5）。
  Future<void> startListening() async {
    if (_ws.connectionState != WsConnectionState.connected) {
      await _ws.connect().timeout(const Duration(seconds: 10), onTimeout: () {
        _msgLog('WebSocket 连接超时，稍后重试');
        return;
      });
    }

    // 注册全局 WS 监听（幂等，重复调用不会叠加）
    _ensureWsListening();

    // 监听 WebSocket 连接状态变化：WS 重连后自动恢复消息监听与通道（异常断开自动重连）
    if (_wsStateSub == null) {
      _wsStateSub = _ws.connectionStateStream.listen((state) {
        if (state == WsConnectionState.connected) {
          _msgLog('WebSocket重连成功，重新注册消息监听');
          _ensureWsListening();
          // 如果之前是连接状态，重连后尝试恢复连接
          if (_connected) {
            _msgLog('重连后尝试恢复消息连接');
            _connected = false;
            onDisconnected?.call();
          }
          // 检查是否有中断的文件传输需要恢复
          if (_pendingSends.isNotEmpty || _fileMetas.isNotEmpty) {
            _msgLog('检测到 ${_pendingSends.length + _fileMetas.length} 个中断的文件传输');
            _onReconnected();
          }
        }
      });
    }

    _msgLog('消息通道监听已就绪（后台常驻，不依赖消息页）', level: LogLevel.info);
  }

  /// 确保已订阅全局 WS 消息（幂等）
  void _ensureWsListening() {
    if (_wsSub != null) return;
    _wsSub = _ws.messages.listen(_onMsg);
  }

  /// 从服务器获取 ICE 配置（STUN/TURN）
  ///
  /// 消息通道此前硬编码单个 Google STUN，跨 NAT / 对称型网络下经常协商失败，
  /// 表现为「Web 端主动连接一直转圈」。改用服务端下发的 TURN 配置可显著提升成功率。
  Future<List<Map<String, dynamic>>> _fetchIceServers() async {
    try {
      final data = await ApiClient.instance.get('/webrtc/config');
      if (data is Map<String, dynamic> && data.containsKey('iceServers')) {
        final servers = data['iceServers'] as List<dynamic>;
        _msgLog('已从服务器获取 ICE 配置: ${servers.length} 个');
        return servers.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      _msgLog('获取 ICE 配置失败，使用默认 STUN: $e', level: LogLevel.warn);
    }
    return [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      },
    ];
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
      'iceServers': await _fetchIceServers(),
      'sdpSemantics': 'unified-plan',
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
        // 超时且 DC 未真正打开：绝不能谎报已连接，否则会陷入「假连接」永久不可用。
        // 显式置 false 并抛出，交由上层重试 / 提示失败。
        _connected = false;
        _msgLog('DC 未在超时内打开，连接失败');
        throw Exception('DataChannel 未在超时内打开: $e');
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
      case 'message_connect_request':
        _onMessageConnectRequest(msg);
        break;
      case 'room_closed':
      case 'peer_disconnected':
        disconnect();
        break;
    }
  }

  /// 处理 Web 端「主动连接消息」指令（P1-5）
  ///
  /// Web 端点击按钮后，服务端除 room_invitation 外还会下发本指令。
  /// App 端只需确认后台消息监听已就绪并回执，无需进入消息页面。
  void _onMessageConnectRequest(Map<String, dynamic> msg) {
    final from = (msg['payload'] as Map<String, dynamic>?)?['fromDeviceUuid'] as String?;
    final roomId = msg['roomId'] as String?;
    _msgLog('收到消息连接指令: room=${_safeId(roomId)} from=${_safeId(from)}',
        level: LogLevel.info);

    // 确保后台监听已注册（App 冷启动时可能尚未注册）
    _ensureWsListening();

    // 回执：告知 Web 端 App 端消息通道可用
    _ws.send({
      'type': 'message_connect_ack',
      'roomId': roomId,
      'targetDeviceUuid': from,
      'payload': {
        'targetDeviceUuid': from,
        'roomId': roomId,
        'ready': true,
        'alreadyConnected': _connected,
      },
    });
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
        'iceServers': await _fetchIceServers(),
        'sdpSemantics': 'unified-plan',
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

      // 监听远端创建的DataChannel（PC端会创建message通道）
      _dcOpenCompleter = Completer<void>();
      _webrtc.onRemoteDataChannel.listen((channel) {
        _msgLog('收到远端DataChannel: ${channel.label}，设置监听');
        channel.onMessage = (webrtc.RTCDataChannelMessage msg) => _onDC(msg);
        channel.onDataChannelState = (webrtc.RTCDataChannelState state) {
          _msgLog('远端DC状态: $state');
          if (state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
            if (_dcOpenCompleter != null && !_dcOpenCompleter!.isCompleted) {
              _dcOpenCompleter!.complete();
            }
            // 重连后恢复中断的传输
            if (_pendingSends.isNotEmpty || _fileMetas.isNotEmpty) {
              _onReconnected();
            }
          } else if (state == webrtc.RTCDataChannelState.RTCDataChannelClosed) {
            _msgLog('远端DC已关闭，断开连接');
            _connected = false;
            _dcOpenCompleter = null;
            onDisconnected?.call();
          }
        };
      });

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
        // 超时后也尝试标记连接，可能DC已打开但事件未触发
        _connected = true;
        _msgLog('标记已连接（DC open超时）');
        onConnected?.call();
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

    // 二进制分片直接存原始字节，避免先 base64 编码再经 _handleChunk 解码的无谓往返。
    // 旧实现每片多一次编解码 + 内存分配，高吞吐时卡住主 isolate 事件循环，
    // 导致 SCTP 接收窗口收缩 → 对端（Web）DC 缓冲区持续满载 → 文件传输超时。
    _storeChunkData(id, seq, total, chunkData);
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

    const cs = _chunkSize; // 16KB per chunk
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
    const cs = _chunkSize;

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

    // 速率统计
    var lastSampleAt = DateTime.now();
    var lastSampleBytes = 0;

    // 二进制流控发送每个 chunk
    _msgLog('SEND 开始发送文件 $total 个chunk, 文件大小=${msg.fileSize}, DC状态=${dc.state}');
    for (int i = 0; i < total; i++) {
      // 动态等待 DataChannel 缓冲区释放（防止溢出断开）
      var retryCount = 0;
      int? ba = dc.bufferedAmount;
      while (ba != null && ba > _backlogLimit) {
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
      // 速率采样：只按间隔回写，避免每片都触发 UI 重建
      final nowSample = DateTime.now();
      if (nowSample.difference(lastSampleAt) >= _speedSampleInterval) {
        final speed =
            ((i + 1) * cs - lastSampleBytes) / nowSample.difference(lastSampleAt).inMilliseconds * 1000;
        lastSampleAt = nowSample;
        lastSampleBytes = (i + 1) * cs;
        _progressCtl.add({'id': msg.id, 'speed': speed});
      }
      _progressCtl.add({'id': msg.id, 'progress': (i + 1) / total});

      // 注意：这里绝不能再「每片固定 sleep」—— 那正是旧实现吞吐只有 ~3MB/s 的原因。
      // 背压已由上方 bufferedAmount 水位循环负责。
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
    const cs = _chunkSize;

    int sentCount = receivedChunks.length;
    // 速率统计
    var lastSampleAt = DateTime.now();
    var lastSampleBytes = receivedChunks.length * cs;
    for (int i = 0; i < pending.totalChunks; i++) {
      if (receivedSet.contains(i)) continue; // 跳过已收到的

      // 流控等待
      var retryCount = 0;
      int? ba = dc.bufferedAmount;
      while (ba != null && ba > _backlogLimit) {
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
      // 速率采样
      final nowSample = DateTime.now();
      if (nowSample.difference(lastSampleAt) >= _speedSampleInterval) {
        final speed =
            (sentCount * cs - lastSampleBytes) / nowSample.difference(lastSampleAt).inMilliseconds * 1000;
        lastSampleAt = nowSample;
        lastSampleBytes = sentCount * cs;
        _progressCtl.add({'id': fileId, 'speed': speed});
      }
      _progressCtl.add({'id': fileId, 'progress': sentCount / pending.totalChunks});

      // 不再每片固定 sleep（背压由上方水位循环负责）
    }

    _msgLog('SEND 续传完成，发送 file_end, id=${_safeId(fileId)}');
    dc.send(webrtc.RTCDataChannelMessage(jsonEncode({'type': 'file_end', 'id': fileId})));
    _progressCtl.add({'id': fileId, 'progress': 1.0, 'sent': true});

    _cancelFileTimer(fileId);
    _pendingSends.remove(fileId);
  }

  /// 取消「发送中」的传输：清理本地资源 + 下发取消指令 + 同步 UI
  ///
  /// 之前只发一条 cancel 指令，本地 _pendingSends 与定时器都不清理，
  /// 导致重连后又被当成中断任务自动续传（重复生成任务、重复上报进度）。
  void cancelSend(String id) {
    final dc = _webrtc.dataChannel;
    if (dc != null && dc.state == webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      try {
        dc.send(webrtc.RTCDataChannelMessage(
          jsonEncode(<String, dynamic>{'type': 'cancel', 'id': id}),
        ));
      } catch (e) {
        _msgLog('发送 cancel 指令失败: $e');
      }
    }
    _cancelFileTimer(id);
    _pendingSends.remove(id);
    _fileMetas.remove(id);
    _cancelledTransfers.add(id);
    _clearRateState(id);
    _msgLog('SEND 传输已取消: id=${_safeId(id)}');
    _progressCtl.add(<String, dynamic>{
      'id': id,
      'progress': 0.0,
      'cancelled': true,
    });
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

    // 已取消的传输：对端可能还有在途分片，直接忽略，避免「取消后又冒出一条记录」
    if (_cancelledTransfers.contains(id)) {
      _msgLog('RECV 忽略已取消传输的 file_start: id=${_safeId(id)}');
      return;
    }

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
      'bytesReceived': 0,
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

  /// 写入一个已收到的分片（二进制路径直接传原始字节，旧 JSON/base64 路径先解码）。
  ///
  /// 抽出公共逻辑，避免二进制分片在接收端做无谓的 base64 编解码往返（见 [_handleBinaryChunk]）。
  void _storeChunkData(String id, int seq, int total, Uint8List chunkBytes) {
    // 取消后到达的在途分片一律丢弃：否则会重建 meta 并重新落一条记录，
    // 这正是「Web 端取消后 App 端出现空白文件」的成因。
    if (_cancelledTransfers.contains(id)) return;
    final meta = _fileMetas[id];
    if (meta == null) {
      _msgLog('RECV ⚠ chunk 无对应 meta: id=${_safeId(id)}');
      return;
    }
    final buf = meta['buffer'] as List<Uint8List?>;
    // 跳过已接收的分片（用于断点续传去重）
    if (buf[seq] != null) return;

    buf[seq] = chunkBytes;
    meta['chunksReceived'] = (meta['chunksReceived'] as int) + 1;
    // 累计已收字节数：速率计算与「3.2 MB / 10 MB」展示都依赖它，
    // 用实际解码后的字节数而不是 chunk 数 × 分片大小（末片通常不满）。
    meta['bytesReceived'] =
        (meta['bytesReceived'] as int? ?? 0) + chunkBytes.length;

    // 活动重置超时
    _startFileTimer(id);

    final rcvd = meta['chunksReceived'] as int;
    if (seq % 10 == 0 || rcvd >= total) {
      _msgLog('RECV chunk进度: $rcvd/$total');
    }

    // 通知进度更新
    final progress = rcvd / total;
    _progressCtl.add({'id': id, 'progress': progress});

    // 接收速率：基于最近 1 秒的字节数滑动计算（与发送端口径一致）。
    _maybeReportReceiveRate(id, meta, total);

    // 检查是否全部接收完毕
    if (rcvd >= total) {
      _msgLog('RECV ✅ 所有chunk收齐，组装文件 id=${_safeId(id)}');
      _assembleFile(id);
    }
  }

  /// 兼容旧协议（JSON/base64）的分片入口
  void _handleChunk(Map<String, dynamic> d) {
    final id = d['id'] as String;
    final seq = d['seq'] as int;
    final total = d['total'] as int;
    final chunkBytes = base64Decode(d['data'] as String);
    _storeChunkData(id, seq, total, chunkBytes);
  }

  /// 接收速率滑动采样：fileId -> [(时刻, 累计字节)]
  final Map<String, List<_RatePoint>> _rateWindows = {};
  /// 每个文件上次回写 UI 的时刻（节流，避免每片都触发重建）
  final Map<String, DateTime> _rateEmitAt = {};

  /// 计算并回写接收速率 / 已收字节 / 预估剩余时间
  ///
  /// 用最近 1 秒窗口而非「相邻两次采样」计算，可平滑单分片抖动，
  /// 显示的速率不会像心跳一样乱跳。
  void _maybeReportReceiveRate(
    String id,
    Map<String, dynamic> meta,
    int totalChunks,
  ) {
    try {
      final receivedBytes = meta['bytesReceived'] as int? ?? 0;
      final now = DateTime.now();
      final win = _rateWindows.putIfAbsent(id, () => <_RatePoint>[]);
      win.add(_RatePoint(now, receivedBytes));
      // 只保留最近 1 秒的采样点
      final cutoff = now.subtract(const Duration(seconds: 1));
      while (win.length > 2 && win.first.at.isBefore(cutoff)) {
        win.removeAt(0);
      }
      // 采样点不足（刚开始 1 秒内）无法给出稳定速率
      if (win.length < 2) return;
      // 节流：每 300ms 最多回写一次 UI
      final lastEmit = _rateEmitAt[id];
      if (lastEmit != null &&
          now.difference(lastEmit) < _speedSampleInterval) {
        return;
      }
      _rateEmitAt[id] = now;

      final first = win.first;
      final last = win.last;
      final dtMs = last.at.difference(first.at).inMilliseconds;
      if (dtMs <= 0) return;
      final speed = (last.bytes - first.bytes) * 1000 / dtMs;

      final fileSize = (meta['fileSize'] as num?)?.toInt() ?? 0;
      final remaining = (fileSize - receivedBytes).clamp(0, fileSize);
      final eta = speed > 0 ? remaining / speed : 0.0;

      _progressCtl.add(<String, dynamic>{
        'id': id,
        'speed': speed,
        'receivedBytes': receivedBytes,
        'etaSeconds': eta,
      });
    } catch (e) {
      _msgLog('计算接收速率失败: $e');
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
    _clearRateState(id);
    final meta = _fileMetas.remove(id);
    if (meta == null) return;
    final buf = meta['buffer'] as List<Uint8List?>;
    final fileName = meta['fileName'] as String;

    int totalBytes = 0;
    for (final c in buf) {
      if (c != null) totalBytes += c.length;
    }
    if (totalBytes == 0) {
      // 一字节都没收到（多为对端取消 / 连接中断）：
      // 绝不能组装出 0 字节的空白文件，直接按取消处理并清理。
      _msgLog('RECV ⚠ 无有效数据，放弃组装: id=${_safeId(id)}',
          level: LogLevel.warn);
      _cancelledTransfers.add(id);
      _deletePartialFile(meta);
      _progressCtl.add(<String, dynamic>{
        'id': id,
        'progress': 0.0,
        'cancelled': true,
      });
      return;
    }

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
      // 超时即视为中断：清理缓冲与不完整数据，避免残留半成品文件
      _deletePartialFile(_fileMetas[fileId]);
      _pendingSends.remove(fileId);
      _fileMetas.remove(fileId);
      _clearRateState(fileId);
      _fileTransferTimers.remove(fileId);
      _progressCtl.add(<String, dynamic>{
        'id': fileId,
        'progress': 0.0,
        'interrupted': true,
      });
    });
  }

  /// 取消传输超时计时器
  void _cancelFileTimer(String fileId) {
    _fileTransferTimers[fileId]?.cancel();
    _fileTransferTimers.remove(fileId);
  }

  /// 清理某次传输的速率采样状态（完成 / 取消 / 超时 / 断开时调用）
  void _clearRateState(String id) {
    _rateWindows.remove(id);
    _rateEmitAt.remove(id);
  }

  /// 取消「接收中」的传输（由 Web 端 cancel 指令触发，或本地主动取消）
  ///
  /// 关键点：
  ///  1. 立即停止接收并释放缓冲 —— 不再组装、不再落盘，杜绝空白文件
  ///  2. 记录到 _cancelledTransfers —— 在途分片到达时直接丢弃，防止会话复活
  ///  3. 通过 progress 流通知 UI 标记「已取消」，**不再往消息流塞空白文件记录**
  ///  4. 回传 cancel_ack，让 Web 端确认两端状态已一致
  void _cancelReceive(String id) {
    _cancelFileTimer(id);
    _pendingSends.remove(id);
    final meta = _fileMetas.remove(id);
    _cancelledTransfers.add(id);
    _clearRateState(id);
    // 防御性清理：若该传输曾写过临时/不完整文件，立即删除
    _deletePartialFile(meta);

    _msgLog('RECV 传输已取消: id=${_safeId(id)}');
    _progressCtl.add(<String, dynamic>{
      'id': id,
      'progress': 0.0,
      'cancelled': true,
    });
    _sendCancelAck(id);
  }

  /// 回传取消确认（供 Web 端确认接收端已清理，两端状态同步）
  void _sendCancelAck(String id) {
    final dc = _webrtc.dataChannel;
    if (dc == null || dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    try {
      dc.send(webrtc.RTCDataChannelMessage(
        jsonEncode(<String, dynamic>{'type': 'cancel_ack', 'id': id}),
      ));
    } catch (e) {
      _msgLog('回传 cancel_ack 失败: $e');
    }
  }

  /// 删除本地残留的不完整文件（若有）
  ///
  /// 当前接收链路在内存缓冲中完成组装后才落盘，正常情况下不会有半成品文件；
  /// 但保留该兜底，可覆盖「边收边写」的后续实现或异常中断留下的残file。
  void _deletePartialFile(Map<String, dynamic>? meta) {
    if (meta == null) return;
    final path = meta['partialPath'] as String?;
    if (path == null || path.isEmpty) return;
    try {
      deletePartialFile(path);
      _msgLog('RECV 已删除不完整文件: $path');
    } catch (e) {
      _msgLog('RECV 删除不完整文件失败: $e');
    }
  }

  String _mime(String n) {
    const m = {
      'pdf': 'application/pdf', 'png': 'image/png', 'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg', 'zip': 'application/zip', 'mp4': 'video/mp4',
      'txt': 'text/plain', 'json': 'application/json', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    };
    return m[n.split('.').last.toLowerCase()] ?? 'application/octet-stream';
  }

  /// 断开当前消息会话（保持 WS 监听，Web 端可再次主动连接）
  ///
  /// 以前会连 _wsSub 一起取消，导致断开一次后除非重新进入消息页，
  /// 否则 Web 端再也无法主动连上（App 收不到 room_invitation）。
  /// 现在只销毁 WebRTC 会话，WS 监听保持常驻。
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
    _webrtc.close();
    _roomId = null;
    _connected = false;
    _dcOpenCompleter = null;
    _pendingIceCandidates.clear();
    _remoteDescSet = false;
    // 注意：不清理 _fileMetas、_pendingSends、_fileTransferTimers
    // 这些数据保留以便重连后断点续传
    //
    // 但必须把「进行中」的传输在 UI 上标记为「传输中断」并丢弃不完整数据：
    // 否则列表里会留下一个永远停在 30% 的幽灵任务，用户也无从判断是否需要重传。
    for (final id in _fileMetas.keys) {
      _progressCtl.add(<String, dynamic>{'id': id, 'progress': 0.0, 'interrupted': true});
    }
    for (final id in _pendingSends.keys) {
      _progressCtl.add(<String, dynamic>{'id': id, 'progress': 0.0, 'interrupted': true});
    }
    onDisconnected?.call();
    _msgLog('已断开（保留文件传输状态以便续传，消息监听常驻）');

    // 保证 Web 端下次发起时能再次被邀请（消息通道与 UI 解耦）
    _ensureWsListening();
  }

  /// 页面卸载时调用：仅解绑 UI 回调，**不销毁后台消息通道**
  ///
  /// 消息通道常驻后台是刚需（Web 端要能主动连上），因此 UI 退出时
  /// 绝不能 dispose 掉服务本身。
  void detachUi() {
    onConnected = null;
    onDisconnected = null;
    _msgLog('UI 已解绑，消息通道保持后台常驻');
  }

  void dispose() {
    disconnect();
    // 清理所有文件传输状态
    for (final timer in _fileTransferTimers.values) {
      timer.cancel();
    }
    _fileTransferTimers.clear();
    _pendingSends.clear();
    _cancelledTransfers.clear();
    _fileMetas.clear();
    _incomingCtl.close();
    _progressCtl.close();
  }
}
