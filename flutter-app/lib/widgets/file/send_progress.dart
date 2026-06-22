import 'package:flutter/material.dart';

import '../../models/file_transfer.dart';

/// 文件传输进度组件
///
/// 显示进度条、百分比、文件信息和取消按钮。
class SendProgress extends StatelessWidget {
  final FileTransfer transfer;
  final VoidCallback? onCancel;

  const SendProgress({
    super.key,
    required this.transfer,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDone = transfer.isCompleted;
    final isFailed = transfer.isFailed;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 文件信息行
            Row(
              children: [
                Icon(
                  isDone
                      ? Icons.check_circle
                      : isFailed
                          ? Icons.error
                          : Icons.insert_drive_file,
                  color: isDone
                      ? Colors.green
                      : isFailed
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        transfer.fileName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatFileSize(transfer.fileSize),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // 取消按钮（仅在传输中显示）
                if (transfer.isTransferring && onCancel != null)
                  IconButton(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: '取消',
                  ),
                if (isDone)
                  const Icon(Icons.done_all, color: Colors.green, size: 22),
                if (isFailed)
                  Icon(Icons.error_outline,
                      color: theme.colorScheme.error, size: 22),
              ],
            ),

            const SizedBox(height: 12),

            // 进度条
            if (transfer.isTransferring || isDone) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: transfer.progress,
                  minHeight: 8,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isDone ? Colors.green : theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${transfer.progressPercent}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isDone ? Colors.green : theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isDone)
                    Text(
                      '传输完成',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.green,
                      ),
                    )
                  else
                    Text(
                      '传输中...',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],

            // 失败状态
            if (isFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '传输失败',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),

            // 等待状态
            if (transfer.isPending)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '准备传输...',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
