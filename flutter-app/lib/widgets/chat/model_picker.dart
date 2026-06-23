import 'package:flutter/material.dart';

/// 模型选择器
///
/// 底部弹出列表，按 provider 分组显示可用模型。
class ModelPicker extends StatelessWidget {
  final String selectedModel;
  final ValueChanged<String> onSelect;

  const ModelPicker({
    super.key,
    required this.selectedModel,
    required this.onSelect,
  });

  /// 可用模型列表
  static const List<Map<String, String>> models = [
    {'provider': 'OpenAI', 'id': 'openai:gpt-4o', 'name': 'GPT-4o'},
    {'provider': 'OpenAI', 'id': 'openai:gpt-4o-mini', 'name': 'GPT-4o Mini'},
    {'provider': 'OpenAI', 'id': 'openai:gpt-3.5-turbo', 'name': 'GPT-3.5 Turbo'},
    {'provider': 'Anthropic', 'id': 'claude:claude-3-5-sonnet-20241022', 'name': 'Claude 3.5 Sonnet'},
    {'provider': 'Anthropic', 'id': 'claude:claude-3-opus-20240229', 'name': 'Claude 3 Opus'},
    {'provider': 'Google', 'id': 'gemini:gemini-1.5-pro', 'name': 'Gemini 1.5 Pro'},
    {'provider': 'Google', 'id': 'gemini:gemini-1.5-flash', 'name': 'Gemini 1.5 Flash'},
  ];

  /// 弹出底部选择器
  static Future<String?> show(BuildContext context, String currentModel) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => ModelPicker(
        selectedModel: currentModel,
        onSelect: (model) => Navigator.pop(context, model),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 按 provider 分组
    final grouped = <String, List<Map<String, String>>>{};
    for (final model in models) {
      final provider = model['provider']!;
      grouped.putIfAbsent(provider, () => []);
      grouped[provider]!.add(model);
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.85,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // 拖动指示条
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
                '选择模型',
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.only(bottom: 32),
                children: grouped.entries.map((entry) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Provider 标签
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Text(
                          entry.key,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // 模型列表
                      ...entry.value.map((model) {
                        final modelId = model['id']!;
                        final modelName = model['name']!;
                        final isSelected = modelId == selectedModel;

                        return ListTile(
                          title: Text(modelName),
                          subtitle: Text(modelId, style: theme.textTheme.bodySmall),
                          trailing: isSelected
                              ? Icon(
                                  Icons.check_circle,
                                  color: theme.colorScheme.primary,
                                )
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
