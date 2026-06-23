/// 消息数据模型
///
/// 对话中的单条消息，支持 user / assistant / system 角色。
class Message {
  final String id;
  final String conversationId;
  final String role; // 'user' | 'assistant' | 'system'
  final String content;
  final int? inputTokens;
  final int? outputTokens;
  final String? modelName;
  final DateTime createdAt;

  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.inputTokens,
    this.outputTokens,
    this.modelName,
    required this.createdAt,
  });

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  factory Message.fromJson(Map<String, dynamic> json) {
    // 兼容服务端 snake_case 和小驼峰两种格式
    String _getStr(String camelKey, String snakeKey, String def) {
      final val = json[camelKey] ?? json[snakeKey];
      if (val == null) return def;
      return val.toString();
    }

    int? _getInt(String camelKey, String snakeKey) {
      final val = json[camelKey] ?? json[snakeKey];
      if (val == null) return null;
      if (val is int) return val;
      return int.tryParse(val.toString());
    }

    DateTime _parseDt(dynamic val) {
      if (val == null) return DateTime.now();
      if (val is String) return DateTime.parse(val);
      return DateTime.now();
    }

    return Message(
      id: _getStr('id', 'id', ''),
      conversationId: _getStr('conversationId', 'conversation_id', ''),
      role: _getStr('role', 'role', 'user'),
      content: _getStr('content', 'content', ''),
      inputTokens: _getInt('inputTokens', 'input_tokens'),
      outputTokens: _getInt('outputTokens', 'output_tokens'),
      modelName: json['modelName']?.toString() ?? json['model_name']?.toString(),
      createdAt: _parseDt(json['createdAt'] ?? json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role,
      'content': content,
      'inputTokens': inputTokens,
      'outputTokens': outputTokens,
      'modelName': modelName,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Message copyWith({
    String? id,
    String? conversationId,
    String? role,
    String? content,
    int? inputTokens,
    int? outputTokens,
    String? modelName,
    DateTime? createdAt,
  }) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      modelName: modelName ?? this.modelName,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() => 'Message($role, ${content.length} chars)';
}
