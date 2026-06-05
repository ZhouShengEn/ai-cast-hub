/// 文件传输数据模型
///
/// 表示一次文件传输任务的进度和状态。
class FileTransfer {
  final String id;
  final String fileName;
  final int fileSize;
  final String status; // 'pending' | 'transferring' | 'completed' | 'failed'
  final double progress; // 0.0 ~ 1.0
  final String? checksum;

  const FileTransfer({
    required this.id,
    required this.fileName,
    required this.fileSize,
    this.status = 'pending',
    this.progress = 0.0,
    this.checksum,
  });

  bool get isPending => status == 'pending';
  bool get isTransferring => status == 'transferring';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';

  /// 进度百分比（0-100）
  int get progressPercent => (progress * 100).round();

  factory FileTransfer.fromJson(Map<String, dynamic> json) {
    return FileTransfer(
      id: json['id'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      fileSize: json['fileSize'] as int? ?? 0,
      status: json['status'] as String? ?? 'pending',
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      checksum: json['checksum'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fileName': fileName,
      'fileSize': fileSize,
      'status': status,
      'progress': progress,
      'checksum': checksum,
    };
  }

  FileTransfer copyWith({
    String? id,
    String? fileName,
    int? fileSize,
    String? status,
    double? progress,
    String? checksum,
  }) {
    return FileTransfer(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      checksum: checksum ?? this.checksum,
    );
  }

  @override
  String toString() => 'FileTransfer($fileName, $status, $progressPercent%)';
}
