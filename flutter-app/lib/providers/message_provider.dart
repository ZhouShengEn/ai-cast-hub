import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../services/message_service.dart';
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
    };

    _svc!.onIncoming.listen((msg) {
      if (_disposed) return;
      if (msg.id.startsWith('read_all_')) {
        _handleReadReceipt(msg);
        return;
      }
      if (msg.id.startsWith('disconnect_')) return;

      final isUnread = !state.isViewing && !msg.isFromMe;
      final newMsg = msg.copyWith(readStatus: isUnread ? ReadStatus.unread : ReadStatus.read);

      state = state.copyWith(
        messages: [...state.messages, newMsg],
        unreadCount: isUnread ? state.unreadCount + 1 : state.unreadCount,
      );

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

  void setViewing(bool viewing) {
    state = state.copyWith(isViewing: viewing);
    if (viewing) {
      markAllAsRead();
    }
  }

  void markAllAsRead() {
    if (state.unreadCount == 0) return;
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
