import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'api_client.dart';
import '../models/conversation.dart';
import '../models/message.dart';

/// AI 对话服务
///
/// 管理对话列表、消息收发、SSE 流式响应。
class ChatService {
  final ApiClient _client = ApiClient.instance;

  /// 获取对话列表
  /// 服务端返回 { code:0, data:{ list:[...], total:N }, message:"ok" }
  /// ApiClient.get() 已解包为 body['data'] → { list, total }
  Future<List<Conversation>> getConversations() async {
    final data = await _client.get('/chat/conversations');
    // data 是 { list: [...], total: N, ... }
    final map = Map<String, dynamic>.from(data as Map);
    final list = map['list'] as List<dynamic>? ?? [];
    return list
        .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 获取指定对话的消息列表
  /// 服务端返回 { code:0, data:{ messages:[...] }, message:"ok" }
  /// ApiClient.get() 已解包为 body['data'] → { messages }
  Future<List<Message>> getMessages(String conversationId) async {
    final data = await _client.get('/chat/conversation/$conversationId/messages');
    // data 是 { messages: [...] }
    final map = Map<String, dynamic>.from(data as Map);
    final list = map['messages'] as List<dynamic>? ?? [];
    return list
        .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 创建新空对话（不发送消息）
  /// 返回创建的对话 ID
  Future<String> createConversation(String model) async {
    final data = await _client.post('/chat/conversations', data: {
      'model': model,
    });
    final result = Map<String, dynamic>.from(data as Map);
    return result['id']?.toString() ?? '';
  }

  /// 发送消息并返回 SSE 流式 Token 流
  /// [conversationId] 对话 ID
  /// [content] 消息内容
  /// [model] 模型标识（如 "openai:gpt-4o"）
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

      final rawStream = response.data.stream as Stream<List<int>>;
      // 使用 UTF-8 流式解码器，正确处理多字节字符边界
      final stringStream = rawStream.transform(utf8.decoder);
      final buffer = StringBuffer();
      bool isDone = false;

      await for (final text in stringStream) {
        if (isDone) break;

        buffer.write(text);
        final fullText = buffer.toString();

        // 找到最后一个换行符，拆分完整行和不完整尾部
        final lastNewline = fullText.lastIndexOf('\n');
        String completeLines;
        String incompleteTail;

        if (lastNewline >= 0) {
          completeLines = fullText.substring(0, lastNewline + 1);
          incompleteTail = fullText.substring(lastNewline + 1);
        } else {
          completeLines = '';
          incompleteTail = fullText;
        }

        // 只保留不完整尾部，等待下个 chunk 拼接
        buffer.clear();
        buffer.write(incompleteTail);

        // 逐行处理完整数据
        final lines = completeLines.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;

          // 检查 [DONE] 标记
          if (trimmed.startsWith('data: [DONE]')) {
            isDone = true;
            break;
          }

          // 解析 data: {...} 格式
          if (trimmed.startsWith('data: ')) {
            final jsonStr = trimmed.substring(6);
            try {
              final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;

              // 处理错误事件
              if (parsed['type'] == 'error') {
                throw Exception(parsed['error'] ?? '服务端错误');
              }

              // 提取 token
              final token = parsed['token'] as String?;
              if (token != null && token.isNotEmpty) {
                yield token;
              }
            } catch (e) {
              // JSON 解析失败：可能是被截断的不完整数据
              // 放回 buffer（不包含已解析完的部分）
              if (e is Exception && e.toString().contains('服务端错误')) {
                rethrow;
              }
              // 不完整的行放回 buffer 等待更多数据
              buffer.clear();
              buffer.write('$trimmed\n$incompleteTail');
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
