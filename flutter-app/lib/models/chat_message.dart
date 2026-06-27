import 'dart:typed_data';

/// 消息类型
enum MessageType { text, file }

/// 消息状态
enum MessageStatus { sending, sent, receiving, received, failed, cancelled }

/// 已读状态
enum ReadStatus { unread, read }

/// 聊天消息（支持文本和文件）
class ChatMessage {
  final String id;
  final String roomId;
  final MessageType type;
  final MessageStatus status;
  final ReadStatus readStatus;     // 已读/未读状态
  final String? text;              // 文本内容
  final String? fileName;          // 文件名（文件消息）
  final int? fileSize;             // 文件大小（bytes）
  final String? fileMimeType;      // 文件 MIME 类型
  final double progress;            // 传输进度 0.0-1.0
  final bool isFromMe;              // 是否自己发送的
  final DateTime timestamp;

  const ChatMessage({
    required this.id,
    required this.roomId,
    required this.type,
    this.status = MessageStatus.sending,
    this.readStatus = ReadStatus.unread,
    this.text,
    this.fileName,
    this.fileSize,
    this.fileMimeType,
    this.progress = 0.0,
    this.isFromMe = true,
    required this.timestamp,
  });

  bool get isText => type == MessageType.text;
  bool get isFile => type == MessageType.file;
  bool get isTransferring => isFile && (status == MessageStatus.sending || status == MessageStatus.receiving);
  bool get isCompleted => status == MessageStatus.sent || status == MessageStatus.received;
  bool get isFailed => status == MessageStatus.failed;
  bool get isSending => status == MessageStatus.sending;

  String get statusLabel {
    switch (status) {
      case MessageStatus.sending: return '发送中';
      case MessageStatus.sent: return readStatus == ReadStatus.read ? '已读' : '已发送';
      case MessageStatus.receiving: return '接收中';
      case MessageStatus.received: return '已接收';
      case MessageStatus.failed: return '发送失败';
      case MessageStatus.cancelled: return '已取消';
    }
  }

  String get fileSizeFormatted {
    if (fileSize == null) return '';
    final bytes = fileSize!;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  ChatMessage copyWith({
    String? id,
    String? roomId,
    MessageType? type,
    MessageStatus? status,
    ReadStatus? readStatus,
    String? text,
    String? fileName,
    int? fileSize,
    String? fileMimeType,
    double? progress,
    bool? isFromMe,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      roomId: roomId ?? this.roomId,
      type: type ?? this.type,
      status: status ?? this.status,
      readStatus: readStatus ?? this.readStatus,
      text: text ?? this.text,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      fileMimeType: fileMimeType ?? this.fileMimeType,
      progress: progress ?? this.progress,
      isFromMe: isFromMe ?? this.isFromMe,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'roomId': roomId,
      'type': type.name,
      'status': status.name,
      'readStatus': readStatus.name,
      'text': text,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileMimeType': fileMimeType,
      'progress': progress,
      'isFromMe': isFromMe,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      roomId: json['roomId'] as String,
      type: MessageType.values.firstWhere((e) => e.name == json['type']),
      status: MessageStatus.values.firstWhere((e) => e.name == json['status'], orElse: () => MessageStatus.sending),
      readStatus: ReadStatus.values.firstWhere((e) => e.name == json['readStatus'], orElse: () => ReadStatus.unread),
      text: json['text'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as int?,
      fileMimeType: json['fileMimeType'] as String?,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      isFromMe: json['isFromMe'] as bool? ?? false,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }

  @override
  String toString() => 'ChatMessage($type, $status)';
}
