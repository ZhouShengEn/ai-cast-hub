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
  String? _selectedFileName;
  int? _selectedFileSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileState = ref.watch(fileProvider);
    final deviceState = ref.watch(deviceProvider);
    final fileNotifier = ref.read(fileProvider.notifier);

    // 获取已绑定的 PC 设备 ID
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
            selectedFileName: _selectedFileName,
            selectedFileSize: _selectedFileSize,
            isSending: fileState.isSending,
            warning: targetDeviceId.isEmpty ? '未绑定 PC 设备，请先在首页扫描二维码完成绑定' : null,
            onSelectFile: () async {
              // 直接通过 provider 选择并发送（provider 内部调用 file_picker）
              if (targetDeviceId.isNotEmpty) {
                await fileNotifier.selectAndSend(targetDeviceId);
                setState(() {
                  _selectedFileName = null;
                  _selectedFileSize = null;
                });
              }
            },
            onSend: () {
              if (targetDeviceId.isNotEmpty) {
                fileNotifier.selectAndSend(targetDeviceId);
                setState(() {
                  _selectedFileName = null;
                  _selectedFileSize = null;
                });
              }
            },
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
                  ],
                ),
              ),
            ),
          ],

          // 错误提示
          if (fileState.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                fileState.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
