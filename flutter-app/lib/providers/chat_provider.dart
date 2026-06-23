import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../services/chat_service.dart';
import '../services/local_storage.dart';

/// 对话状态
class ChatState {
  final List<Conversation> conversations;
  final String? activeConversationId;
  final List<Message> messages;
  final bool streaming;
  final String streamingContent;
  final String selectedModel;
  final String? error;

  const ChatState({
    this.conversations = const [],
    this.activeConversationId,
    this.messages = const [],
    this.streaming = false,
    this.streamingContent = '',
    this.selectedModel = 'openai:gpt-4o',
    this.error,
  });

  ChatState copyWith({
    List<Conversation>? conversations,
    String? activeConversationId,
    List<Message>? messages,
    bool? streaming,
    String? streamingContent,
    String? selectedModel,
    String? error,
  }) {
    return ChatState(
      conversations: conversations ?? this.conversations,
      activeConversationId: activeConversationId ?? this.activeConversationId,
      messages: messages ?? this.messages,
      streaming: streaming ?? this.streaming,
      streamingContent: streamingContent ?? this.streamingContent,
      selectedModel: selectedModel ?? this.selectedModel,
      error: error,
    );
  }

  /// 当前活跃的对话
  Conversation? get activeConversation {
    if (activeConversationId == null) return null;
    try {
      return conversations.firstWhere((c) => c.id == activeConversationId);
    } catch (_) {
      return null;
    }
  }

  /// 组合消息列表（历史 + 流式内容）
  List<Message> get displayMessages {
    if (!streaming || streamingContent.isEmpty) return messages;
    final all = List<Message>.from(messages);
    all.add(Message(
      id: 'streaming',
      conversationId: activeConversationId ?? '',
      role: 'assistant',
      content: streamingContent,
      createdAt: DateTime.now(),
    ));
    return all;
  }
}

/// 对话状态管理
class ChatNotifier extends StateNotifier<ChatState> {
  final ChatService _service = ChatService();
  final LocalStorage _storage = LocalStorage.instance;

  StreamSubscription<String>? _streamSubscription;

  ChatNotifier() : super(const ChatState());

  /// 获取对话列表
  Future<void> fetchConversations() async {
    try {
      final conversations = await _service.getConversations();
      await _storage.cacheConversations(conversations);
      state = state.copyWith(conversations: conversations);
    } catch (e) {
      // 网络失败时使用缓存
      final cached = await _storage.getCachedConversations();
      if (cached.isNotEmpty) {
        state = state.copyWith(conversations: cached);
      } else {
        state = state.copyWith(error: '获取对话列表失败: $e');
      }
    }
  }

  /// 选择对话
  Future<void> selectConversation(String conversationId) async {
    state = state.copyWith(
      activeConversationId: conversationId,
      streamingContent: '',
      messages: [],
    );

    try {
      final messages = await _service.getMessages(conversationId);
      await _storage.cacheMessages(messages);
      state = state.copyWith(messages: messages);
    } catch (e) {
      // 使用缓存
      final cached = await _storage.getCachedMessages(conversationId);
      state = state.copyWith(messages: cached, error: cached.isEmpty ? '加载消息失败: $e' : null);
    }
  }

  /// 创建新对话
  Future<void> createConversation() async {
    state = state.copyWith(error: null);

    try {
      final id = await _service.createConversation(state.selectedModel);
      await fetchConversations();
      state = state.copyWith(
        activeConversationId: id,
        messages: [],
        streamingContent: '',
      );
    } catch (e) {
      state = state.copyWith(error: '创建对话失败: $e');
    }
  }

  /// 发送消息（流式）
  Future<void> sendMessage(String content) async {
    // 如果没有活跃对话，先创建
    String convId = state.activeConversationId ?? '';
    if (convId.isEmpty) {
      await createConversation();
      convId = state.activeConversationId ?? '';
      if (convId.isEmpty) return;
    }

    // 添加用户消息到列表
    final userMessage = Message(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convId,
      role: 'user',
      content: content,
      createdAt: DateTime.now(),
    );
    final updatedMessages = List<Message>.from(state.messages)..add(userMessage);

    state = state.copyWith(
      messages: updatedMessages,
      streaming: true,
      streamingContent: '',
      error: null,
    );

    try {
      final stream = _service.sendMessage(convId, content, state.selectedModel);
      final buffer = StringBuffer();

      _streamSubscription = stream.listen(
        (token) {
          buffer.write(token);
          state = state.copyWith(streamingContent: buffer.toString());
        },
        onDone: () {
          _onStreamDone(buffer.toString(), convId);
        },
        onError: (e) {
          state = state.copyWith(
            streaming: false,
            error: '消息发送失败: $e',
          );
        },
      );
    } catch (e) {
      state = state.copyWith(
        streaming: false,
        error: '发送失败: $e',
      );
    }
  }

  /// 取消当前流式响应
  void cancelStream() {
    _streamSubscription?.cancel();
    state = state.copyWith(streaming: false);
  }

  /// 设置模型
  void setModel(String model) {
    state = state.copyWith(selectedModel: model);
    // 记录最近使用的模型
    final recent = _storage.getRecentModels();
    recent.remove(model);
    recent.insert(0, model);
    _storage.saveRecentModels(recent.take(5).toList());
  }

  /// 删除对话
  Future<void> deleteConversation(String conversationId) async {
    try {
      await _service.deleteConversation(conversationId);
      await _storage.deleteCachedConversation(conversationId);
      final conversations = state.conversations
          .where((c) => c.id != conversationId)
          .toList();
      final activeConvId =
          state.activeConversationId == conversationId
              ? null
              : state.activeConversationId;
      state = state.copyWith(
        conversations: conversations,
        activeConversationId: activeConvId,
        messages: activeConvId == null ? [] : state.messages,
      );
    } catch (e) {
      state = state.copyWith(error: '删除失败: $e');
    }
  }

  void _onStreamDone(String fullContent, String convId) {
    // 添加完整的 AI 回复到消息列表
    final aiMessage = Message(
      id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convId,
      role: 'assistant',
      content: fullContent,
      createdAt: DateTime.now(),
    );
    final updatedMessages = List<Message>.from(state.messages)..add(aiMessage);

    state = state.copyWith(
      messages: updatedMessages,
      streaming: false,
      streamingContent: '',
    );

    // 刷新对话列表（标题可能更新）
    fetchConversations();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    super.dispose();
  }
}

/// 对话 Provider
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});
