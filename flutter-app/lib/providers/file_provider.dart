import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/file_transfer.dart';
import '../services/file_service.dart';
import '../services/websocket_service.dart';
import '../utils/constants.dart';

/// 文件传输状态
class FileState {
  final List<FileTransfer> transfers;
  final bool isSending;
  final String? error;
  /// 用户已选择的待发送文件信息（中断后保留以便续传）
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
///
/// 支持断点续传：
/// - 发送前查询服务器已接收的分片，跳过已传输部分
/// - 连接中断后保留文件数据和传输记录，标记为 'interrupted'
/// - WebSocket 重连后自动恢复中断的传输
/// - 30 分钟无活动自动过期
class FileNotifier extends StateNotifier<FileState> {
  final FileService _service = FileService();
  StreamSubscription<double>? _progressSubscription;
  StreamSubscription<WsConnectionState>? _wsStateSubscription;
  bool _cancelled = false;

  /// 传输超时计时器：transferId -> Timer
  final Map<String, Timer> _transferTimers = {};

  FileNotifier() : super(const FileState()) {
    // 监听 WebSocket 重连，自动恢复中断的传输
    _wsStateSubscription = WebSocketService.instance.connectionStateStream.listen(
      _onWsStateChanged,
    );
  }

  /// WebSocket 状态变化回调
  void _onWsStateChanged(WsConnectionState wsState) {
    if (wsState == WsConnectionState.connected) {
      // 检查是否有中断的传输需要恢复
      _checkAndResumeInterrupted();
    }
  }

  /// 检查中断的传输并尝试恢复
  void _checkAndResumeInterrupted() {
    if (state.pendingFileBytes == null) return;

    final interruptedTransfers = state.transfers
        .where((t) => t.isInterrupted)
        .toList();

    for (final transfer in interruptedTransfers) {
      _resumeTransfer(transfer);
    }
  }

  /// 恢复单个中断的传输
  Future<void> _resumeTransfer(FileTransfer transfer) async {
    if (state.isSending) return;
    if (state.pendingFileBytes == null) return;

    print('[FileProvider] 尝试恢复传输: ${transfer.fileName} (${transfer.id})');

    _cancelled = false;
    state = state.copyWith(isSending: true, error: null);

    try {
      // 查询服务器已接收的分片
      final receivedChunks = await _service.getReceivedChunks(transfer.id);
      print('[FileProvider] 服务器已收 ${receivedChunks.length} 个分片');

      // 更新传输状态为传输中
      final resumedTransfer = transfer.copyWith(status: 'transferring');
      _updateTransfer(resumedTransfer);

      // 开始续传
      final progressStream = _service.startTransfer(
        transferId: transfer.id,
        bytes: state.pendingFileBytes!,
        checksum: transfer.checksum ?? '',
        resumeFromChunks: receivedChunks,
      );

      _progressSubscription?.cancel();
      _progressSubscription = progressStream.listen(
        (progress) {
          if (_cancelled) return;
          _updateTransfer(resumedTransfer.copyWith(
            progress: progress,
            status: progress >= 1.0 ? 'completed' : 'transferring',
          ));

          if (progress >= 1.0) {
            state = state.copyWith(isSending: false);
            _cancelTransferTimer(transfer.id);
          }
        },
        onError: (e) {
          print('[FileProvider] 续传失败: $e');
          _onTransferError(transfer, e);
        },
        onDone: () {
          state = state.copyWith(isSending: false);
        },
      );

      // 重置超时计时器
      _startTransferTimer(transfer.id);
    } catch (e) {
      print('[FileProvider] 恢复传输失败: $e');
      state = state.copyWith(isSending: false, error: '恢复传输失败: $e');
    }
  }

  /// 传输出错处理（区分连接中断 vs 其他错误）
  void _onTransferError(FileTransfer transfer, Object e) {
    final errStr = e.toString().toLowerCase();
    final isConnectionError = errStr.contains('connection') ||
        errStr.contains('timeout') ||
        errStr.contains('disconnected') ||
        errStr.contains('socket') ||
        errStr.contains('network');

    if (isConnectionError && !_cancelled) {
      // 连接中断：保留数据，标记为 interrupted
      _updateTransfer(transfer.copyWith(status: 'interrupted'));
      _startTransferTimer(transfer.id);
      state = state.copyWith(isSending: false);
      print('[FileProvider] 传输中断（连接问题）: ${transfer.fileName}');
    } else {
      // 其他错误：标记为 failed
      _updateTransfer(transfer.copyWith(status: 'failed'));
      _cancelTransferTimer(transfer.id);
      state = state.copyWith(isSending: false, error: '传输失败: $e');
    }
  }

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

      // 创建传输记录（使用临时 ID，后续更新为服务端返回的真实 ID）
      final tempId = 'transfer_${DateTime.now().millisecondsSinceEpoch}';
      final transfer = FileTransfer(
        id: tempId,
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
      _updateTransferById(tempId, updatedTransfer);

      // 启动超时计时器
      _startTransferTimer(transferId);

      if (_cancelled) return;

      // 查询服务器是否已有部分分片（断点续传）
      final receivedChunks = await _service.getReceivedChunks(transferId);
      if (receivedChunks.isNotEmpty) {
        print('[FileProvider] 发现已有 ${receivedChunks.length} 个分片，将跳过');
      }

      // 开始分片传输
      final progressStream = _service.startTransfer(
        transferId: transferId,
        bytes: fileBytes,
        checksum: checksum,
        resumeFromChunks: receivedChunks,
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
            _cancelTransferTimer(transferId);
          }
        },
        onError: (e) {
          _onTransferError(updatedTransfer, e);
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
    _cancelTransferTimer(transferId);
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

  /// 按旧 ID 更新传输（ID 变更时使用）
  void _updateTransferById(String oldId, FileTransfer transfer) {
    final index = state.transfers.indexWhere((t) => t.id == oldId);
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

  // ---- 超时管理 ----

  /// 启动传输超时计时器（30 分钟）
  void _startTransferTimer(String transferId) {
    _cancelTransferTimer(transferId);
    _transferTimers[transferId] = Timer(AppConstants.transferTimeout, () {
      _expireTransfer(transferId);
    });
  }

  /// 取消传输超时计时器
  void _cancelTransferTimer(String transferId) {
    _transferTimers[transferId]?.cancel();
    _transferTimers.remove(transferId);
  }

  /// 传输过期处理
  Future<void> _expireTransfer(String transferId) async {
    print('[FileProvider] 传输过期: $transferId');
    _updateTransferStatus(transferId, 'expired');
    _cancelTransferTimer(transferId);
    // 通知服务器
    try {
      await _service.cancelTransfer(transferId);
    } catch (_) {}
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _wsStateSubscription?.cancel();
    for (final timer in _transferTimers.values) {
      timer.cancel();
    }
    _transferTimers.clear();
    super.dispose();
  }
}

/// 文件传输 Provider
final fileProvider = StateNotifierProvider<FileNotifier, FileState>((ref) {
  return FileNotifier();
});
