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
    // 兼容服务端 snake_case 和小驼峰两种格式
    String _getString(String camelKey, String snakeKey, String defaultValue) {
      final val = json[camelKey] ?? json[snakeKey];
      if (val == null) return defaultValue;
      return val.toString();
    }

    return Conversation(
      id: _getString('id', 'id', ''),
      deviceId: json['deviceId']?.toString() ?? json['device_id']?.toString(),
      title: _getString('title', 'title', '新对话'),
      modelProvider: _getString('modelProvider', 'model_provider', ''),
      modelName: _getString('modelName', 'model_name', ''),
      createdAt: _parseDateTime(json['createdAt'] ?? json['created_at']),
      updatedAt: _parseDateTime(json['updatedAt'] ?? json['updated_at']),
    );
  }

  static DateTime _parseDateTime(dynamic val) {
    if (val == null) return DateTime.now();
    if (val is String) return DateTime.parse(val);
    return DateTime.now();
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
