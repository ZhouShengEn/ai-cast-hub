import 'package:flutter/material.dart';

import '../../providers/chat_provider.dart';
import '../../services/local_storage.dart';
import '../../utils/model_config.dart';

/// 模型选择器
///
/// 底部弹出列表，按 provider 分组显示可用模型。
/// 本地模式仅显示已配置 API Key 的本地直连提供商。
class ModelPicker extends StatelessWidget {
  final String selectedModel;
  final ValueChanged<String> onSelect;
  final ChatMode chatMode;

  const ModelPicker({
    super.key,
    required this.selectedModel,
    required this.onSelect,
    required this.chatMode,
  });

  /// 弹出底部选择器
  static Future<String?> show(
    BuildContext context,
    String currentModel,
    ChatMode chatMode,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => ModelPicker(
        selectedModel: currentModel,
        onSelect: (model) => Navigator.pop(context, model),
        chatMode: chatMode,
      ),
    );
  }

  /// 获取当前模式下的可用提供商列表
  List<ProviderConfig> _getAvailableProviders() {
    if (chatMode == ChatMode.local) {
      // 本地模式：仅显示已配置 API Key 的本地直连提供商
      final keys = LocalStorage.instance.getApiKeys();
      final configuredKeys = keys
          .where((k) => (k['key'] ?? '').isNotEmpty)
          .map((k) => k['provider'])
          .toSet();
      return ModelConfig.localProviders
          .where((p) => configuredKeys.contains(p.key))
          .toList();
    }
    // 服务端模式：显示所有提供商
    return ModelConfig.providers;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providers = _getAvailableProviders();

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.85,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                chatMode == ChatMode.local ? '选择模型（本地直连）' : '选择模型',
                style: theme.textTheme.titleLarge,
              ),
            ),
            if (providers.isEmpty && chatMode == ChatMode.local)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.key_off, size: 48, color: theme.colorScheme.outline),
                    const SizedBox(height: 12),
                    Text(
                      '暂无已配置的模型',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '请在设置 → 模型配置中添加 API Key',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.only(bottom: 32),
                  children: providers.map((provider) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Row(
                            children: [
                              Text(
                                provider.displayName,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (chatMode == ChatMode.local) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.tertiaryContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '本地',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onTertiaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        ...provider.models.map((model) {
                          final modelId = ModelConfig.buildModelId(provider.key, model.id);
                          final isSelected = modelId == selectedModel;

                          return ListTile(
                            title: Text(model.name),
                            subtitle: Text(modelId, style: theme.textTheme.bodySmall),
                            trailing: isSelected
                                ? Icon(Icons.check_circle,
                                    color: theme.colorScheme.primary)
                                : null,
                            selected: isSelected,
                            selectedTileColor:
                                theme.colorScheme.primaryContainer.withOpacity(0.3),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            onTap: () => onSelect(modelId),
                          );
                        }),
                      ],
                    );
                  }).toList(),
                ),
              ),
          ],
        );
      },
    );
  }
}
