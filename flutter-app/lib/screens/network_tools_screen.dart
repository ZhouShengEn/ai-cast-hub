import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../services/api_client.dart';

/// 网络工具页面 — Ping 测试 + 本机 IP 查询
class NetworkToolsScreen extends StatefulWidget {
  const NetworkToolsScreen({super.key});
  @override
  State<NetworkToolsScreen> createState() => _NetworkToolsScreenState();
}

class _NetworkToolsScreenState extends State<NetworkToolsScreen> {
  final TextEditingController _ipController = TextEditingController(text: '192.168.');
  final List<_PingResult> _results = [];
  bool _pinging = false;
  String _localIp = '获取中...';
  Timer? _pingTimer;
  final _dio = ApiClient.instance.dio;

  @override
  void initState() {
    super.initState();
    _getLocalIp();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _pingTimer?.cancel();
    super.dispose();
  }

  // ==================== 获取本机IP ====================
  Future<void> _getLocalIp() async {
    if (kIsWeb) {
      setState(() => _localIp = '浏览器无法获取，请用真机');
      return;
    }

    try {
      final info = NetworkInfo();
      final wifiIp = await info.getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty) {
        setState(() => _localIp = wifiIp);
      } else {
        setState(() => _localIp = '未连接 WiFi');
      }
    } catch (e) {
      setState(() => _localIp = '获取失败: $e');
    }
  }

  // ==================== Ping ====================
  Future<void> _startPing() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    // 先验证地址格式
    if (!_isValidTarget(ip)) {
      setState(() => _results.add(_PingResult(
        time: DateTime.now(), success: false, ip: ip,
        message: '无效地址', latencyMs: -1,
      )));
      return;
    }

    setState(() {
      _pinging = true;
      _results.clear();
    });

    // 执行 Ping，测试 3000 和 80 端口
    final results = await _doPing(ip);
    if (mounted) {
      setState(() {
        _results.addAll(results);
        _pinging = false;
      });
    }
  }

  /// 执行 Ping：测试 3000、80、443 端口
  Future<List<_PingResult>> _doPing(String ip) async {
    final results = <_PingResult>[];

    for (final entry in [
      {'port': 3000, 'protocol': 'http'},
      {'port': 80,   'protocol': 'http'},
      {'port': 443,  'protocol': 'https'},
    ]) {
      final port = entry['port'] as int;
      final protocol = entry['protocol'] as String;
      final sw = Stopwatch()..start();
      int? statusCode;
      bool connected = false;

      try {
        final response = await _dio.get(
          '$protocol://$ip:$port/',
          options: Options(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
            validateStatus: (status) {
              statusCode = status;
              return true; // 接受任何状态码
            },
          ),
        );
        sw.stop();
        statusCode = response.statusCode;
        connected = true;
      } catch (e) {
        sw.stop();
        // 被 CORS 拦截也能说明端口可达
        // 只有真正的连接超时/无法连接才算不可达
        if (statusCode != null) {
          connected = true;
        } else if (e is DioException) {
          final type = e.type;
          if (type == DioExceptionType.connectionTimeout ||
              type == DioExceptionType.connectionError) {
            connected = false;
          } else {
            // 收到服务器响应但被 CORS/证书/重定向拦截 → 端口可达
            connected = true;
            if (e.response?.statusCode != null) {
              statusCode = e.response!.statusCode;
            }
          }
        }
      }

      results.add(_PingResult(
        time: DateTime.now(),
        success: connected,
        ip: '$ip:$port ($protocol)',
        message: connected
            ? '可达 · ${statusCode ?? "?"} · ${sw.elapsedMilliseconds}ms'
            : '不可达',
        latencyMs: connected ? sw.elapsedMilliseconds : -1,
      ));
    }

    return results;
  }

  bool _isValidTarget(String target) {
    if (target.isEmpty) return false;
    // 简单的域名或 IP 验证
    final host = target.contains('://') ? target.split('://').last.split('/').first : target;
    return host.isNotEmpty && (host.contains('.') || host.contains(':'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网络工具')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 本机 IP
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.phone_iphone, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('本机 IP', style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(_localIp, style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ), overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.refresh, color: theme.colorScheme.onPrimaryContainer),
                    onPressed: _getLocalIp,
                    padding: EdgeInsets.zero,
                  ),
                  IconButton(
                    icon: Icon(Icons.copy, color: theme.colorScheme.onPrimaryContainer, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _localIp));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制到剪贴板')),
                      );
                    },
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Ping 工具
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ping 测试', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('输入 IP 地址，测试是否可达', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ipController,
                          enabled: !_pinging,
                          decoration: const InputDecoration(
                            labelText: 'IP 地址或域名',
                            hintText: '192.168.1.1 或 baidu.com',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.language),
                          ),
                          keyboardType: TextInputType.url,
                          onSubmitted: (_) => _startPing(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _pinging ? null : _startPing,
                          icon: _pinging
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.send),
                          label: const Text('Ping'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _quickBtn('baidu.com'),
                      _quickBtn('192.168.62.65'),
                      _quickBtn('192.168.62.1'),
                      _quickBtn('8.8.8.8'),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Ping 结果
          if (_results.isNotEmpty) ...[
            Row(
              children: [
                Text('Ping 结果', style: theme.textTheme.titleMedium),
                if (_pinging) ...[
                  const SizedBox(width: 8),
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _results.clear()),
                  child: const Text('清除'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._results.map((r) => _buildResultCard(r, theme)),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _quickBtn(String ip) {
    return ActionChip(
      label: Text(ip, style: const TextStyle(fontSize: 12)),
      onPressed: _pinging ? null : () {
        _ipController.text = ip;
        _startPing();
      },
    );
  }

  Widget _buildResultCard(_PingResult r, ThemeData theme) {
    final bg = r.success ? Colors.green.shade50 : Colors.red.shade50;
    final icon = r.success ? Icons.check_circle : Icons.cancel;
    final iconColor = r.success ? Colors.green : Colors.red;

    return Card(
      color: bg,
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: iconColor, size: 24),
        title: Text(r.message, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
        subtitle: Text(
          '${_fmtTime(r.time)} · ${r.ip}',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        trailing: r.latencyMs >= 0
            ? Text('${r.latencyMs}ms', style: TextStyle(color: iconColor, fontWeight: FontWeight.bold))
            : null,
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _PingResult {
  final DateTime time;
  final String ip;
  final bool success;
  final String message;
  final int latencyMs;
  _PingResult({required this.time, required this.ip, required this.success, required this.message, required this.latencyMs});
}
