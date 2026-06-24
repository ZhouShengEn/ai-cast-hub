import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/chat_provider.dart';
import '../utils/extensions.dart';
import '../utils/model_config.dart';
import '../widgets/chat/chat_bubble.dart';
import '../widgets/chat/chat_input_bar.dart';
import '../widgets/chat/model_picker.dart';
import '../widgets/chat/token_indicator.dart';

/// AI 对话页面 — 模型选择、流式对话、历史管理
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(chatProvider.notifier).fetchConversations();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chatState = ref.watch(chatProvider);
    final chatNotifier = ref.read(chatProvider.notifier);
    final messages = chatState.displayMessages;
    final isStreaming = chatState.streaming;

    // 流式更新时自动滚动
    if (isStreaming) {
      _scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () async {
            final selected = await ModelPicker.show(
              context,
              chatState.selectedModel,
              chatState.chatMode,
            );
            if (selected != null) {
              chatNotifier.setModel(selected);
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(chatState.chatMode == ChatMode.local ? '本地对话' : 'AI 对话'),
              if (chatState.chatMode == ChatMode.local) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _shortModelName(chatState.selectedModel),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down, size: 20, color: theme.colorScheme.onSurface),
            ],
          ),
        ),
        actions: [
          // 模式切换按钮
          IconButton(
            icon: Icon(
              chatState.chatMode == ChatMode.local ? Icons.phone_android : Icons.cloud,
            ),
            tooltip: chatState.chatMode == ChatMode.local ? '本地模式 — 点击切换服务端' : '服务端模式 — 点击切换本地',
            onPressed: () {
              final next = chatState.chatMode == ChatMode.local
                  ? ChatMode.server
                  : ChatMode.local;
              chatNotifier.setChatMode(next);
              if (next == ChatMode.server) {
                chatNotifier.fetchConversations();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建对话',
            onPressed: () => chatNotifier.createConversation(),
          ),
          // 本地模式：设置按钮；服务端模式：对话历史按钮
          if (chatState.chatMode == ChatMode.local)
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: '模型配置',
              onPressed: () => Navigator.pushNamed(context, '/settings'),
            )
          else
            Builder(
              builder: (scaffoldContext) => IconButton(
                icon: const Icon(Icons.history),
                tooltip: '对话历史',
                onPressed: () => Scaffold.of(scaffoldContext).openDrawer(),
              ),
            ),
        ],
      ),
      // 对话历史抽屉
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('对话历史', style: theme.textTheme.titleLarge),
              ),
              const Divider(),
              Expanded(
                child: chatState.conversations.isEmpty
                    ? Center(
                        child: Text(
                          '暂无历史对话',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: chatState.conversations.length,
                        itemBuilder: (context, index) {
                          final conv = chatState.conversations[index];
                          final isActive = conv.id == chatState.activeConversationId;

                          return ListTile(
                            title: Text(
                              conv.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${conv.modelName} \u00b7 ${conv.updatedAt.timeAgo()}',
                              style: theme.textTheme.bodySmall,
                            ),
                            selected: isActive,
                            selectedTileColor:
                                theme.colorScheme.primaryContainer.withOpacity(0.3),
                            onTap: () {
                              chatNotifier.selectConversation(conv.id);
                              Navigator.pop(context);
                            },
                            onLongPress: () {
                              _showDeleteDialog(conv.id, conv.title);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Token 用量指示
          TokenIndicator(
            totalInputTokens: messages
                .where((m) => m.isUser)
                .fold(0, (sum, m) => sum + (m.inputTokens ?? 0)),
            totalOutputTokens: messages
                .where((m) => m.isAssistant && m.id != 'streaming')
                .fold(0, (sum, m) => sum + (m.outputTokens ?? 0)),
          ),

          // 本地模式提示条
          if (chatState.chatMode == ChatMode.local)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: theme.colorScheme.tertiaryContainer,
              child: Row(
                children: [
                  Icon(Icons.phone_android, size: 16,
                      color: theme.colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '本地直连模式 — API Key 在设置 → 模型配置中管理',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 消息列表
          Expanded(
            child: messages.isEmpty && !isStreaming
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          chatState.chatMode == ChatMode.local
                              ? '选择模型开始本地对话'
                              : '选择模型开始对话',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '当前模型: ${chatState.selectedModel}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        if (chatState.chatMode == ChatMode.local) ...[
                          const SizedBox(height: 4),
                          Text(
                            '点击右上角图标可切换服务端/本地模式',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length + (chatState.thinking ? 1 : 0),
                    itemBuilder: (context, index) {
                      // 思考中指示气泡
                      if (index == messages.length && chatState.thinking) {
                        return _buildThinkingBubble(theme);
                      }
                      final message = messages[index];
                      final isLastAI = index == messages.length - 1 &&
                          message.isAssistant &&
                          message.id == 'streaming';

                      return ChatBubble(
                        message: message,
                        isStreaming: isLastAI && isStreaming,
                      );
                    },
                  ),
          ),

          // 底部输入栏
          ChatInputBar(
            isStreaming: isStreaming,
            onSend: (text) {
              chatNotifier.sendMessage(text);
              _scrollToBottom();
            },
            onStop: () => chatNotifier.cancelStream(),
          ),
        ],
      ),
    );
  }

  String _shortModelName(String modelId) {
    final name = ModelConfig.getModelDisplayName(modelId);
    return name.length > 20 ? '${name.substring(0, 18)}…' : name;
  }

  Widget _buildThinkingBubble(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(
              Icons.psychology,
              size: 18,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: _ThinkingDots(color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(String convId, String title) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('确定删除对话「$title」？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(chatProvider.notifier).deleteConversation(convId);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// 思考中动画 — 三个点交替跳动
class _ThinkingDots extends StatefulWidget {
  final Color color;
  const _ThinkingDots({required this.color});

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with TickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = (_controller.value - i * 0.2) % 1.0;
            final scale = 0.5 + 0.5 * (1 - (2 * t - 1).abs());
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.color.withOpacity(0.4 + 0.6 * scale),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
