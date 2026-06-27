import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/file_transfer.dart';
import '../services/file_service.dart';
import '../utils/constants.dart';

/// 文件传输状态
class FileState {
  final List<FileTransfer> transfers;
  final bool isSending;
  final String? error;
  /// 用户已选择的待发送文件信息
  final String? pendingFileName;
  final int? pendingFileSize;
  final Uint8List? pendingFileBytes;

  const FileState({
    this.transfers = const [],
    this.isSending = false,
    this.error,
    this.pendingFileName,
    this.pendingFileSize,
    this.pendingFileBytes,
  });

  FileState copyWith({
    List<FileTransfer>? transfers,
    bool? isSending,
    String? error,
    String? pendingFileName,
    int? pendingFileSize,
    Uint8List? pendingFileBytes,
    bool clearPending = false,
  }) {
    return FileState(
      transfers: transfers ?? this.transfers,
      isSending: isSending ?? this.isSending,
      error: error,
      pendingFileName: clearPending ? null : (pendingFileName ?? this.pendingFileName),
      pendingFileSize: clearPending ? null : (pendingFileSize ?? this.pendingFileSize),
      pendingFileBytes: clearPending ? null : (pendingFileBytes ?? this.pendingFileBytes),
    );
  }
}

/// 文件传输状态管理
class FileNotifier extends StateNotifier<FileState> {
  final FileService _service = FileService();
  StreamSubscription<double>? _progressSubscription;
  bool _cancelled = false;

  FileNotifier() : super(const FileState());

  /// 选择文件（不立即发送）
  Future<void> pickFile() async {
    state = state.copyWith(error: null);
    try {
      final platformFile = await _service.pickFile();
      if (platformFile == null) return;

      final bytes = platformFile.bytes;
      if (bytes == null) {
        state = state.copyWith(error: '无法读取文件数据');
        return;
      }

      if (!_service.validateFile(platformFile.size, AppConstants.maxFileSize)) {
        state = state.copyWith(error: '文件大小超过 2GB 限制');
        return;
      }

      state = state.copyWith(
        pendingFileName: platformFile.name,
        pendingFileSize: platformFile.size,
        pendingFileBytes: bytes,
      );
    } catch (e) {
      state = state.copyWith(error: '文件选择失败: $e');
    }
  }

  /// 发送已选择的文件到目标设备
  Future<void> sendFile(String targetDeviceId) async {
    if (state.isSending) return;
    if (state.pendingFileBytes == null || state.pendingFileName == null) {
      state = state.copyWith(error: '请先选择文件');
      return;
    }

    final fileName = state.pendingFileName!;
    final fileSize = state.pendingFileSize!;
    final fileBytes = state.pendingFileBytes!;

    _cancelled = false;
    state = state.copyWith(error: null, isSending: true);

    try {
      // 计算校验和
      final checksum = await _service.calculateChecksum(fileBytes);

      // 创建传输记录
      final transfer = FileTransfer(
        id: 'transfer_${DateTime.now().millisecondsSinceEpoch}',
        fileName: fileName,
        fileSize: fileSize,
        status: 'pending',
        checksum: checksum,
      );

      state = state.copyWith(
        transfers: [transfer, ...state.transfers],
        clearPending: true,
      );

      // 初始化传输
      final transferId = await _service.initTransfer(
        fileName: fileName,
        fileSize: fileSize,
        checksum: checksum,
        targetDeviceId: targetDeviceId,
      );

      // 更新传输 ID（使用服务端返回的真实 ID）
      final updatedTransfer = transfer.copyWith(
        id: transferId,
        status: 'transferring',
      );
      _updateTransfer(updatedTransfer);

      if (_cancelled) return;

      // 开始分片传输
      final progressStream = _service.startTransfer(
        transferId: transferId,
        bytes: fileBytes,
      );

      _progressSubscription = progressStream.listen(
        (progress) {
          if (_cancelled) return;
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
    _cancelled = true;
    _progressSubscription?.cancel();
    try {
      await _service.cancelTransfer(transferId);
    } catch (_) {}
    _updateTransferStatus(transferId, 'cancelled');
    state = state.copyWith(isSending: false);
  }

  /// 清除待发文件
  void clearPendingFile() {
    state = state.copyWith(clearPending: true);
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
