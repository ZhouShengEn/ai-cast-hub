import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/constants.dart';
import 'local_storage.dart';

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

  /// 重连最大间隔（指数退避上限）
  static const Duration _maxReconnectDelay = Duration(seconds: 30);

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
  Future<void> connect() async {
    if (_connectionState == WsConnectionState.connected ||
        _connectionState == WsConnectionState.connecting) {
      return;
    }

    _intentionalClose = false;
    _setConnectionState(WsConnectionState.connecting);

    try {
      final uuid = _storage.getDeviceUuid() ?? '';
      final key = _storage.getTransferKey() ?? '';
      final serverBase = _storage.getServerUrl();

      // 从 HTTP URL 推导 WS URL
      final wsUrl = serverBase
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://')
          .replaceFirst('/api/v1', '');
      final uri = Uri.parse('$wsUrl/ws?deviceUuid=$uuid&transferKey=$key');

      _channel = WebSocketChannel.connect(uri);

      await _channel!.ready;

      _setConnectionState(WsConnectionState.connected);
      _reconnectAttempts = 0;

      _startHeartbeat();

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
    } catch (e) {
      _setConnectionState(WsConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  /// 发送 JSON 消息
  void send(Map<String, dynamic> message) {
    if (_connectionState != WsConnectionState.connected || _channel == null) {
      return;
    }
    try {
      _channel!.sink.add(jsonEncode(message));
    } catch (_) {
      // 发送失败，忽略
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
  }

  /// 释放资源
  void dispose() {
    disconnect();
    _connectionStateController.close();
    _messageController.close();
  }

  // ---- 内部方法 ----

  void _setConnectionState(WsConnectionState state) {
    _connectionState = state;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = message['type'] as String?;

      // 处理心跳 pong
      if (type == 'pong') {
        _heartbeatTimeoutTimer?.cancel();
        return;
      }

      // 发送到消息流
      if (!_messageController.isClosed) {
        _messageController.add(message);
      }
    } catch (_) {
      // 解析失败，忽略
    }
  }

  void _onError(dynamic error) {
    _setConnectionState(WsConnectionState.disconnected);
    _maybeReconnect();
  }

  void _onDone() {
    _setConnectionState(WsConnectionState.disconnected);
    _maybeReconnect();
  }

  /// 判断是否应该重连（认证失败不重连）
  void _maybeReconnect() {
    final closeCode = _channel?.closeCode ?? 0;
    // 认证失败（4000-4003）不重连，避免无限循环
    if (closeCode >= 4000 && closeCode <= 4003) {
      _intentionalClose = true;
      return;
    }
    _scheduleReconnect();
  }

  /// 启动心跳
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(AppConstants.wsHeartbeatInterval, (_) {
      send({'type': 'ping'});

      // 设置 pong 超时
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer =
          Timer(AppConstants.wsHeartbeatTimeout - AppConstants.wsHeartbeatInterval, () {
        // pong 超时，重连
        _channel?.sink.close();
      });
    });
  }

  /// 指数退避重连
  void _scheduleReconnect() {
    if (_intentionalClose) return;

    _setConnectionState(WsConnectionState.reconnecting);
    _heartbeatTimer?.cancel();
    _heartbeatTimeoutTimer?.cancel();

    final delay = Duration(
      seconds: min(
        pow(2, _reconnectAttempts).toInt(),
        _maxReconnectDelay.inSeconds,
      ),
    );
    _reconnectAttempts++;

    Future.delayed(delay, () {
      if (_intentionalClose) return;
      connect();
    });
  }
}
