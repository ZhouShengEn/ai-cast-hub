import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../utils/constants.dart';
import 'api_client.dart';
import '../models/conversation.dart';
import '../models/message.dart';

/// AI 对话服务
///
/// 管理对话列表、消息收发、SSE 流式响应。
class ChatService {
  final ApiClient _client = ApiClient.instance;

  /// 获取对话列表
  Future<List<Conversation>> getConversations() async {
    final data = await _client.get('/chat/conversations');
    return (data as List<dynamic>)
        .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 获取指定对话的消息列表
  Future<List<Message>> getMessages(String conversationId) async {
    final data = await _client.get('/chat/conversation/$conversationId/messages');
    return (data as List<dynamic>)
        .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 创建新对话并发送首条消息
  /// 返回创建的对话 ID
  Future<String> createConversation(String model) async {
    final data = await _client.post('/chat/send', data: {
      'model': model,
      'content': '你好',
      'isNew': true,
    });
    final result = Map<String, dynamic>.from(data as Map);
    return result['conversationId'] as String? ?? '';
  }

  /// 发送消息并返回 SSE 流式 Token 流
  /// [conversationId] 对话 ID
  /// [content] 消息内容
  /// [model] 模型标识（如 "openai/gpt-4o"）
  Stream<String> sendMessage(
    String conversationId,
    String content,
    String model,
  ) async* {
    try {
      final dio = _client.dio;
      final response = await dio.post(
        '/chat/send',
        data: {
          'conversationId': conversationId,
          'content': content,
          'model': model,
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'text/event-stream',
          },
        ),
      );

      final stream = response.data.stream as Stream<List<int>>;
      final buffer = StringBuffer();
      bool isDone = false;

      await for (final chunk in stream) {
        if (isDone) break;

        final text = utf8.decode(chunk, allowMalformed: true);
        buffer.write(text);

        // 按行分割 SSE 格式
        final lines = buffer.toString().split('\n');
        buffer.clear();

        for (int i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.isEmpty) continue;

          // 检查 [DONE] 标记
          if (line.startsWith('data: [DONE]')) {
            isDone = true;
            break;
          }

          // 解析 data: {...} 格式
          if (line.startsWith('data: ')) {
            final jsonStr = line.substring(6);
            try {
              final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
              final token = parsed['token'] as String?;
              if (token != null && token.isNotEmpty) {
                yield token;
              }
            } catch (_) {
              // JSON 解析失败，可能是被截断的不完整数据，放回 buffer
              buffer.write('$line\n');
            }
          }
        }
      }
    } on DioException catch (e) {
      if (e.type != DioExceptionType.cancel) {
        throw Exception('SSE 连接失败: ${e.message}');
      }
    }
  }

  /// 删除对话
  Future<void> deleteConversation(String conversationId) async {
    await _client.delete('/chat/conversation/$conversationId');
  }
}
