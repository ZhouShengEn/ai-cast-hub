import 'dart:collection';
import 'package:flutter/foundation.dart';

/// 调试日志/网络监控服务（单例）
class DebugService {
  static final DebugService _instance = DebugService._();
  factory DebugService() => _instance;
  DebugService._();

  /// 日志列表（最多保留 200 条）
  final Queue<_LogEntry> _logs = Queue<_LogEntry>();
  final int _maxLogs = 200;

  /// 网络请求列表（最多保留 100 条）
  final Queue<_NetworkEntry> _networks = Queue<_NetworkEntry>();
  final int _maxNetworks = 100;

  /// 是否启用（使用 ValueNotifier 实现响应式）
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// 日志变更回调
  void Function()? onLogChanged;

  /// 网络变更回调
  void Function()? onNetworkChanged;

  // ============ 日志 ============

  void log(String message, {LogLevel level = LogLevel.info}) {
    if (!enabled.value) return;
    _addLog(level, message);
  }

  void debug(String message) => log(message, level: LogLevel.debug);
  void info(String message) => log(message, level: LogLevel.info);
  void warn(String message) => log(message, level: LogLevel.warn);
  void error(String message) => log(message, level: LogLevel.error);

  void _addLog(LogLevel level, String message) {
    if (_logs.length >= _maxLogs) _logs.removeFirst();
    _logs.add(_LogEntry(
      time: DateTime.now(),
      level: level,
      message: message,
    ));
    onLogChanged?.call();
  }

  List<_LogEntry> get logs => _logs.toList();

  // ============ 网络 ============

  void networkRequest(String method, String url, dynamic body, Map<String, dynamic>? headers) {
    if (!enabled.value) return;
    if (_networks.length >= _maxNetworks) _networks.removeFirst();
    _networks.add(_NetworkEntry(
      time: DateTime.now(),
      method: method,
      url: url,
      requestBody: body,
      requestHeaders: headers,
      status: 'pending',
    ));
    onNetworkChanged?.call();
  }

  void networkResponse(String url, int statusCode, dynamic data) {
    if (!enabled.value) return;
    // 找到最近一条匹配的 pending 请求
    for (int i = _networks.length - 1; i >= 0; i--) {
      if (_networks.elementAt(i).url == url && _networks.elementAt(i).status == 'pending') {
        _networks.elementAt(i).statusCode = statusCode;
        _networks.elementAt(i).responseData = data;
        _networks.elementAt(i).status = statusCode >= 200 && statusCode < 300 ? 'success' : 'error';
        _networks.elementAt(i).responseTime = DateTime.now();
        onNetworkChanged?.call();
        break;
      }
    }
  }

  void networkError(String url, String error) {
    if (!enabled.value) return;
    for (int i = _networks.length - 1; i >= 0; i--) {
      if (_networks.elementAt(i).url == url && _networks.elementAt(i).status == 'pending') {
        _networks.elementAt(i).status = 'error';
        _networks.elementAt(i).errorMessage = error;
        _networks.elementAt(i).responseTime = DateTime.now();
        onNetworkChanged?.call();
        break;
      }
    }
  }

  List<_NetworkEntry> get networks => _networks.toList();

  /// 清除所有数据
  void clear() {
    _logs.clear();
    _networks.clear();
    onLogChanged?.call();
    onNetworkChanged?.call();
  }
}

enum LogLevel { debug, info, warn, error }

class _LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;
  _LogEntry({required this.time, required this.level, required this.message});
}

class _NetworkEntry {
  final DateTime time;
  final String method;
  final String url;
  final dynamic requestBody;
  final Map<String, dynamic>? requestHeaders;
  DateTime? responseTime;
  int? statusCode;
  dynamic responseData;
  String status; // pending | success | error
  String? errorMessage;

  _NetworkEntry({
    required this.time,
    required this.method,
    required this.url,
    this.requestBody,
    this.requestHeaders,
    this.status = 'pending',
    this.statusCode,
    this.responseData,
    this.responseTime,
    this.errorMessage,
  });

  int get durationMs {
    if (responseTime == null) return 0;
    return responseTime!.difference(time).inMilliseconds;
  }
}
