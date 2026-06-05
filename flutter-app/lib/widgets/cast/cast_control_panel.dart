import 'package:flutter/material.dart';

/// 投屏控制面板
///
/// 显示开始/停止投屏按钮、连接状态和投屏质量选择。
class CastControlPanel extends StatelessWidget {
  final bool isCasting;
  final String connectionState; // 'connecting' | 'connected' | 'disconnected'
  final String? pcDeviceName;
  final String? castQuality; // 'high' | 'medium' | 'low'
  final VoidCallback onStartCast;
  final VoidCallback onStopCast;
  final ValueChanged<String>? onQualityChanged;

  const CastControlPanel({
    super.key,
    this.isCasting = false,
    this.connectionState = 'disconnected',
    this.pcDeviceName,
    this.castQuality = 'high',
    required this.onStartCast,
    required this.onStopCast,
    this.onQualityChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 投屏状态图标
            Icon(
              isCasting ? Icons.cast_connected : Icons.cast,
              size: 64,
              color: isCasting
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),

            // 状态文字
            if (isCasting) ...[
              Text(
                '正在投屏${pcDeviceName != null ? '到 $pcDeviceName' : ''}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              _buildConnectionStatus(theme, connectionState),
            ] else ...[
              Text(
                '准备投屏',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                '点击下方按钮开始将屏幕投射到 PC',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: 24),

            // 投屏质量选择（非投屏中可修改）
            if (!isCasting) ...[
              _buildQualitySelector(theme),
              const SizedBox(height: 16),
            ],

            // 开始/停止按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: isCasting
                  ? FilledButton.icon(
                      onPressed: onStopCast,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止投屏'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: onStartCast,
                      icon: const Icon(Icons.screen_share),
                      label: const Text('开始投屏'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatus(ThemeData theme, String state) {
    Color color;
    String text;

    switch (state) {
      case 'connecting':
        color = Colors.orange;
        text = '连接中...';
        break;
      case 'connected':
        color = Colors.green;
        text = '已连接';
        break;
      default:
        color = Colors.grey;
        text = '未连接';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }

  Widget _buildQualitySelector(ThemeData theme) {
    const qualities = [
      {'value': 'high', 'label': '高画质', 'desc': '1080p'},
      {'value': 'medium', 'label': '中等', 'desc': '720p'},
      {'value': 'low', 'label': '低画质', 'desc': '480p'},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('投屏质量', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          children: qualities.map((q) {
            final isSelected = q['value'] == castQuality;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Column(
                    children: [
                      Text(q['label']!),
                      Text(
                        q['desc']!,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  selected: isSelected,
                  onSelected: (_) => onQualityChanged?.call(q['value']!),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
