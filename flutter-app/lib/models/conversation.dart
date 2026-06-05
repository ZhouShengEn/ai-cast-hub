/// 对话数据模型
///
/// 表示一个 AI 对话会话。
class Conversation {
  final String id;
  final String? deviceId;
  final String title;
  final String modelProvider;
  final String modelName;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Conversation({
    required this.id,
    this.deviceId,
    required this.title,
    required this.modelProvider,
    required this.modelName,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String? ?? '',
      deviceId: json['deviceId'] as String?,
      title: json['title'] as String? ?? '新对话',
      modelProvider: json['modelProvider'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'deviceId': deviceId,
      'title': title,
      'modelProvider': modelProvider,
      'modelName': modelName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  Conversation copyWith({
    String? id,
    String? deviceId,
    String? title,
    String? modelProvider,
    String? modelName,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      title: title ?? this.title,
      modelProvider: modelProvider ?? this.modelProvider,
      modelName: modelName ?? this.modelName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() => 'Conversation($id, $title)';
}
