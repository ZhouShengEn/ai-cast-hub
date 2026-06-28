import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/debug_service.dart';

/// 可拖拽悬浮调试球
class DebugBall extends StatefulWidget {
  final Offset initialPosition;
  const DebugBall({super.key, this.initialPosition = const Offset(-16, 160)});
  @override
  State<DebugBall> createState() => _DebugBallState();
}

class _DebugBallState extends State<DebugBall> {
  final DebugService _debug = DebugService();
  bool _expanded = false;
  int _tabIndex = 0;
  late Offset _position;
  // 面板可缩放，初始尺寸
  Size _panelSize = const Size(360, 520);
  // 面板位置（相对于屏幕，拖拽面板时使用）
  Offset? _panelPosition;

  /// 当前展开的网络请求索引（-1 表示无）
  int _expandedNetworkIdx = -1;

  @override
  void initState() {
    super.initState();
    // 初始位置在屏幕正中间，在 build 中用 MediaQuery 计算后设置
    _position = widget.initialPosition;
    _debug.onLogChanged = () { if (mounted) setState(() {}); };
    _debug.onNetworkChanged = () { if (mounted) setState(() {}); };
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
    final ballSize = 50.0;

    // 首次构建时将悬浮球放在屏幕正中间
    if (_position == widget.initialPosition) {
      _position = Offset(
        (screenSize.width - ballSize) / 2,
        (screenSize.height - ballSize) / 2,
      );
    }

    double ballX = _position.dx >= 0
        ? _position.dx.clamp(0, screenSize.width - ballSize)
        : screenSize.width + _position.dx;
    double ballY = _position.dy.clamp(0, screenSize.height - ballSize - 80);

    return Stack(
      children: [
        if (_expanded)
          Positioned(
            left: _panelPosition?.dx ?? _calcDefaultPanelX(screenSize, ballX, ballSize),
            top: _panelPosition?.dy ?? _calcDefaultPanelY(screenSize, ballY, ballSize),
            child: _buildPanel(),
          ),
        Positioned(
          left: ballX, top: ballY,
          child: GestureDetector(
            onTap: () => setState(() {
              _expanded = !_expanded;
              _expandedNetworkIdx = -1;
              // 展开时重置面板位置（居中显示）
              if (_expanded) {
                _panelPosition = Offset(
                  (screenSize.width - _panelSize.width) / 2,
                  (screenSize.height - _panelSize.height) / 2,
                );
              }
            }),
            onPanUpdate: (d) => setState(() {
              _position = Offset(
                (_position.dx >= 0 ? _position.dx : screenSize.width + _position.dx) + d.delta.dx,
                _position.dy + d.delta.dy,
              );
            }),
            onPanEnd: (_) {
              final midX = screenSize.width / 2;
              setState(() {
                _position = ballX < midX
                    ? Offset(ballX, ballY)
                    : Offset(ballX - screenSize.width, ballY);
              });
            },
            child: Container(
              width: ballSize, height: ballSize,
              decoration: BoxDecoration(
                color: _expanded ? Colors.blue.shade700 : Colors.black87,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 2))],
              ),
              child: Center(
                child: Text(_expanded ? '✕' : '🐞', style: const TextStyle(fontSize: 20)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 计算面板默认 X 位置（基于悬浮球位置）
  double _calcDefaultPanelX(Size screenSize, double ballX, double ballSize) {
    final isLeft = ballX < screenSize.width / 2;
    double panelX = isLeft ? ballX + ballSize + 8 : ballX - _panelSize.width - 8;
    return panelX.clamp(0, screenSize.width - _panelSize.width);
  }

  /// 计算面板默认 Y 位置（基于悬浮球位置）
  double _calcDefaultPanelY(Size screenSize, double ballY, double ballSize) {
    double panelY = (ballY + ballSize / 2 - _panelSize.height / 2)
        .clamp(0, screenSize.height - _panelSize.height - 40);
    return panelY;
  }

  Widget _buildPanel() {
    return GestureDetector(
      // 双指缩放面板大小
      onScaleUpdate: (details) {
        setState(() {
          if (details.pointerCount >= 2) {
            final newWidth = (_panelSize.width * details.scale).clamp(240.0, 600.0);
            final newHeight = (_panelSize.height * details.scale).clamp(300.0, 800.0);
            _panelSize = Size(newWidth, newHeight);
            // 缩放时保持面板中心不变
            final screenSize = MediaQuery.of(context).size;
            _panelPosition = Offset(
              (screenSize.width - _panelSize.width) / 2,
              (screenSize.height - _panelSize.height) / 2,
            );
          } else if (details.pointerCount == 1) {
            // 单指拖动面板
            _panelPosition = Offset(
              (_panelPosition?.dx ?? 0) + details.focalPointDelta.dx,
              (_panelPosition?.dy ?? 0) + details.focalPointDelta.dy,
            );
          }
        });
      },
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: _panelSize.width, height: _panelSize.height,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Container(
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF2D2D2D),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  children: [
                    _tab('Console', 0),
                    _tab('Network', 1),
                    const Spacer(),
                    // 一键复制按钮
                    if (_tabIndex == 0)
                      GestureDetector(
                        onTap: () => _copyConsole(),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(Icons.copy_all, size: 16, color: Colors.grey),
                        ),
                      ),
                    GestureDetector(
                      onTap: () { _debug.clear(); setState(() {}); },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.delete_outline, size: 16, color: Colors.grey),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() { _expanded = false; _expandedNetworkIdx = -1; }),
                      child: const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Icon(Icons.close, size: 16, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _tabIndex == 0 ? _consolePanel() : _networkPanel(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(String text, int idx) {
    final sel = _tabIndex == idx;
    return GestureDetector(
      onTap: () => setState(() { _tabIndex = idx; _expandedNetworkIdx = -1; }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: sel ? Colors.green : Colors.transparent, width: 2)),
        ),
        child: Text(text, style: TextStyle(color: sel ? Colors.green : Colors.grey, fontSize: 13, fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  // ==================== Console ====================

  /// 复制控制台全部日志到剪贴板
  void _copyConsole() {
    final logs = _debug.logs;
    if (logs.isEmpty) return;
    final buffer = StringBuffer();
    for (final e in logs.reversed) {
      buffer.writeln('[${_fmtTime(e.time)}][${_lvlTag(e.level)}] ${e.message}');
    }
    final text = buffer.toString();
    try {
      Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已复制 ${logs.length} 条日志', style: const TextStyle(fontSize: 12)),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            width: 200,
          ),
        );
      }
    } catch (e) {
      debugPrint('[DebugBall] 复制失败: $e');
    }
  }

  Widget _consolePanel() {
    final logs = _debug.logs;
    if (logs.isEmpty) return _empty('暂无日志');
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: logs.length,
            itemBuilder: (_, i) {
              final e = logs[logs.length - 1 - i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(_fmtTime(e.time), style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: 'monospace'), enableInteractiveSelection: true),
                    const SizedBox(width: 4),
                    SelectableText(_lvlTag(e.level), style: TextStyle(color: _lvlColor(e.level), fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.bold), enableInteractiveSelection: true),
                    const SizedBox(width: 4),
                    Expanded(child: SelectableText(e.message, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'), enableInteractiveSelection: true)),
                  ],
                ),
              );
            },
          ),
        ),
        // 一键复制按钮
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            color: Color(0xFF2D2D2D),
            border: Border(top: BorderSide(color: Color(0xFF444444), width: 0.5)),
          ),
          child: GestureDetector(
            onTap: () => _copyConsole(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.copy_all, size: 14, color: Colors.grey),
                SizedBox(width: 4),
                Text('一键复制全部日志', style: TextStyle(color: Colors.grey, fontSize: 11)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ==================== Network ====================
  Widget _networkPanel() {
    final nets = _debug.networks;
    if (nets.isEmpty) return _empty('暂无网络请求');
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: nets.length,
      itemBuilder: (_, i) {
        final idx = nets.length - 1 - i;
        final e = nets[idx];
        final isExpanded = _expandedNetworkIdx == idx;
        final sc = e.status == 'success' ? Colors.green : e.status == 'error' ? Colors.red : Colors.orange;

        return GestureDetector(
          onTap: () => setState(() {
            _expandedNetworkIdx = isExpanded ? -1 : idx;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isExpanded ? const Color(0xFF3A3A3A) : const Color(0xFF2D2D2D),
              borderRadius: BorderRadius.circular(6),
              border: isExpanded ? Border.all(color: Colors.blue.shade700, width: 1) : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 摘要行
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(color: _methodC(e.method), borderRadius: BorderRadius.circular(3)),
                      child: Text(e.method, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    Text(_fmtTime(e.time), style: const TextStyle(color: Colors.grey, fontSize: 9, fontFamily: 'monospace')),
                    const SizedBox(width: 6),
                    Icon(Icons.circle, size: 6, color: sc),
                    const SizedBox(width: 4),
                    Text('${e.durationMs}ms', style: TextStyle(color: sc, fontSize: 10)),
                    if (e.statusCode != null) ...[
                      const SizedBox(width: 6),
                      Text('${e.statusCode}', style: TextStyle(
                        color: e.statusCode! >= 200 && e.statusCode! < 300 ? Colors.green : Colors.red,
                        fontSize: 10, fontWeight: FontWeight.bold,
                      )),
                    ],
                    const Spacer(),
                    Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 14, color: Colors.grey),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _shortUrl(e.url),
                  style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
                  maxLines: isExpanded ? 10 : 1,
                  overflow: isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                ),

                // 展开详情
                if (isExpanded) ...[
                  const SizedBox(height: 8),
                  if (e.requestBody != null) ...[
                    _detailSection('📤 Request Body', e.requestBody, Colors.orange),
                    const SizedBox(height: 6),
                  ],
                  if (e.responseData != null) ...[
                    _detailSection('📥 Response Body', e.responseData, Colors.green),
                    const SizedBox(height: 6),
                  ],
                  if (e.errorMessage != null) ...[
                    _detailSection('❌ Error', e.errorMessage, Colors.red),
                  ],
                  const SizedBox(height: 4),
                  // URL 完整展示
                  _detailSection('🔗 Full URL', e.url, Colors.blue),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailSection(String title, dynamic data, Color color) {
    final text = _pretty(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
            const Spacer(),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已复制 $title', style: const TextStyle(fontSize: 10)), duration: const Duration(seconds: 1)),
                );
              },
              child: const Icon(Icons.copy, size: 12, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text.length > 500 ? '${text.substring(0, 500)}...' : text,
            style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  // ==================== 工具方法 ====================
  Widget _empty(String text) => Center(child: Text(text, style: const TextStyle(color: Colors.grey, fontSize: 12)));

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  String _lvlTag(LogLevel l) { switch (l) { case LogLevel.debug: return 'D'; case LogLevel.info: return 'I'; case LogLevel.warn: return 'W'; case LogLevel.error: return 'E'; } }
  Color _lvlColor(LogLevel l) { switch (l) { case LogLevel.debug: return Colors.blue; case LogLevel.info: return Colors.green; case LogLevel.warn: return Colors.orange; case LogLevel.error: return Colors.red; } }
  Color _methodC(String m) { switch (m) { case 'GET': return Colors.green; case 'POST': return Colors.orange; case 'PUT': return Colors.blue; case 'DELETE': return Colors.red; default: return Colors.grey; } }

  String _pretty(dynamic data) {
    try {
      if (data is String) return data;
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) { return data.toString(); }
  }
  String _shortUrl(String url) => url.replaceAll(RegExp(r'^https?://[^/]+'), '');
}
