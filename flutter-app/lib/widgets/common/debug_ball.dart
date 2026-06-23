import 'dart:convert';
import 'package:flutter/material.dart';

import '../../services/debug_service.dart';

/// 可拖拽悬浮调试球
///
/// 点击展开面板：顶部 Tab 切换 Console / Network
/// 长按拖拽移动位置
class DebugBall extends StatefulWidget {
  /// 初始位置（相对于屏幕边缘）
  final Offset initialPosition;

  const DebugBall({super.key, this.initialPosition = const Offset(-16, 160)});

  @override
  State<DebugBall> createState() => _DebugBallState();
}

class _DebugBallState extends State<DebugBall> {
  final DebugService _debug = DebugService();

  /// 面板是否展开
  bool _expanded = false;

  /// 当前 Tab: 0=Console, 1=Network
  int _tabIndex = 0;

  /// 悬浮球位置
  late Offset _position;

  /// 面板大小
  Size _panelSize = const Size(350, 500);

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    _debug.onLogChanged = () {
      if (mounted) setState(() {});
    };
    _debug.onNetworkChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _debug.onLogChanged = null;
    _debug.onNetworkChanged = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    // 计算面板和球的真实位置
    final ballSize = 50.0;
    final isLeft = _position.dx < screenSize.width / 2;

    // 球的屏幕坐标（dx >= 0 表示从左算，< 0 表示从右算）
    double ballX, ballY;
    ballX = _position.dx >= 0
        ? _position.dx.clamp(0, screenSize.width - ballSize)
        : screenSize.width + _position.dx;
    ballY = _position.dy.clamp(0, screenSize.height - ballSize - 80);

    // 面板位置
    double panelX;
    if (isLeft) {
      panelX = ballX + ballSize + 8;
    } else {
      panelX = ballX - _panelSize.width - 8;
    }
    panelX = panelX.clamp(0, screenSize.width - _panelSize.width);
    double panelY = (ballY + ballSize / 2 - _panelSize.height / 2)
        .clamp(0, screenSize.height - _panelSize.height - 40);

    return Stack(
      children: [
        // 展开的面板
        if (_expanded)
          Positioned(
            left: panelX,
            top: panelY,
            child: _buildPanel(),
          ),

        // 悬浮球
        Positioned(
          left: ballX,
          top: ballY,
          child: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            onPanUpdate: (details) {
              setState(() {
                _position = Offset(
                  (_position.dx >= 0 ? _position.dx : screenSize.width + _position.dx) +
                      details.delta.dx,
                  _position.dy + details.delta.dy,
                );
              });
            },
            onPanEnd: (_) {
              // 吸附到屏幕边缘
              setState(() {
                final midX = screenSize.width / 2;
                if (ballX < midX) {
                  _position = Offset(ballX, ballY);
                } else {
                  _position = Offset(ballX - screenSize.width, ballY);
                }
              });
            },
            child: Container(
              width: ballSize,
              height: ballSize,
              decoration: BoxDecoration(
                color: _expanded ? Colors.blue.shade700 : Colors.black87,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  _expanded ? '✕' : '🐞',
                  style: const TextStyle(fontSize: 20),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 调试面板
  Widget _buildPanel() {
    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: _panelSize.width,
        height: _panelSize.height,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            // 标题栏
            Container(
              height: 40,
              decoration: const BoxDecoration(
                color: Color(0xFF2D2D2D),
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  _buildTab('Console', 0),
                  _buildTab('Network', 1),
                  const Spacer(),
                  // 清除按钮
                  GestureDetector(
                    onTap: () {
                      _debug.clear();
                      setState(() {});
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.delete_outline, size: 16, color: Colors.grey),
                    ),
                  ),
                  // 关闭按钮
                  GestureDetector(
                    onTap: () => setState(() => _expanded = false),
                    child: const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.close, size: 16, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
            // 内容区
            Expanded(
              child: _tabIndex == 0 ? _buildConsolePanel() : _buildNetworkPanel(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String text, int index) {
    final selected = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? Colors.green : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: selected ? Colors.green : Colors.grey,
            fontSize: 13,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// Console 日志面板
  Widget _buildConsolePanel() {
    final logs = _debug.logs;
    if (logs.isEmpty) {
      return const Center(child: Text('暂无日志', style: TextStyle(color: Colors.grey, fontSize: 12)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: logs.length,
      itemBuilder: (_, i) {
        final entry = logs[logs.length - 1 - i]; // 最新在前
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${entry.time.hour.toString().padLeft(2, '0')}:${entry.time.minute.toString().padLeft(2, '0')}:${entry.time.second.toString().padLeft(2, '0')}',
                style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 4),
              Text(
                _levelTag(entry.level),
                style: TextStyle(color: _levelColor(entry.level), fontSize: 10, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  entry.message,
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Network 面板
  Widget _buildNetworkPanel() {
    final networks = _debug.networks;
    if (networks.isEmpty) {
      return const Center(child: Text('暂无网络请求', style: TextStyle(color: Colors.grey, fontSize: 12)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: networks.length,
      itemBuilder: (_, i) {
        final entry = networks[networks.length - 1 - i]; // 最新在前
        final statusColor = entry.status == 'success'
            ? Colors.green
            : entry.status == 'error'
                ? Colors.red
                : Colors.orange;

        return GestureDetector(
          onTap: () => _showNetworkDetail(entry),
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: _methodColor(entry.method),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(entry.method, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.circle, size: 6, color: statusColor),
                    const SizedBox(width: 4),
                    Text('${entry.durationMs}ms', style: TextStyle(color: statusColor, fontSize: 10)),
                    if (entry.statusCode != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${entry.statusCode}',
                        style: TextStyle(
                          color: entry.statusCode! >= 200 && entry.statusCode! < 300 ? Colors.green : Colors.red,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _shortUrl(entry.url),
                  style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.errorMessage != null)
                  Text(entry.errorMessage!, style: const TextStyle(color: Colors.red, fontSize: 10)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 请求详情弹窗
  void _showNetworkDetail(debugEntry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _methodColor(debugEntry.method),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(debugEntry.method, style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${debugEntry.statusCode ?? '-'} · ${debugEntry.durationMs}ms',
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _section('URL', debugEntry.url),
              if (debugEntry.requestBody != null)
                _section('Request', _prettyJson(debugEntry.requestBody)),
              if (debugEntry.responseData != null)
                _section('Response', _prettyJson(debugEntry.responseData)),
              if (debugEntry.errorMessage != null)
                _section('Error', debugEntry.errorMessage!, color: Colors.redAccent),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String content, {Color color = Colors.green}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              content,
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  String _prettyJson(dynamic data) {
    try {
      final encoder = const JsonEncoder.withIndent('  ');
      if (data is String) return data;
      return encoder.convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  String _shortUrl(String url) {
    return url.replaceAll(RegExp(r'^https?://[^/]+'), '');
  }

  String _levelTag(LogLevel level) {
    switch (level) {
      case LogLevel.debug: return 'D';
      case LogLevel.info: return 'I';
      case LogLevel.warn: return 'W';
      case LogLevel.error: return 'E';
    }
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.debug: return Colors.blue;
      case LogLevel.info: return Colors.green;
      case LogLevel.warn: return Colors.orange;
      case LogLevel.error: return Colors.red;
    }
  }

  Color _methodColor(String method) {
    switch (method) {
      case 'GET': return Colors.green;
      case 'POST': return Colors.orange;
      case 'PUT': return Colors.blue;
      case 'DELETE': return Colors.red;
      default: return Colors.grey;
    }
  }
}
