import 'package:flutter/material.dart';

import '../../utils/constants.dart';

/// 文件选择器组件
///
/// 大号拖放区域，选择文件后显示详情和发送按钮。
class FileSelector extends StatelessWidget {
  final String? selectedFileName;
  final int? selectedFileSize;
  final bool isSending;
  final VoidCallback onSelectFile;
  final VoidCallback onSend;
  final String? warning;

  const FileSelector({
    super.key,
    this.selectedFileName,
    this.selectedFileSize,
    this.isSending = false,
    required this.onSelectFile,
    required this.onSend,
    this.warning,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFile = selectedFileName != null;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // 文件选择区域
            InkWell(
              onTap: isSending ? null : onSelectFile,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 32),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: hasFile
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    width: 2,
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  color: hasFile
                      ? theme.colorScheme.primaryContainer.withOpacity(0.3)
                      : null,
                ),
                child: Column(
                  children: [
                    Icon(
                      hasFile ? Icons.insert_drive_file : Icons.cloud_upload_outlined,
                      size: 56,
                      color: hasFile
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    if (hasFile) ...[
                      Text(
                        selectedFileName!,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatFileSize(selectedFileSize ?? 0),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ] else ...[
                      Text(
                        '点击选择文件',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '支持任意格式，最大 2GB',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 警告信息
            if (warning != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        warning!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 发送按钮
            if (hasFile) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: isSending ? null : onSend,
                  icon: const Icon(Icons.send),
                  label: Text(isSending ? '发送中...' : '发送到 PC'),
                ),
              ),
            ],
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
