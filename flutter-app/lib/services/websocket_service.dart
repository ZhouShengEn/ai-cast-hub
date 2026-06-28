import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/constants.dart';
import 'local_storage.dart';
import 'debug_service.dart';
import 'background_service.dart';

/// WebSocket 连接状态
enum WsConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// WebSocket 通信服务
///
/// 管理到服务器的 WebSocket 长连接，支持自动重连、心跳保活、消息流。
/// 支持调试模式：开启后可查看所有 WS 消息的详细日志。
class WebSocketService {
  static WebSocketService? _instance;

  final LocalStorage _storage = LocalStorage.instance;

  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  StreamSubscription<dynamic>? _subscription;

  /// 连接状态控制器
  final StreamController<WsConnectionState> _connectionStateController =
      StreamController<WsConnectionState>.broadcast();

  /// 消息流控制器
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  WsConnectionState _connectionState = WsConnectionState.disconnected;
  int _reconnectAttempts = 0;
  bool _intentionalClose = false;

  /// 用于等待服务端 connected/error 确认
  Completer<void>? _connectCompleter;

  /// 重连最大间隔（指数退避上限）
  static const Duration _maxReconnectDelay = Duration(seconds: 30);

  /// 调试模式开关
  bool debugMode = false;

  final List<Map<String, dynamic>> _debugLog = [];
  static const int _maxDebugLog = 200;

  void _debugAdd(String dir, String type, [Map<String, dynamic>? payload]) {
    if (!debugMode) return;
    _debugLog.add({'time': DateTime.now().toIso8601String(), 'dir': dir, 'type': type, 'payload': payload});
    if (_debugLog.length > _maxDebugLog) _debugLog.removeAt(0);
    if (payload != null) {
      debugPrint('[WS-Debug] $dir $type payload=${_truncatePayload(payload)}');
    } else {
      debugPrint('[WS-Debug] $dir $type');
    }
  }

  String _truncatePayload(Map<String, dynamic> p) {
    final str = p.toString();
    return str.length > 200 ? '${str.substring(0, 200)}...' : str;
  }

  /// 获取调试日志列表
  List<Map<String, dynamic>> get debugLog => List.unmodifiable(_debugLog);

  WebSocketService._();

  static WebSocketService get instance {
    _instance ??= WebSocketService._();
    return _instance!;
  }

  /// 当前连接状态
  WsConnectionState get connectionState => _connectionState;

  /// 连接状态流
  Stream<WsConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// 消息流（解析后的 JSON Map）
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// 连接到 WebSocket 服务器
  ///
  /// 等待服务端发回 connected 确认消息后才返回。
  /// 如果认证失败（error 消息）或超时，抛出异常。
  Future<void> connect() async {
    if (_connectionState == WsConnectionState.connected) {
      return;
    }

    // 如果正在连接中，等待 5s
    if (_connectionState == WsConnectionState.connecting) {
      if (_connectCompleter != null) {
        try {
          await _connectCompleter!.future.timeout(
            const Duration(seconds: 5),
          );
          return;
        } catch (_) {}
      }
    }

    _intentionalClose = false;
    _setConnectionState(WsConnectionState.connecting);
    _connectCompleter = Completer<void>();

    try {
      final uuid = _storage.getDeviceUuid();
      final key = _storage.getTransferKey();
      final serverBase = _storage.getServerUrl();

      final uuidShort = (uuid?.length ?? 0) >= 8 ? uuid!.substring(0, 8) : (uuid ?? 'null');
      debugPrint('[WS] 准备连接: server=$serverBase, uuid=$uuidShort...');

      if (uuid == null || uuid.isEmpty) {
        throw Exception('设备 UUID 未注册，请先返回首页完成设备注册');
      }
      if (key == null || key.isEmpty) {
        throw Exception('设备 transferKey 未生成，请先返回首页完成设备注册');
      }

      final wsUrl = serverBase
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://')
          .replaceFirst('/api/v1', '');
      final uri = Uri.parse('$wsUrl/ws?deviceUuid=$uuid&transferKey=$key');

      debugPrint('[WS] 连接: $uri');
      _channel = WebSocketChannel.connect(uri);

      await _channel!.ready;
      debugPrint('[WS] TCP 连接已建立，等待服务端确认...');

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      // 等待服务端发回 connected 确认（最多10秒）
      await _connectCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException(
            'WebSocket 服务端确认超时，请检查:\n'
            '1. 服务器是否在 ${_storage.getServerUrl()} 运行\n'
            '2. 设备 UUID 和 transferKey 是否正确',
          );
        },
      );

