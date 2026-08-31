import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../services/message_service.dart';
import '../services/debug_service.dart';
import '../utils/file_download.dart';

class MessageState {
  final List<ChatMessage> messages;
  final bool isConnected;
  final bool isConnecting;
  final String? error;
  final int unreadCount;
  final bool isViewing;

  const MessageState({this.messages = const [], this.isConnected = false, this.isConnecting = false, this.error, this.unreadCount = 0, this.isViewing = false});

  MessageState copyWith({List<ChatMessage>? messages, bool? isConnected, bool? isConnecting, String? error, int? unreadCount, bool? isViewing}) {
    return MessageState(
      messages: messages ?? this.messages, isConnected: isConnected ?? this.isConnected,
      isConnecting: isConnecting ?? this.isConnecting, error: error,
      unreadCount: unreadCount ?? this.unreadCount, isViewing: isViewing ?? this.isViewing,
    );
  }
}

class MessageNotifier extends StateNotifier<MessageState> {
  MessageService? _svc;
  bool _disposed = false;

  MessageNotifier() : super(const MessageState());

  void _initService() {
    if (_svc != null) return;

    _svc = MessageService();

    _svc!.onDisconnected = () {
      if (_disposed) return;
      state = state.copyWith(isConnected: false, isConnecting: false);
    };

    _svc!.onConnected = () {
      if (_disposed) return;
      state = state.copyWith(isConnected: true, isConnecting: false);
      DebugService().log(
        '[MsgProvider] DataChannel 已连接, isViewing=${state.isViewing}, '
        'unreadCount=${state.unreadCount}',
        level: LogLevel.info,
      );
      // DC 刚建立或重连时，仅当用户确实停留在消息页且存在未读才回执。
      // 注意：不能无条件回执，否则 isViewing 一旦残留 true，
      // 每次重连都会把 PC 端消息提前标成已读。
      if (state.isViewing && state.unreadCount > 0) {
        markAllAsRead();
      }
    };

    _svc!.onIncoming.listen((msg) {
      if (_disposed) return;
      if (msg.id.startsWith('read_all_')) {
        _handleReadReceipt(msg);
        return;
      }
      if (msg.id.startsWith('disconnect_')) return;

      // 只有「不在消息页」且「是对方发来的」才计未读
      final isUnread = !state.isViewing && !msg.isFromMe;
      final newMsg = msg.copyWith(readStatus: isUnread ? ReadStatus.unread : ReadStatus.read);

      state = state.copyWith(
        messages: [...state.messages, newMsg],
        unreadCount: isUnread ? state.unreadCount + 1 : state.unreadCount,
      );

      DebugService().log(
        '[MsgProvider] 收到消息 id=${msg.id}, isViewing=${state.isViewing}, '
        'isUnread=$isUnread, unreadCount=${state.unreadCount}',
        level: LogLevel.info,
      );

      // 用户正停留在消息页：立即回执，让 PC 端显示已读
      if (state.isViewing && !msg.isFromMe) {
        _sendReadAll();
      }
    });

    _svc!.onProgress.listen((d) async {
      final id = d['id'] as String?; if (id == null) return;

      if (d['start'] == true) {
        final existing = state.messages.indexWhere((m) => m.id == id);
        if (existing < 0) {
          state = state.copyWith(messages: [...state.messages, ChatMessage(
            id: id,
            roomId: '',
            type: MessageType.file,
            status: MessageStatus.sending,
            fileName: d['fileName'] as String?,
            fileSize: (d['fileSize'] as num?)?.toInt(),
            fileMimeType: d['fileMimeType'] as String?,
            progress: 0.0,
            isFromMe: d['isFromMe'] == true,
            timestamp: DateTime.now(),
          )]);
        }
        return;
      }

      final p = (d['progress'] as num?)?.toDouble(); if (p == null) return;

      String? savedPath;
      if (d['completed'] == true) {
        final bytes = d['bytes'] as Uint8List?;
        final fileName = d['fileName'] as String? ?? 'download';
        debugPrint('[Msg PROV] 收到 completed 事件: file=$fileName bytes=${bytes?.length}');
        if (bytes != null) {
          savedPath = await _downloadFile(bytes, fileName);
          debugPrint('[Msg PROV] 下载完成: path=$savedPath');
        } else {
          debugPrint('[Msg PROV] ⚠ bytes 为空，无法下载');
        }
      }

      final idx = state.messages.indexWhere((m) => m.id == id);
      if (idx >= 0) {
        final list = [...state.messages];
        MessageStatus newStatus = list[idx].status;
        if (d['completed'] == true) {
          newStatus = MessageStatus.received;
        } else if (d['sent'] == true) {
          newStatus = MessageStatus.sent;
        } else if (d['failed'] == true) {
          newStatus = MessageStatus.failed;
        } else if (d['interrupted'] == true) {
          newStatus = MessageStatus.interrupted;
        } else if (d['resumed'] == true) {
          // 恢复传输：保持 sending/receiving 状态
          if (list[idx].isFromMe) {
            newStatus = MessageStatus.sending;
          } else {
            newStatus = MessageStatus.receiving;
          }
        }
        list[idx] = list[idx].copyWith(progress: p, status: newStatus, filePath: savedPath ?? list[idx].filePath);
        state = state.copyWith(messages: list);
      }
    });
  }

