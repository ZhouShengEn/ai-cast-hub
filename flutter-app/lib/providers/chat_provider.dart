import 'dart:async';
import 'package:uuid/uuid.dart' show Uuid;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../services/chat_service.dart';
import '../services/local_ai_service.dart';
import '../services/local_storage.dart';
import '../utils/model_config.dart';

/// 对话模式
enum ChatMode {
  server, // 通过服务端中转
  local,  // App 本地直连大模型
}

/// 对话状态
class ChatState {
  final List<Conversation> conversations;
  final String? activeConversationId;
  final List<Message> messages;
  final bool streaming;       // 正在流式输出
  final bool thinking;        // 等待首个 token（思考中）
  final String streamingContent;
  final String selectedModel;
  final ChatMode chatMode;
  final String? error;

  const ChatState({
    this.conversations = const [],
    this.activeConversationId,
    this.messages = const [],
    this.streaming = false,
    this.thinking = false,
    this.streamingContent = '',
    this.selectedModel = 'openai:gpt-4o',
    this.chatMode = ChatMode.server,
    this.error,
  });

  ChatState copyWith({
    List<Conversation>? conversations,
    String? activeConversationId,
    List<Message>? messages,
    bool? streaming,
    bool? thinking,
    String? streamingContent,
    String? selectedModel,
    ChatMode? chatMode,
    String? error,
    bool clearError = false,
  }) {
    return ChatState(
      conversations: conversations ?? this.conversations,
      activeConversationId: activeConversationId ?? this.activeConversationId,
      messages: messages ?? this.messages,
      streaming: streaming ?? this.streaming,
      thinking: thinking ?? this.thinking,
      streamingContent: streamingContent ?? this.streamingContent,
      selectedModel: selectedModel ?? this.selectedModel,
      chatMode: chatMode ?? this.chatMode,
      error: clearError ? null : (error ?? this.error),
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

/// 对话状态管理 — 支持服务端模式 & 本地直连模式
class ChatNotifier extends StateNotifier<ChatState> {
  final ChatService _service = ChatService();
  final LocalAIService _localService = LocalAIService();
  final LocalStorage _storage = LocalStorage.instance;
  final Uuid _uuid = const Uuid();

  StreamSubscription<String>? _streamSubscription;
  Timer? _flushTimer;

  ChatNotifier() : super(const ChatState()) {
    _loadMode();
    _loadSelectedModel();
    _loadLocalConversations();
  }

  void _loadMode() {
    final saved = _storage.getChatMode();
    state = state.copyWith(
      chatMode: saved == 'local' ? ChatMode.local : ChatMode.server,
    );
  }

  void _loadSelectedModel() {
    final recent = _storage.getRecentModels();
    if (recent.isNotEmpty) {
      state = state.copyWith(selectedModel: recent.first);
    }
  }

  /// 加载本地持久化的对话列表
  void _loadLocalConversations() {
    final raw = _storage.getLocalConversations();
    if (raw.isEmpty) return;
    final convs = raw.map((m) => Conversation(
      id: m['id'] as String,
      deviceId: m['deviceId'] as String?,
      title: m['title'] as String? ?? '新对话',
      modelProvider: m['modelProvider'] as String? ?? '',
      modelName: m['modelName'] as String? ?? '',
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
    )).toList();
    state = state.copyWith(conversations: convs);
  }

  /// 持久化本地对话列表
  void _persistLocalConversations() {
    final data = state.conversations.map((c) => {
      'id': c.id,
      'deviceId': c.deviceId,
      'title': c.title,
      'modelProvider': c.modelProvider,
      'modelName': c.modelName,
      'createdAt': c.createdAt.toIso8601String(),
      'updatedAt': c.updatedAt.toIso8601String(),
    }).toList();
    _storage.saveLocalConversations(data);
  }

  /// 持久化本地消息
  void _persistLocalMessages() {
    final allMsgs = _storage.getLocalMessages();
    final convId = state.activeConversationId;
    if (convId == null) return;
    allMsgs[convId] = state.messages.map((m) => {
      'id': m.id,
      'conversationId': m.conversationId,
      'role': m.role,
      'content': m.content,
      'inputTokens': m.inputTokens,
      'outputTokens': m.outputTokens,
      'modelName': m.modelName,
      'createdAt': m.createdAt.toIso8601String(),
    }).toList();
    _storage.saveLocalMessages(allMsgs);
  }

  /// 切换对话模式 — 保存当前模式数据，加载新模式数据
  void setChatMode(ChatMode mode) {
    if (state.chatMode == mode) return;

    // 保存当前模式数据
    if (state.chatMode == ChatMode.local) {
      _persistLocalConversations();
      _persistLocalMessages();
    }

    // 取消当前流
    _streamSubscription?.cancel();
    _flushTimer?.cancel();
    _localService.cancel();

    _storage.saveChatMode(mode.name);

    if (mode == ChatMode.local) {
      // 加载本地对话列表
      final raw = _storage.getLocalConversations();
      final convs = raw.map((m) => Conversation(
        id: m['id'] as String,
        deviceId: m['deviceId'] as String?,
        title: m['title'] as String? ?? '新对话',
        modelProvider: m['modelProvider'] as String? ?? '',
        modelName: m['modelName'] as String? ?? '',
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
      )).toList();

      // 自动选中最近的对话（如果有），恢复其消息
      String? activeId;
      List<Message> activeMessages = [];
      if (convs.isNotEmpty) {
        activeId = convs.first.id;
        final allMsgs = _storage.getLocalMessages();
        final msgList = allMsgs[activeId] ?? [];
        activeMessages = msgList.map((m) => Message(
          id: m['id'] as String,
          conversationId: m['conversationId'] as String,
          role: m['role'] as String,
          content: m['content'] as String? ?? '',
          inputTokens: m['inputTokens'] as int?,
          outputTokens: m['outputTokens'] as int?,
          modelName: m['modelName'] as String?,
          createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
        )).toList();
      }

      state = state.copyWith(
        chatMode: mode,
        conversations: convs,
        activeConversationId: activeId,
        messages: activeMessages,
        streaming: false,
        thinking: false,
        streamingContent: '',
        clearError: true,
      );
    } else {
      // 切换到服务端模式，清空本地数据，由 fetchConversations 加载
      state = state.copyWith(
        chatMode: mode,
        conversations: [],
        activeConversationId: null,
        messages: [],
        streaming: false,
        thinking: false,
        streamingContent: '',
        clearError: true,
      );
      fetchConversations();
    }
  }

  /// 获取对话列表
  Future<void> fetchConversations() async {
    if (state.chatMode == ChatMode.local) return;

    try {
      final conversations = await _service.getConversations();
      await _storage.cacheConversations(conversations);
      state = state.copyWith(conversations: conversations);
    } catch (e) {
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

    if (state.chatMode == ChatMode.local) {
      // 本地模式：从持久化数据恢复消息
      final allMsgs = _storage.getLocalMessages();
      final msgList = allMsgs[conversationId] ?? [];
      final messages = msgList.map((m) => Message(
        id: m['id'] as String,
        conversationId: m['conversationId'] as String,
        role: m['role'] as String,
        content: m['content'] as String? ?? '',
        inputTokens: m['inputTokens'] as int?,
        outputTokens: m['outputTokens'] as int?,
        modelName: m['modelName'] as String?,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
      )).toList();
      state = state.copyWith(messages: messages);
      return;
    }

    try {
      final messages = await _service.getMessages(conversationId);
      await _storage.cacheMessages(messages);
      state = state.copyWith(messages: messages);
    } catch (e) {
      final cached = await _storage.getCachedMessages(conversationId);
      state = state.copyWith(
        messages: cached,
        error: cached.isEmpty ? '加载消息失败: $e' : null,
      );
    }
  }

  /// 创建新对话
  Future<void> createConversation() async {
    state = state.copyWith(clearError: true);

    if (state.chatMode == ChatMode.local) {
      final now = DateTime.now();
      final id = 'local_${_uuid.v4()}';
      final parsed = ModelConfig.parseModelId(state.selectedModel);
      final provider = ModelConfig.getProvider(parsed.provider);

      final conv = Conversation(
        id: id,
        title: '新对话',
        modelProvider: parsed.provider,
        modelName: provider != null
            ? '${provider.displayName} ${parsed.model}'
            : state.selectedModel,
        createdAt: now,
        updatedAt: now,
      );
      state = state.copyWith(
        conversations: [conv, ...state.conversations],
        activeConversationId: id,
        messages: [],
        streamingContent: '',
      );
      _persistLocalConversations();
      return;
    }

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

    // 进入"思考中"状态
    state = state.copyWith(
      messages: updatedMessages,
      streaming: true,
      thinking: true,
      streamingContent: '',
      clearError: true,
    );

    // 本地模式先持久化用户消息
    if (state.chatMode == ChatMode.local) {
      _persistLocalMessages();
    }

    try {
      final Stream<String> stream;
      if (state.chatMode == ChatMode.local) {
        final history = updatedMessages
            .where((m) => m.id != 'streaming')
            .map((m) => {'role': m.role, 'content': m.content})
            .toList();
        stream = _localService.sendMessage(state.selectedModel, history);
      } else {
        stream = _service.sendMessage(convId, content, state.selectedModel);
      }

      final buffer = StringBuffer();
      // 用于平滑动画的显示缓冲：实际内容可能比显示内容多（延迟释放）
      final displayBuffer = StringBuffer();
      bool firstToken = true;

      void flushDisplay() {
        state = state.copyWith(streamingContent: displayBuffer.toString());
      }

      _streamSubscription = stream.listen(
        (token) {
          if (token.startsWith('\x00ERROR:')) {
            final errorMsg = token.substring(7);
            _onStreamError(errorMsg, convId);
            return;
          }
          // 收到首个 token，退出思考状态
          if (state.thinking) {
            state = state.copyWith(thinking: false);
          }
          buffer.write(token);

          // 首个 token 立即显示，避免延迟感
          if (firstToken) {
            firstToken = false;
            displayBuffer.write(buffer.toString());
            flushDisplay();
            // 启动定时器，每 30ms 刷新一次显示内容，实现打字机效果
            _flushTimer?.cancel();
            _flushTimer = Timer.periodic(const Duration(milliseconds: 30), (_) {
              if (displayBuffer.length < buffer.length) {
                // 每次追加 2-3 个字符，模拟流畅打字
                final remaining = buffer.length - displayBuffer.length;
                final step = remaining > 3 ? 3 : remaining;
                displayBuffer.write(buffer.toString().substring(
                  displayBuffer.length,
                  displayBuffer.length + step,
                ));
                flushDisplay();
              }
            });
          }
        },
        onDone: () {
          _flushTimer?.cancel();
          // 确保最终显示完整内容
          if (state.streaming) {
            state = state.copyWith(streamingContent: buffer.toString());
            _onStreamDone(buffer.toString(), convId);
          }
        },
        onError: (e) {
          _flushTimer?.cancel();
          _onStreamError(e.toString().replaceFirst('Exception: ', ''), convId);
        },
      );
    } catch (e) {
      _onStreamError(e.toString().replaceFirst('Exception: ', ''), convId);
    }
  }

  /// 取消当前流式响应
  void cancelStream() {
    _streamSubscription?.cancel();
    _flushTimer?.cancel();
    _localService.cancel();

    if (state.streaming && state.streamingContent.isNotEmpty) {
      final aiMessage = Message(
        id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
        conversationId: state.activeConversationId ?? '',
        role: 'assistant',
        content: '${state.streamingContent}\n\n_(已取消)_',
        createdAt: DateTime.now(),
      );
      final updatedMessages = List<Message>.from(state.messages)..add(aiMessage);
      state = state.copyWith(
        messages: updatedMessages,
        streaming: false,
        thinking: false,
        streamingContent: '',
      );
      if (state.chatMode == ChatMode.local) _persistLocalMessages();
    } else {
      state = state.copyWith(streaming: false, thinking: false, streamingContent: '');
    }
  }

  /// 设置模型
  void setModel(String model) {
    state = state.copyWith(selectedModel: model);
    final recent = _storage.getRecentModels();
    recent.remove(model);
    recent.insert(0, model);
    _storage.saveRecentModels(recent.take(5).toList());
  }

  /// 删除对话
  Future<void> deleteConversation(String conversationId) async {
    if (state.chatMode == ChatMode.local) {
      final conversations = state.conversations
          .where((c) => c.id != conversationId)
          .toList();
      // 同时删除持久化的消息
      final allMsgs = _storage.getLocalMessages();
      allMsgs.remove(conversationId);
      _storage.saveLocalMessages(allMsgs);

      state = state.copyWith(
        conversations: conversations,
        activeConversationId: state.activeConversationId == conversationId
            ? null
            : state.activeConversationId,
        messages: state.activeConversationId == conversationId
            ? []
            : state.messages,
      );
      _persistLocalConversations();
      return;
    }

    try {
      await _service.deleteConversation(conversationId);
      await _storage.deleteCachedConversation(conversationId);
      final conversations = state.conversations
          .where((c) => c.id != conversationId)
          .toList();
      state = state.copyWith(
        conversations: conversations,
        activeConversationId: state.activeConversationId == conversationId
            ? null
            : state.activeConversationId,
        messages: state.activeConversationId == conversationId
            ? []
            : state.messages,
      );
    } catch (e) {
      state = state.copyWith(error: '删除失败: $e');
    }
  }

  void _onStreamDone(String fullContent, String convId) {
    final aiMessage = Message(
      id: 'ai_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convId,
      role: 'assistant',
      content: fullContent,
      createdAt: DateTime.now(),
    );
    final updatedMessages = List<Message>.from(state.messages)..add(aiMessage);

    List<Conversation> updatedConversations = state.conversations;
    if (state.chatMode == ChatMode.local) {
      updatedConversations = state.conversations.map((c) {
        if (c.id == convId && c.title == '新对话') {
          final userMsgs = state.messages.where((m) => m.isUser);
          final titleSource = userMsgs.isNotEmpty ? userMsgs.first.content : fullContent;
          final title = titleSource.length > 20
              ? '${titleSource.substring(0, 20)}...'
              : titleSource;
          return c.copyWith(title: title, updatedAt: DateTime.now());
        }
        return c;
      }).toList();
    }

    state = state.copyWith(
      messages: updatedMessages,
      conversations: updatedConversations,
      streaming: false,
      thinking: false,
      streamingContent: '',
    );

    // 本地模式持久化
    if (state.chatMode == ChatMode.local) {
      _persistLocalConversations();
      _persistLocalMessages();
    } else {
      fetchConversations();
    }
  }

  void _onStreamError(String errorMsg, String convId) {
    _streamSubscription?.cancel();

    final aiMessage = Message(
      id: 'error_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convId,
      role: 'assistant',
      content: '⚠️ $errorMsg',
      createdAt: DateTime.now(),
    );
    final updatedMessages = List<Message>.from(state.messages)..add(aiMessage);

    state = state.copyWith(
      messages: updatedMessages,
      streaming: false,
      thinking: false,
      streamingContent: '',
      error: errorMsg,
    );

    if (state.chatMode == ChatMode.local) {
      _persistLocalMessages();
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _flushTimer?.cancel();
    _localService.cancel();
    super.dispose();
  }
}

/// 对话 Provider
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});
