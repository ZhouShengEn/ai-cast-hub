import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_storage.dart';

/// HTTP 接口调试工具（App 端）
///
/// 与 PC Web 端能力保持一致：请求配置 / 发送 / 一键重发 / 请求记录 / 响应展示。
/// 记录持久化到 App 本地数据库（sqflite，无 sqflite 环境降级为 SharedPreferences），
/// 重装 App 后数据清空，不做云端同步。
class HttpToolScreen extends StatefulWidget {
  const HttpToolScreen({super.key});

  @override
  State<HttpToolScreen> createState() => _HttpToolScreenState();
}

class _HttpToolScreenState extends State<HttpToolScreen> {
  /// 与 PC 端保持一致的常量
  static const List<String> _methods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];
  static const List<String> _commonHeaders = [
    'Accept',
    'Authorization',
    'Cache-Control',
    'Content-Type',
    'X-Device-UUID',
    'X-Transfer-Key',
    'X-Requested-With',
  ];
  static const int _defaultTimeoutSec = 10;

  /// 裸 Dio 实例：不加任何拦截器，保证看到「最原始」的响应（含非 0 业务码与 4xx/5xx）
  final Dio _dio = Dio();

  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _timeoutCtrl =
      TextEditingController(text: '$_defaultTimeoutSec');
  final TextEditingController _bodyCtrl = TextEditingController();

  final List<_HeaderRow> _headerRows = [_HeaderRow()];

  String _method = 'GET';
  bool _sending = false;
  bool _bodyExpanded = true;
  bool _headersExpanded = false;

  _HttpResponse? _response;
  List<_HttpRecord> _records = [];
  String? _activeRecordId;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = '$_serverOrigin/api/v1/health';
    _loadRecords();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _timeoutCtrl.dispose();
    _bodyCtrl.dispose();
    for (final row in _headerRows) {
      row.dispose();
    }
    super.dispose();
  }

  // ============================================================
  // 基础工具
  // ============================================================

  /// 服务端 Origin（去掉 /api/v1 前缀），用于给相对地址补全
  String get _serverOrigin {
    final uri = Uri.tryParse(LocalStorage.instance.getServerUrl());
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      final port = uri.hasPort ? ':${uri.port}' : '';
      return '${uri.scheme}://${uri.host}$port';
    }
    return 'http://localhost:3000';
  }

  ThemeData get _theme => Theme.of(context);

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade600 : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  bool get _bodyDisabled => _method == 'GET' || _method == 'HEAD';

  String _prettyBody(dynamic data) {
    if (data == null) return '';
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.isEmpty) return '';
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
      } catch (_) {
        return data;
      }
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  bool _isJsonText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return false;
    try {
      jsonDecode(trimmed);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Color _statusColor(int? code) {
    if (code == null) return Colors.red;
    return (code >= 200 && code < 400) ? Colors.green.shade600 : Colors.red.shade600;
  }

  Color _methodColor(String m) {
    switch (m.toUpperCase()) {
      case 'GET':
        return Colors.green.shade600;
      case 'POST':
        return Colors.blue.shade600;
      case 'PUT':
        return Colors.orange.shade700;
      case 'DELETE':
        return Colors.red.shade600;
      case 'PATCH':
        return Colors.purple.shade600;
      default:
        return Colors.grey.shade600;
    }
  }

  // ============================================================
  // Headers 行操作
  // ============================================================

  void _addHeaderRow([String key = '', String value = '']) {
    setState(() => _headerRows.add(_HeaderRow(k: key, v: value)));
  }

  void _removeHeaderRow(int index) {
    setState(() {
      _headerRows.removeAt(index).dispose();
      if (_headerRows.isEmpty) _headerRows.add(_HeaderRow());
    });
  }

  /// 快速填入本机设备认证头（与 ApiClient 拦截器注入规则一致）
  void _addAuthHeaders() {
    final storage = LocalStorage.instance;
    final uuid = storage.getDeviceUuid();
    final key = storage.getTransferKey();
    if ((uuid == null || uuid.isEmpty) && (key == null || key.isEmpty)) {
      _toast('本机尚未注册设备（无 deviceUuid / transferKey）');
      return;
    }
    _upsertHeader('X-Device-UUID', uuid ?? '');
    _upsertHeader('X-Transfer-Key', key ?? '');
    _toast('已填入设备认证请求头');
  }

  /// 常见请求头的推荐取值
  String _defaultHeaderValue(String key) {
    switch (key.toLowerCase()) {
      case 'content-type':
        return 'application/json';
      case 'accept':
        return 'application/json';
      case 'authorization':
        return 'Bearer ';
      case 'cache-control':
        return 'no-cache';
      default:
        return '';
    }
  }

  void _upsertHeader(String key, String value) {
    _HeaderRow? found;
    for (final row in _headerRows) {
      if (row.key.text.trim().toLowerCase() == key.toLowerCase()) {
        found = row;
        break;
      }
    }
    if (found != null) {
      found.value.text = value;
      return;
    }
    for (final row in _headerRows) {
      if (row.key.text.trim().isEmpty) {
        row.key.text = key;
        row.value.text = value;
        setState(() {});
        return;
      }
    }
    _addHeaderRow(key, value);
  }

  // ============================================================
  // 发送请求
  // ============================================================

  Future<void> _send({String? updateId}) async {
    if (_sending) return;

    final target = _urlCtrl.text.trim();
    if (target.isEmpty) {
      _toast('请先填写请求地址 URL');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final timeoutSec = int.tryParse(_timeoutCtrl.text.trim()) ?? _defaultTimeoutSec;
    final safeTimeout = timeoutSec <= 0 ? _defaultTimeoutSec : timeoutSec;

    // 收集请求头
    final headers = <String, String>{};
    for (final row in _headerRows) {
      final k = row.key.text.trim();
      if (k.isNotEmpty) headers[k] = row.value.text;
    }

    setState(() {
      _sending = true;
      _response = null;
    });

    final stopwatch = Stopwatch()..start();
    _HttpResponse result;
    try {
      final res = await _dio.request(
        target,
        data: _buildRequestBody(),
        options: Options(
          method: _method,
          headers: headers,
          connectTimeout: Duration(seconds: safeTimeout),
          receiveTimeout: Duration(seconds: safeTimeout),
          sendTimeout: Duration(seconds: safeTimeout),
          validateStatus: (_) => true,
        ),
      );
      stopwatch.stop();
      final body = _prettyBody(res.data);
      final responseHeaders = <Map<String, String>>[];
      res.headers.forEach((k, v) {
        responseHeaders.add({'key': k, 'value': v.join(', ')});
      });
      result = _HttpResponse(
        statusCode: res.statusCode,
        statusText: res.statusMessage ?? '',
        durationMs: stopwatch.elapsedMilliseconds,
        headers: responseHeaders,
        body: body,
        isJson: _isJsonText(body),
      );
    } on DioException catch (e) {
      stopwatch.stop();
      result = _HttpResponse(
        statusCode: e.response?.statusCode,
        statusText: '',
        durationMs: stopwatch.elapsedMilliseconds,
        headers: const [],
        body: '',
        isJson: false,
        error: _friendlyError(e, safeTimeout),
      );
    } catch (e) {
      stopwatch.stop();
      result = _HttpResponse(
        statusCode: null,
        statusText: '',
        durationMs: stopwatch.elapsedMilliseconds,
        headers: const [],
        body: '',
        isJson: false,
        error: '请求失败: $e',
      );
    }

    if (!mounted) return;
    await _saveRecord(
      updateId: updateId,
      displayName: _nameCtrl.text.trim().isEmpty
          ? _defaultName(_method, target)
          : _nameCtrl.text.trim(),
      target: target,
      timeoutSec: safeTimeout,
      result: result,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _response = result;
      _bodyExpanded = true;
    });

    if (result.error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error!), backgroundColor: Colors.red.shade600),
      );
    } else if ((result.statusCode ?? 0) >= 400) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('请求完成，服务端返回 ${result.statusCode}'),
          backgroundColor: Colors.orange.shade700,
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text('请求成功（${result.statusCode}，${result.durationMs}ms）')),
      );
    }
  }

  /// 一键重发：优先复用当前选中记录的全部参数，其次复用当前表单
  Future<void> _resend() async {
    if (_sending) return;
    final rec = _activeRecord;
    if (rec != null) {
      _applyRecord(rec, keepResponse: true);
      await _send(updateId: rec.id);
      return;
    }
    if (_urlCtrl.text.trim().isEmpty) {
      _toast('请先填写请求地址 URL');
      return;
    }
    await _send();
  }

  dynamic _buildRequestBody() {
    if (_bodyDisabled) return null;
    final text = _bodyCtrl.text.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  String _defaultName(String method, String target) {
    final uri = Uri.tryParse(target);
    final path = (uri != null && uri.path.isNotEmpty) ? uri.path : target;
    return '$method $path';
  }

  String _friendlyError(DioException e, int timeoutSec) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '请求超时：超过 $timeoutSec 秒未收到响应';
      case DioExceptionType.connectionError:
        return '网络错误：无法连接到目标地址（请检查地址是否正确、服务是否已启动）';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badCertificate:
        return 'HTTPS 证书校验失败';
      default:
        return e.message ?? '请求失败';
    }
  }

  // ============================================================
  // 记录读写（本地数据库）
  // ============================================================

  Future<void> _loadRecords() async {
    try {
      final rows = await LocalStorage.instance.getHttpRecords();
      if (!mounted) return;
      setState(() {
        _records = rows.map(_HttpRecord.fromMap).toList();
      });
    } catch (e) {
      _toast('读取请求记录失败: $e', error: true);
    }
  }

  Future<void> _saveRecord({
    required String? updateId,
    required String displayName,
    required String target,
    required int timeoutSec,
    required _HttpResponse result,
  }) async {
    final id = updateId ?? _newId();
    final record = _HttpRecord(
      id: id,
      name: displayName,
      method: _method,
      url: target,
      timeoutSec: timeoutSec,
      headers: _headerRows
          .map((row) => {'key': row.key.text, 'value': row.value.text})
          .toList(),
      body: _bodyCtrl.text,
      statusCode: result.statusCode,
      durationMs: result.durationMs,
      responseHeaders: result.headers,
      responseBody: result.body,
      isJson: result.isJson,
      error: result.error,
      createdAt: DateTime.now(),
    );

    try {
      await LocalStorage.instance.saveHttpRecord(record.toMap());
    } catch (e) {
      _toast('保存请求记录失败: $e', error: true);
    }

    if (!mounted) return;
    setState(() {
      _activeRecordId = record.id;
      _records = [record, ..._records.where((r) => r.id != record.id)];
      if (_records.length > LocalStorage.httpRecordsLimit) {
        _records = _records.sublist(0, LocalStorage.httpRecordsLimit);
      }
    });
  }

  String _newId() {
    final rand = Random().nextInt(0xFFFFFF).toRadixString(36);
    return 'req_${DateTime.now().microsecondsSinceEpoch}_$rand';
  }

  _HttpRecord? get _activeRecord {
    if (_activeRecordId == null) return null;
    for (final r in _records) {
      if (r.id == _activeRecordId) return r;
    }
    return null;
  }

  /// 点击历史记录：回填全部配置并展示上次响应
  void _applyRecord(_HttpRecord rec, {bool keepResponse = false}) {
    setState(() {
      _nameCtrl.text = rec.name;
      _method = rec.method;
      _urlCtrl.text = rec.url;
      _timeoutCtrl.text = '${rec.timeoutSec}';
      _bodyCtrl.text = rec.body;

      for (final row in _headerRows) {
        row.dispose();
      }
      _headerRows.clear();
      if (rec.headers.isEmpty) {
        _headerRows.add(_HeaderRow());
      } else {
        for (final h in rec.headers) {
          _headerRows.add(_HeaderRow(k: h['key'] ?? '', v: h['value'] ?? ''));
        }
      }

      _activeRecordId = rec.id;
      if (!keepResponse) {
        _response = _HttpResponse(
          statusCode: rec.statusCode,
          statusText: '',
          durationMs: rec.durationMs,
          headers: rec.responseHeaders,
          body: rec.responseBody,
          isJson: rec.isJson,
          error: rec.error,
        );
      }
      _headersExpanded = false;
      _bodyExpanded = true;
    });
  }

  Future<void> _deleteRecord(String id) async {
    try {
      await LocalStorage.instance.deleteHttpRecord(id);
    } catch (e) {
      _toast('删除失败: $e', error: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _records = _records.where((r) => r.id != id).toList();
      if (_activeRecordId == id) _activeRecordId = null;
    });
  }

  Future<void> _clearAllRecords() async {
    if (_records.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空请求记录'),
        content: Text('确认清空全部 ${_records.length} 条请求记录？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await LocalStorage.instance.clearHttpRecords();
    } catch (e) {
      _toast('清空失败: $e', error: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _records = [];
      _activeRecordId = null;
    });
    _toast('请求记录已清空');
  }

  // ============================================================
  // 长文本缩放查看
  // ============================================================

  void _openFullscreenText(String title, String text) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenTextViewer(title: title, text: text),
      ),
    );
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    return Scaffold(
      appBar: AppBar(title: const Text('HTTP 接口调试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildRequestCard(theme),
          const SizedBox(height: 16),
          _buildResponseCard(theme),
          const SizedBox(height: 16),
          _buildRecordsCard(theme),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ---- 请求配置 ----
  Widget _buildRequestCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('请求配置', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),

            TextField(
              controller: _nameCtrl,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: '请求名称（留空自动生成）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),

            // 方法 + URL
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 108,
                  child: DropdownButtonFormField<String>(
                    value: _method,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '方法',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    ),
                    items: _methods
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(
                                m,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: _methodColor(m),
                                ),
                              ),
                            ))
                        .toList(),
                    onChanged: _sending
                        ? null
                        : (v) => setState(() => _method = v ?? 'GET'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    enabled: !_sending,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: '请求地址 URL',
                      hintText: 'http://host:3000/api/v1/health',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('/api/v1/health', style: TextStyle(fontSize: 11)),
                  onPressed: _sending
                      ? null
                      : () => _urlCtrl.text = '$_serverOrigin/api/v1/health',
                ),
                ActionChip(
                  label: const Text('/api/v1/server/info', style: TextStyle(fontSize: 11)),
                  onPressed: _sending
                      ? null
                      : () => _urlCtrl.text = '$_serverOrigin/api/v1/server/info',
                ),
                ActionChip(
                  avatar: const Icon(Icons.link_off, size: 14),
                  label: const Text('清空', style: TextStyle(fontSize: 11)),
                  onPressed: _sending ? null : () => _urlCtrl.clear(),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 超时时间
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _timeoutCtrl,
                    enabled: !_sending,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '超时时间（秒）',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: '默认 10 秒',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Headers
            Row(
              children: [
                Text('请求头 Headers', style: theme.textTheme.bodyMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _sending ? null : _addAuthHeaders,
                  icon: const Icon(Icons.key, size: 16),
                  label: const Text('认证头', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                ),
                // 新增请求头：可选空行自定义，也可直接选常见请求头
                PopupMenuButton<String>(
                  tooltip: '新增请求头',
                  enabled: !_sending,
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value.isEmpty) {
                      _addHeaderRow();
                    } else {
                      _upsertHeader(value, _defaultHeaderValue(value));
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: '',
                      height: 38,
                      child: Text('自定义（空行）', style: TextStyle(fontSize: 12)),
                    ),
                    const PopupMenuDivider(),
                    ..._commonHeaders.map(
                      (h) => PopupMenuItem(
                        value: h,
                        height: 38,
                        child: Text(
                          h,
                          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, size: 16),
                        SizedBox(width: 4),
                        Text('新增', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            ...List.generate(_headerRows.length, (i) => _buildHeaderRow(i)),
            const SizedBox(height: 16),

            // Body
            Row(
              children: [
                Text('请求体 Body', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                if (_bodyDisabled)
                  Text(
                    '$_method 请求不发送 Body',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _bodyCtrl,
              enabled: !_sending,
              maxLines: 8,
              minLines: 4,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.5),
              decoration: const InputDecoration(
                hintText: '{"key": "value"}',
                border: OutlineInputBorder(),
                isDense: true,
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sending ? null : () => _send(),
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send),
                    label: Text(_sending ? '请求中…' : '发送请求'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _sending ? null : _resend,
                  icon: const Icon(Icons.replay),
                  label: const Text('一键重发'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderRow(int index) {
    final row = _headerRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: TextField(
              controller: row.key,
              enabled: !_sending,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'Header 名称',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 5,
            child: TextField(
              controller: row.value,
              enabled: !_sending,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: '值',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: Colors.grey,
            tooltip: '删除该行',
            onPressed: _sending ? null : () => _removeHeaderRow(index),
          ),
        ],
      ),
    );
  }

  // ---- 响应结果 ----
  Widget _buildResponseCard(ThemeData theme) {
    final res = _response;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('响应结果', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (res != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (res.error != null ? Colors.red : _statusColor(res.statusCode))
                          .withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      res.error != null ? '请求失败' : '${res.statusCode} ${res.statusText}'.trim(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: res.error != null ? Colors.red : _statusColor(res.statusCode),
                      ),
                    ),
                  ),
                if (res != null) ...[
                  const SizedBox(width: 8),
                  Text('${res.durationMs} ms',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
                ],
              ],
            ),
            const SizedBox(height: 10),

            if (res == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '还没有响应，填写请求配置后点击「发送请求」',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                ),
              )
            else ...[
              if (res.error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    res.error!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                  ),
                ),

              // 响应头
              if (res.headers.isNotEmpty) ...[
                const SizedBox(height: 8),
                ExpansionTile(
                  initiallyExpanded: _headersExpanded,
                  onExpansionChanged: (v) => setState(() => _headersExpanded = v),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(
                    '响应头（${res.headers.length}）',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: res.headers
                      .map((h) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 130,
                                  child: Text(
                                    h['key'] ?? '',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Colors.blue.shade700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    h['value'] ?? '',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ],

              // 响应体
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('响应体', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: res.isJson ? Colors.green.shade50 : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      res.isJson ? 'JSON' : '文本',
                      style: TextStyle(
                        fontSize: 10,
                        color: res.isJson ? Colors.green.shade700 : Colors.grey.shade700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _openFullscreenText('响应体', res.body),
                    icon: const Icon(Icons.zoom_in, size: 16),
                    label: const Text('缩放', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 30),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: res.body));
                      _toast('响应体已复制');
                    },
                    icon: const Icon(Icons.copy, size: 15),
                    label: const Text('复制', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 30),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _bodyExpanded = !_bodyExpanded),
                    icon: Icon(
                      _bodyExpanded ? Icons.unfold_less : Icons.unfold_more,
                      size: 16,
                    ),
                    label: Text(
                      _bodyExpanded ? '折叠' : '展开',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 30),
                    ),
                  ),
                ],
              ),
              if (_bodyExpanded)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 320),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      res.body.isEmpty ? '(无响应体)' : res.body,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'monospace',
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- 请求记录 ----
  Widget _buildRecordsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('请求记录', style: theme.textTheme.titleMedium),
                const SizedBox(width: 6),
                Text(
                  '（${_records.length}）',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _records.isEmpty ? null : _clearAllRecords,
                  icon: const Icon(Icons.delete_sweep, size: 16),
                  label: const Text('清空', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 32),
                  ),
                ),
              ],
            ),
            if (_records.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    '暂无请求记录（重装 App 后记录会清空）',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                ),
              )
            else
              ..._records.map((rec) => _buildRecordTile(rec, theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordTile(_HttpRecord rec, ThemeData theme) {
    final active = rec.id == _activeRecordId;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: active ? theme.colorScheme.primary.withOpacity(0.06) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: () => _applyRecord(rec),
        leading: Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: _methodColor(rec.method).withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            rec.method,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: _methodColor(rec.method),
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                rec.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            Text(
              rec.error != null ? '失败' : '${rec.statusCode ?? '-'}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: rec.error != null ? Colors.red : _statusColor(rec.statusCode),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rec.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            Text(
              '${_fmtTime(rec.createdAt)} · ${rec.durationMs}ms',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, size: 16),
          color: Colors.grey,
          tooltip: '删除该记录',
          onPressed: () => _deleteRecord(rec.id),
        ),
      ),
    );
  }
}

/// Headers 行（key-value 一对一控制器）
class _HeaderRow {
  final TextEditingController key;
  final TextEditingController value;

  _HeaderRow({String k = '', String v = ''})
      : key = TextEditingController(text: k),
        value = TextEditingController(text: v);

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// 一次请求的响应快照
class _HttpResponse {
  final int? statusCode;
  final String statusText;
  final int durationMs;
  final List<Map<String, String>> headers;
  final String body;
  final bool isJson;
  final String? error;

  const _HttpResponse({
    required this.statusCode,
    required this.statusText,
    required this.durationMs,
    required this.headers,
    required this.body,
    required this.isJson,
    this.error,
  });
}

/// 一条请求记录（持久化到本地数据库）
class _HttpRecord {
  final String id;
  final String name;
  final String method;
  final String url;
  final int timeoutSec;
  final List<Map<String, String>> headers;
  final String body;
  final int? statusCode;
  final int durationMs;
  final List<Map<String, String>> responseHeaders;
  final String responseBody;
  final bool isJson;
  final String? error;
  final DateTime createdAt;

  const _HttpRecord({
    required this.id,
    required this.name,
    required this.method,
    required this.url,
    required this.timeoutSec,
    required this.headers,
    required this.body,
    required this.statusCode,
    required this.durationMs,
    required this.responseHeaders,
    required this.responseBody,
    required this.isJson,
    required this.error,
    required this.createdAt,
  });

  factory _HttpRecord.fromMap(Map<String, dynamic> map) {
    return _HttpRecord(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      method: map['method'] as String? ?? 'GET',
      url: map['url'] as String? ?? '',
      timeoutSec: map['timeout_sec'] as int? ?? 10,
      headers: _decodeHeaders(map['headers']),
      body: map['body'] as String? ?? '',
      statusCode: map['status_code'] as int?,
      durationMs: map['duration_ms'] as int? ?? 0,
      responseHeaders: _decodeHeaders(map['response_headers']),
      responseBody: map['response_body'] as String? ?? '',
      isJson: (map['is_json'] as int? ?? 0) == 1,
      error: map['error'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'method': method,
      'url': url,
      'timeout_sec': timeoutSec,
      'headers': jsonEncode(headers),
      'body': body,
      'status_code': statusCode,
      'duration_ms': durationMs,
      'response_headers': jsonEncode(responseHeaders),
      'response_body': responseBody,
      // sqflite 无 bool 类型，用 0/1 存储
      'is_json': isJson ? 1 : 0,
      'error': error,
      'created_at': createdAt.toIso8601String(),
    };
  }

  static List<Map<String, String>> _decodeHeaders(dynamic raw) {
    if (raw == null) return const [];
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => {
                'key': (e['key'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              })
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// 长文本全屏查看（支持双指缩放 / 拖动）
class _FullscreenTextViewer extends StatelessWidget {
  final String title;
  final String text;

  const _FullscreenTextViewer({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')),
              );
            },
          ),
        ],
      ),
      body: ColoredBox(
        color: const Color(0xFF0F172A),
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          boundaryMargin: const EdgeInsets.all(80),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text.isEmpty ? '(空)' : text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                fontFamily: 'monospace',
                color: Color(0xFFE2E8F0),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
