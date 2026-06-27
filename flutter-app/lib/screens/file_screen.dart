import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/file_provider.dart';
import '../providers/device_provider.dart';
import '../widgets/file/file_selector.dart';
import '../widgets/file/send_progress.dart';

/// 文件传输页面 — 选择文件并发送到已绑定 PC
class FileScreen extends ConsumerStatefulWidget {
  const FileScreen({super.key});

  @override
  ConsumerState<FileScreen> createState() => _FileScreenState();
}

class _FileScreenState extends ConsumerState<FileScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(deviceProvider.notifier).fetchDeviceList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileState = ref.watch(fileProvider);
    final deviceState = ref.watch(deviceProvider);
    final fileNotifier = ref.read(fileProvider.notifier);

    final targetDeviceId = deviceState.pairedDevices.isNotEmpty
        ? deviceState.pairedDevices.first.deviceUuid
        : '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件传输'),
      ),
      body: Column(
        children: [
          // 文件选择器
          FileSelector(
            selectedFileName: fileState.pendingFileName,
            selectedFileSize: fileState.pendingFileSize,
            isSending: fileState.isSending,
            warning: targetDeviceId.isEmpty ? '未绑定 PC 设备，请先在首页输入连接码完成绑定' : null,
            onSelectFile: () {
              if (targetDeviceId.isEmpty) {
                Navigator.pushNamed(context, '/scan').then((_) {
                  ref.read(deviceProvider.notifier).fetchDeviceList();
                });
                return;
              }
              fileNotifier.pickFile();
            },
            onSend: () {
              if (targetDeviceId.isNotEmpty) {
                fileNotifier.sendFile(targetDeviceId);
              }
            },
          ),

          // 错误提示
          if (fileState.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Chip(
                avatar: const Icon(Icons.error_outline, size: 18, color: Colors.red),
                label: Expanded(
                  child: Text(
                    fileState.error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
                    maxLines: 2,
                  ),
                ),
                backgroundColor: Colors.red.shade50,
                side: BorderSide.none,
              ),
            ),

          // 发送历史
          if (fileState.transfers.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('传输记录', style: theme.textTheme.titleSmall),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: fileState.transfers.length,
                itemBuilder: (context, index) {
                  final transfer = fileState.transfers[index];
                  return SendProgress(
                    transfer: transfer,
                    onCancel: transfer.isTransferring
                        ? () => fileNotifier.cancelTransfer(transfer.id)
                        : null,
                  );
                },
              ),
            ),
          ] else ...[
            // 空状态
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 64,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      targetDeviceId.isEmpty
                          ? '请先绑定 PC 设备'
                          : '选择文件发送到 PC',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (targetDeviceId.isEmpty) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () async {
                          final result = await Navigator.pushNamed(context, '/scan');
                          if (result == true) {
                            await ref.read(deviceProvider.notifier).fetchDeviceList();
                          }
                        },
                        icon: const Icon(Icons.link),
                        label: const Text('去输入连接码'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
