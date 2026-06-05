import 'package:flutter/material.dart';

/// Token 用量指示器
///
/// 顶部小条显示今日输入/输出 Token 用量，点击可展开详情。
class TokenIndicator extends StatelessWidget {
  final int totalInputTokens;
  final int totalOutputTokens;
  final Map<String, Map<String, int>> modelBreakdown; // {model: {input, output}}

  const TokenIndicator({
    super.key,
    this.totalInputTokens = 0,
    this.totalOutputTokens = 0,
    this.modelBreakdown = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = totalInputTokens + totalOutputTokens;

    return InkWell(
      onTap: total > 0 ? () => _showDetail(context) : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildTokenChip(
              context,
              label: '输入',
              value: totalInputTokens,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 16),
            _buildTokenChip(
              context,
              label: '输出',
              value: totalOutputTokens,
              color: theme.colorScheme.tertiary,
            ),
            if (total > 0) ...[
              const SizedBox(width: 12),
              Text(
                '总计 ${_formatTokenCount(total)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTokenChip(
    BuildContext context, {
    required String label,
    required int value,
    required Color color,
  }) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$label: ${_formatTokenCount(value)}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _formatTokenCount(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }

  void _showDetail(BuildContext context) {
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Token 用量统计', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              if (modelBreakdown.isNotEmpty)
                ...modelBreakdown.entries.map((entry) {
                  final input = entry.value['input'] ?? 0;
                  final output = entry.value['output'] ?? 0;
                  return ListTile(
                    title: Text(entry.key),
                    subtitle: Text(
                      '输入: ${_formatTokenCount(input)}  输出: ${_formatTokenCount(output)}',
                    ),
                  );
                }),
              const Divider(),
              ListTile(
                title: const Text('合计'),
                trailing: Text(
                  '${_formatTokenCount(totalInputTokens + totalOutputTokens)} Token',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
