import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/chat_provider.dart';
import '../models/message.dart';
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
            );
            if (selected != null) {
              chatNotifier.setModel(selected);
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('AI 对话'),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down, size: 20, color: theme.colorScheme.onSurface),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建对话',
            onPressed: () => chatNotifier.createConversation(),
          ),
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
                              '${conv.modelName} · ${conv.updatedAt.timeAgo()}',
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
                          '选择模型开始对话',
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
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
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
