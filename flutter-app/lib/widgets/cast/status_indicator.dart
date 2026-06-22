import 'package:flutter/material.dart';

/// 连接状态指示器
///
/// 圆点 + 文字：连接中(黄色)、已连接(绿色)、断开(灰色)、错误(红色)。
class StatusIndicator extends StatelessWidget {
  /// 状态值：'connecting' | 'connected' | 'disconnected' | 'error'
  final String status;
  final String? label;
  final double dotSize;

  const StatusIndicator({
    super.key,
    this.status = 'disconnected',
    this.label,
    this.dotSize = 10.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, text) = _statusInfo();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label ?? text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  (Color, String) _statusInfo() {
    switch (status) {
      case 'connecting':
        return (Colors.orange, '连接中');
      case 'connected':
        return (Colors.green, '已连接');
      case 'error':
        return (Colors.red, '错误');
      case 'disconnected':
      default:
        return (Colors.grey, '未连接');
    }
  }
}
