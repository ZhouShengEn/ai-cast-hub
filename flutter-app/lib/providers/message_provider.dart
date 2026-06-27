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

  const MessageState({this.messages = const [], this.isConnected = false, this.isConnecting = false, this.error});

  MessageState copyWith({List<ChatMessage>? messages, bool? isConnected, bool? isConnecting, String? error}) {
    return MessageState(
      messages: messages ?? this.messages, isConnected: isConnected ?? this.isConnected,
      isConnecting: isConnecting ?? this.isConnecting, error: error,
    );
  }
}

class MessageNotifier extends StateNotifier<MessageState> {
  MessageService? _svc;
  MessageNotifier() : super(const MessageState());

  Future<void> connect(String pcDeviceId) async {
    if (state.isConnected || state.isConnecting) return;
    state = state.copyWith(isConnecting: true, error: null);
    _svc = MessageService();

    // 注册断开回调
    _svc!.onDisconnected = () {
      if (!mounted) return;
      state = state.copyWith(isConnected: false, isConnecting: false);
    };

    _svc!.onIncoming.listen((msg) {
      if (!mounted) return;
      if (msg.id.startsWith('read_all_')) {
        _handleReadReceipt(msg);
        return;
      }
      // 过滤掉内部消息（如 disconnect_xxx）
      if (msg.id.startsWith('disconnect_')) return;
      state = state.copyWith(messages: [...state.messages, msg]);
    });

    _svc!.onProgress.listen((d) {
      final id = d['id'] as String?; if (id == null) return;

      // 新文件消息开始（发送方：文件已选取，开始发送）
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

      // 文件接收完成 → 触发下载
      if (d['completed'] == true) {
        final bytes = d['bytes'] as Uint8List?;
        final fileName = d['fileName'] as String? ?? 'download';
        if (bytes != null) {
          _downloadFile(bytes, fileName);
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
        list[idx] = list[idx].copyWith(progress: p, status: newStatus);
        state = state.copyWith(messages: list);
      }
    });

    try {
      await _svc!.connect(pcDeviceId);
      state = state.copyWith(isConnected: true, isConnecting: false);
    } catch (e) {
      state = state.copyWith(isConnecting: false, error: '$e');
    }
  }

  /// 下载文件（Web 浏览器下载 / 移动端保存到本地）
  void _downloadFile(Uint8List bytes, String fileName) {
    downloadFile(bytes, fileName);
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
      // 消息已通过 _progressCtl 流添加到 state（start 事件）
      // 但如果 sendFile 返回 null（用户取消选择）则无需处理
      if (msg == null) return;
      // 确保消息已添加（兜底：如果 start 事件漏了，这里补上）
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

  @override
  void dispose() { _svc?.dispose(); super.dispose(); }
}

final messageProvider = StateNotifierProvider<MessageNotifier, MessageState>((ref) => MessageNotifier());
