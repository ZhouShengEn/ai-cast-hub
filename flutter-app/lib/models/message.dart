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
    return Message(
      id: json['id'] as String? ?? '',
      conversationId: json['conversationId'] as String? ?? '',
      role: json['role'] as String? ?? 'user',
      content: json['content'] as String? ?? '',
      inputTokens: json['inputTokens'] as int?,
      outputTokens: json['outputTokens'] as int?,
      modelName: json['modelName'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
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
