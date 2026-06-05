import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/file_transfer.dart';
import '../services/file_service.dart';
import '../utils/constants.dart';

/// 文件传输状态
class FileState {
  final List<FileTransfer> transfers;
  final bool isSending;
  final String? error;

  const FileState({
    this.transfers = const [],
    this.isSending = false,
    this.error,
  });

  FileState copyWith({
    List<FileTransfer>? transfers,
    bool? isSending,
    String? error,
  }) {
    return FileState(
      transfers: transfers ?? this.transfers,
      isSending: isSending ?? this.isSending,
      error: error,
    );
  }
}

/// 文件传输状态管理
class FileNotifier extends StateNotifier<FileState> {
  final FileService _service = FileService();
  StreamSubscription<double>? _progressSubscription;

  FileNotifier() : super(const FileState());

  /// 选择文件并发送
  Future<void> selectAndSend(String targetDeviceId) async {
    if (state.isSending) return;

    state = state.copyWith(error: null);

    try {
      // 选择文件
      final platformFile = await _service.pickFile();
      if (platformFile == null) return;

      final fileName = platformFile.name ?? 'unknown';
      final fileSize = platformFile.size ?? 0;
      final filePath = platformFile.path ?? '';

      // 校验文件大小
      if (!_service.validateFile(fileSize, AppConstants.maxFileSize)) {
        state = state.copyWith(error: '文件大小超过 2GB 限制');
        return;
      }

      // 创建传输记录
      final transfer = FileTransfer(
        id: 'transfer_${DateTime.now().millisecondsSinceEpoch}',
        fileName: fileName,
        fileSize: fileSize,
        status: 'pending',
      );

      state = state.copyWith(
        transfers: [transfer, ...state.transfers],
        isSending: true,
      );

      // 计算校验和
      String checksum = '';
      if (filePath.isNotEmpty) {
        checksum = await _service.calculateChecksum(filePath);
      }

      // 初始化传输
      final transferId = await _service.initTransfer(
        fileName: fileName,
        fileSize: fileSize,
        checksum: checksum,
        targetDeviceId: targetDeviceId,
      );

      // 更新传输 ID
      final updatedTransfer = transfer.copyWith(
        id: transferId,
        status: 'transferring',
      );
      _updateTransfer(updatedTransfer);

      // 开始分片传输
      final progressStream = _service.startTransfer(
        transferId: transferId,
        filePath: filePath,
      );

      _progressSubscription = progressStream.listen(
        (progress) {
          _updateTransfer(updatedTransfer.copyWith(
            progress: progress,
            status: progress >= 1.0 ? 'completed' : 'transferring',
          ));

          if (progress >= 1.0) {
            state = state.copyWith(isSending: false);
          }
        },
        onError: (e) {
          _updateTransfer(updatedTransfer.copyWith(status: 'failed'));
          state = state.copyWith(
            isSending: false,
            error: '传输失败: $e',
          );
        },
        onDone: () {
          state = state.copyWith(isSending: false);
        },
      );
    } catch (e) {
      state = state.copyWith(
        isSending: false,
        error: '文件发送失败: $e',
      );
    }
  }

  /// 取消传输
  Future<void> cancelTransfer(String transferId) async {
    try {
      await _service.cancelTransfer(transferId);
      _updateTransferStatus(transferId, 'failed');
      state = state.copyWith(isSending: false);
    } catch (e) {
      state = state.copyWith(error: '取消传输失败: $e');
    }
  }

  /// 更新传输进度
  void updateProgress(String transferId, double progress) {
    final index = state.transfers.indexWhere((t) => t.id == transferId);
    if (index == -1) return;

    final updated = List<FileTransfer>.from(state.transfers);
    updated[index] = updated[index].copyWith(progress: progress);
    state = state.copyWith(transfers: updated);
  }

  void _updateTransfer(FileTransfer transfer) {
    final index = state.transfers.indexWhere((t) => t.id == transfer.id);
    final updated = List<FileTransfer>.from(state.transfers);
    if (index >= 0) {
      updated[index] = transfer;
    }
    state = state.copyWith(transfers: updated);
  }

  void _updateTransferStatus(String transferId, String status) {
    final index = state.transfers.indexWhere((t) => t.id == transferId);
    if (index == -1) return;
    final updated = List<FileTransfer>.from(state.transfers);
    updated[index] = updated[index].copyWith(status: status);
    state = state.copyWith(transfers: updated);
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }
}

/// 文件传输 Provider
final fileProvider = StateNotifierProvider<FileNotifier, FileState>((ref) {
  return FileNotifier();
});