      debugPrint('[WS] 连接成功');
    } catch (e) {
      debugPrint('[WS] 连接失败: $e');
      _setConnectionState(WsConnectionState.disconnected);
      rethrow;
    }
  }

  /// 发送 JSON 消息
  /// 如果未连接则打印警告并返回 false
  bool send(Map<String, dynamic> message) {
    if (_connectionState != WsConnectionState.connected || _channel == null) {
      debugPrint('[WS] 发送失败: 未连接, 消息=${message['type']}');
      return false;
    }
    try {
      final json = jsonEncode(message);
      _channel!.sink.add(json);
      final type = message['type'] as String? ?? '?';
      _debugAdd('>>>', type, message);
      DebugService().debug('[WS] >> $type ${_truncatePayload(message)}');
      if (!debugMode) debugPrint('[WS] >> $type');
      return true;
    } catch (e) {
      debugPrint('[WS] 发送异常: $e');
      return false;
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _intentionalClose = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimeoutTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _setConnectionState(WsConnectionState.disconnected);
    // 停止后台服务
    if (!kIsWeb) {
      try {
        if (defaultTargetPlatform == TargetPlatform.android) {
          BackgroundService.stopService();
        }
      } catch (_) {
        // 忽略平台检测错误
      }
    }
  }

  /// 释放资源
  void dispose() {
    disconnect();
    _connectionStateController.close();
    _messageController.close();
  }

  // ---- 内部方法 ----

  void _setConnectionState(WsConnectionState state) {
    if (_connectionState == state) return;
    _connectionState = state;
    DebugService().info('[WS] 连接状态: $state');
    debugPrint('[WS] 状态: $state');
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = message['type'] as String?;

      // 心跳 pong
      if (type == 'pong') {
        _heartbeatTimeoutTimer?.cancel();
        _debugAdd('<<<', 'pong');
        return;
      }

      _debugAdd('<<<', type ?? '?', message);
      DebugService().debug('[WS] << $type ${_truncatePayload(message)}');
      if (!debugMode) debugPrint('[WS] << $type');

      // 服务端连接确认
      if (type == 'connected') {
        _setConnectionState(WsConnectionState.connected);
        _reconnectAttempts = 0;
        _startHeartbeat();
        // 启动后台服务保持连接（Android only）
        if (!kIsWeb) {
          try {
            if (defaultTargetPlatform == TargetPlatform.android) {
              BackgroundService.startService().then((success) {
                if (success) {
                  debugPrint('[WS] 后台服务已启动');
                }
              });
            }
          } catch (_) {
            // 忽略平台检测错误
          }
        }
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete();
        }
        return;
      }

      // 服务端认证错误（连接阶段的 error 不转发给业务层）
      if (type == 'error' && _connectionState == WsConnectionState.connecting) {
        final errMsg = message['payload']?['message'] as String? ?? '认证失败';
        debugPrint('[WS] 认证错误: $errMsg');
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.completeError(
            Exception('WebSocket 认证失败: $errMsg\n请返回首页重新注册设备'),
          );
        }
        return;
      }

      // 其他消息发送到业务流
      if (!_messageController.isClosed) {
        _messageController.add(message);
      }
    } catch (e) {
      debugPrint('[WS] 解析消息失败: $e');
    }
  }

  void _onError(dynamic error) {
    debugPrint('[WS] 错误: $error');
    _setConnectionState(WsConnectionState.disconnected);
    _maybeReconnect();
  }

  void _onDone() {
    debugPrint('[WS] 连接关闭, code=${_channel?.closeCode}');
    _setConnectionState(WsConnectionState.disconnected);
    _maybeReconnect();
  }

  /// 判断是否应该重连（认证失败不重连）
  void _maybeReconnect() {
    final closeCode = _channel?.closeCode ?? 0;
    if (closeCode >= 4000 && closeCode <= 4003) {
      debugPrint('[WS] 认证失败(code=$closeCode)，放弃重连');
      _intentionalClose = true;
      if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
        _connectCompleter!.completeError(
          Exception('WebSocket 认证失败(code=$closeCode)，请返回首页重新注册设备'),
        );
      }
      return;
    }
    _scheduleReconnect();
  }

  /// 启动心跳
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(AppConstants.wsHeartbeatInterval, (_) {
      send({'type': 'ping'});

      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = Timer(
        AppConstants.wsHeartbeatTimeout - AppConstants.wsHeartbeatInterval,
        () {
          _channel?.sink.close();
        },
      );
    });
  }

  /// 指数退避重连
  void _scheduleReconnect() {
    if (_intentionalClose) return;

    _setConnectionState(WsConnectionState.reconnecting);
    _heartbeatTimer?.cancel();
    _heartbeatTimeoutTimer?.cancel();

    final delay = Duration(
      seconds: min(pow(2, _reconnectAttempts).toInt(), _maxReconnectDelay.inSeconds),
    );
    _reconnectAttempts++;

    Future.delayed(delay, () {
      if (_intentionalClose) return;
      connect();
    });
  }
}
