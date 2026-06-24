import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../utils/model_config.dart';
import 'local_storage.dart';

/// 本地 AI 服务 — 不经过服务端，直接从 App 调用大模型 API
///
/// 使用 OpenAI 兼容的 Chat Completions 接口 + SSE 流式响应。
class LocalAIService {
  final LocalStorage _storage = LocalStorage.instance;
  Dio? _dio;
  CancelToken? _cancelToken;

  Dio get _client {
    _dio ??= Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      headers: {'Content-Type': 'application/json'},
    ));
    return _dio!;
  }

  /// 获取本地存储的 API Key
  String? _getApiKey(String provider) {
    final keys = _storage.getApiKeys();
    for (final k in keys) {
      if (k['provider'] == provider) return k['key'];
    }
    return null;
  }

  /// 发送消息并返回 SSE 流式 Token 流
  ///
  /// [model] 格式: "openai:gpt-4o"
  /// [messages] 消息列表 [{role, content}]
  Stream<String> sendMessage(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    final parsed = ModelConfig.parseModelId(model);
    final providerKey = parsed.provider;
    final modelName = parsed.model;

    // 检查提供商是否支持本地直连
    final provider = ModelConfig.getProvider(providerKey);
    if (provider == null || !provider.localSupported || provider.endpoint == null) {
      yield* _errorStream('「${provider?.displayName ?? providerKey}」不支持本地直连，请切换到服务端模式');
      return;
    }

    // 获取 API Key
    final apiKey = _getApiKey(providerKey);
    if (apiKey == null || apiKey.isEmpty) {
      yield* _errorStream('未配置「${provider.displayName}」的 API Key，请在设置 → 模型配置中填写');
      return;
    }

    final url = '${provider.endpoint}/chat/completions';

    // 创建取消令牌
    _cancelToken?.cancel();
    _cancelToken = CancelToken();

    Response<ResponseBody>? response;
    try {
      response = await _client.post(
        url,
        data: {
          'model': modelName,
          'messages': messages,
          'stream': true,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
          // 接受所有状态码，手动处理错误
          validateStatus: (status) => true,
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      yield* _errorStream(_extractDioError(e));
      return;
    }

    // 检查 HTTP 错误
    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 400) {
      final errorBody = await _readResponseBody(response.data!);
      final msg = _parseApiError(errorBody, statusCode);
      yield* _errorStream(msg);
      return;
    }

    // 处理 SSE 流
    try {
      // Web 端返回 Stream<Uint8List>，用 asyncExpand + List<int>.from 兼容解码
      final rawStream = response.data!.stream;
      final stringStream = rawStream.asyncExpand((chunk) {
        final str = utf8.decode(List<int>.from(chunk), allowMalformed: true);
        return Stream.value(str);
      });
      final buffer = StringBuffer();

      await for (final text in stringStream) {
        buffer.write(text);
        final fullText = buffer.toString();

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

        buffer.clear();
        buffer.write(incompleteTail);

        final lines = completeLines.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          if (trimmed == 'data: [DONE]') return;

          if (trimmed.startsWith('data: ')) {
            final jsonStr = trimmed.substring(6);
            try {
              final chunk = jsonDecode(jsonStr) as Map<String, dynamic>;

              // 检查流式错误
              if (chunk.containsKey('error')) {
                final error = chunk['error'];
                final msg = error is Map
                    ? (error['message'] ?? '流式响应错误')
                    : error.toString();
                yield* _errorStream(msg.toString());
                return;
              }

              final choices = chunk['choices'] as List<dynamic>?;
              if (choices != null && choices.isNotEmpty) {
                final delta = choices[0]['delta'] as Map<String, dynamic>?;
                final content = delta?['content'] as String?;
                if (content != null && content.isNotEmpty) {
                  yield content;
                }
              }
            } catch (_) {
              // JSON 不完整，放回 buffer
              buffer.clear();
              buffer.write('$trimmed\n$incompleteTail');
            }
          }
        }
      }
    } on DioException catch (e) {
      if (e.type != DioExceptionType.cancel) {
        yield* _errorStream(_extractDioError(e));
      }
    }
  }

  /// 读取 ResponseBody 为字符串
  Future<String> _readResponseBody(ResponseBody body) async {
    try {
      final bytes = await body.stream.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return utf8.decode(bytes);
    } catch (_) {
      return '';
    }
  }

  /// 解析 API 错误响应
  String _parseApiError(String body, int statusCode) {
    if (body.isEmpty) return 'API 调用失败 (HTTP $statusCode)';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      if (error is Map) {
        return '${error['message'] ?? 'API 调用失败'} (HTTP $statusCode)';
      }
      if (error is String) return '$error (HTTP $statusCode)';
      return '$body (HTTP $statusCode)';
    } catch (_) {
      return 'API 调用失败 (HTTP $statusCode)';
    }
  }

  /// 从 DioException 提取错误信息
  String _extractDioError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '连接超时，请检查网络或代理设置';
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return '响应超时，请稍后重试';
    }
    if (e.type == DioExceptionType.connectionError) {
      if (kIsWeb) {
        return '网络连接失败 — 浏览器可能因 CORS 策略阻止了请求，请尝试在桌面/移动端运行或配置代理';
      }
      return '网络连接失败，请检查网络或 API 地址是否正确';
    }
    return '请求失败: ${e.message}';
  }

  /// 生成错误流（单条错误消息）
  Stream<String> _errorStream(String message) async* {
    // 使用特殊前缀标记错误，由 chat_provider 识别
    yield '\x00ERROR:$message';
  }

  /// 取消当前流式响应
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }
}