  Future<void> startListening() async {
    _initService();
    await _svc!.startListening();
  }

  Future<void> connect(String pcDeviceId) async {
    if (state.isConnected || state.isConnecting) return;
    state = state.copyWith(isConnecting: true, error: null);

    _initService();

    try {
      await _svc!.connect(pcDeviceId);
      state = state.copyWith(isConnected: true, isConnecting: false);
    } catch (e) {
      DebugService().error('[MsgProvider] 连接失败: $e');
      state = state.copyWith(isConnecting: false, error: '$e');
    }
  }

  Future<String?> _downloadFile(Uint8List bytes, String fileName) async {
    debugPrint('[Msg PROV] 开始下载文件: $fileName (${bytes.length} bytes)');
    final result = await downloadFile(bytes, fileName);
    debugPrint('[Msg PROV] downloadFile 返回: $result');
    return result;
  }

  void _handleReadReceipt(ChatMessage receiptMsg) {
    if (receiptMsg.readStatus != ReadStatus.read) return;
    final list = state.messages.map((m) {
      if (m.isFromMe && m.readStatus == ReadStatus.unread) {
        return m.copyWith(readStatus: ReadStatus.read);
      }
      return m;
    }).toList();
    state = state.copyWith(messages: list);
  }

  Future<void> sendText(String text) async {
    if (_svc == null) return;
    if (text.trim().isEmpty) return;
    final sendingMsg = ChatMessage(
      id: 'm_${DateTime.now().millisecondsSinceEpoch}',
      roomId: '',
      type: MessageType.text,
      status: MessageStatus.sending,
      text: text.trim(),
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, sendingMsg]);

    final result = await _svc!.sendText(text.trim());

    final idx = state.messages.indexWhere((m) => m.id == sendingMsg.id);
    if (idx >= 0) {
      final list = [...state.messages];
      list[idx] = result;
      state = state.copyWith(messages: list);
    } else {
      state = state.copyWith(messages: [...state.messages, result]);
    }
  }

  Future<void> sendFile() async {
    if (_svc == null) return;
    try {
      final msg = await _svc!.sendFile();
      if (msg == null) return;
      final idx = state.messages.indexWhere((m) => m.id == msg.id);
      if (idx < 0) {
        state = state.copyWith(messages: [...state.messages, msg]);
      }
    } catch (e) {
      state = state.copyWith(error: '发送失败: $e');
    }
  }

  void cancelTransfer(String id) {
    _svc?.cancelSend(id);
    final idx = state.messages.indexWhere((m) => m.id == id);
    if (idx >= 0) {
      final list = [...state.messages];
      list[idx] = list[idx].copyWith(status: MessageStatus.cancelled);
      state = state.copyWith(messages: list);
    }
  }

  void disconnect() {
    _svc?.disconnect();
    _svc = null;
    state = state.copyWith(isConnected: false, isConnecting: false);
  }

  /// 设置用户是否停留在消息页
  ///
  /// 幂等：状态未变化时不重复触发回执，避免 PC 端消息被提前标记已读。
  void setViewing(bool viewing) {
    if (state.isViewing == viewing) return;
    DebugService().log(
      '[MsgProvider] setViewing($viewing), unreadCount=${state.unreadCount}',
      level: LogLevel.info,
    );
    state = state.copyWith(isViewing: viewing);
    if (viewing) {
      markAllAsRead();
    }
  }

  /// 强制退出「消息页浏览态」
  ///
  /// 供非消息页（如首页）在显示时调用，作为 dispose 之外的兜底，
  /// 防止 isViewing 残留 true 导致未读红点不显示、回执提前发出。
  void forceExitViewing() {
    if (!state.isViewing) return;
    DebugService().log('[MsgProvider] forceExitViewing()', level: LogLevel.info);
    state = state.copyWith(isViewing: false);
  }

  void markAllAsRead() {
    if (state.unreadCount == 0) {
      DebugService().log(
        '[MsgProvider] markAllAsRead 跳过：无未读消息',
        level: LogLevel.info,
      );
      return;
    }
    DebugService().log(
      '[MsgProvider] markAllAsRead, 清除未读 ${state.unreadCount} 条',
      level: LogLevel.info,
    );
    final list = state.messages.map((m) {
      if (!m.isFromMe && m.readStatus == ReadStatus.unread) {
        return m.copyWith(readStatus: ReadStatus.read);
      }
      return m;
    }).toList();
    state = state.copyWith(messages: list, unreadCount: 0);
    _sendReadAll();
  }

  void _sendReadAll() {
    if (_svc == null) return;
    _svc!.sendReadAll();
  }

  @override
  void dispose() { _disposed = true; _svc?.dispose(); super.dispose(); }
}

final messageProvider = StateNotifierProvider<MessageNotifier, MessageState>((ref) => MessageNotifier());
