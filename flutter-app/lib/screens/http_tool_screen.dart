import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_storage.dart';

/// HTTP 接口调试工具（App 端）
///
/// 与 PC Web 端能力对齐，但按移动端习惯使用 **Tab 切换式** UI：
///   Tab1 接口列表  —— 保存下来的接口模板，点击进入接口请求页并回填
///   Tab2 接口请求  —— 编辑并发起请求（发送 / 保存），**不放一键重发**
///   Tab3 请求记录  —— 历史记录，点击进详情页查看完整入参与响应，详情页提供一键重发
///
/// 存储策略（与 Web 端刻意区分）：接口列表与请求记录**只存手机本地数据库**
/// （sqflite，无 sqflite 环境降级为 SharedPreferences），不上传服务器，仅本机可用。
class HttpToolScreen extends StatefulWidget {
  const HttpToolScreen({super.key});

  @override
  State<HttpToolScreen> createState() => _HttpToolScreenState();
}

class _HttpToolScreenState extends State<HttpToolScreen>
    with SingleTickerProviderStateMixin {
  /// 与 PC Web 端保持一致的常量
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

  /// 裸 Dio：不加任何拦截器，保证看到「最原始」的响应（含非 0 业务码与 4xx/5xx）
  final Dio _dio = Dio();

  late final TabController _tabCtrl;

  // ---- 请求表单（Tab2）----
  final TextEditingController _urlCtrl =
      TextEditingController(text: '$_serverOrigin/api/v1/health');
  final TextEditingController _timeoutCtrl =
      TextEditingController(text: '$_defaultTimeoutSec');
  final TextEditingController _bodyCtrl = TextEditingController();
  final List<_HeaderRow> _headerRows = [_HeaderRow()];

  String _method = 'GET';

  /// 当前表单关联的名字：来自接口模板或历史记录，用于保存接口与生成请求记录名
  String _formName = '';

  /// 表单正在编辑的接口模板 id；null 表示是一份新参数
  String? _editingApiId;

  bool _sending = false;
  bool _bodyExpanded = true;

  _HttpResponse? _response;
  List<_HttpApi> _apis = [];
  List<_HttpRecord> _records = [];

  /// 当前显示的 Tab（配合 IndexedStack 使用）
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _tabCtrl.addListener(_onTabChanged);
    _loadApis();
    _loadRecords();
  }

  /// TabBar 点击/程序化切换都会走到这里
  void _onTabChanged() {
    if (!mounted) return;
    if (_tabCtrl.index != _currentTab) {
      setState(() => _currentTab = _tabCtrl.index);
    }
  }

  /// 清空请求头行的引用
  ///
  /// 注意：这里【不要】调用旧 controller 的 dispose() ——
  /// 它们可能仍被页面上已挂载的 TextField 引用，提前 dispose 会破坏
  /// 框架的依赖清理（触发 InheritedElement 相关断言 / used after disposed）。
  /// 直接丢弃引用即可：Element 卸载时框架会自行 removeListener，随后由 GC 回收。
  void _clearHeaderRows() {
    _headerRows.clear();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
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
  static String get _serverOrigin {
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

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Color _statusColor(int? code) {
    if (code == null) return Colors.red;
    return (code >= 200 && code < 400)
        ? Colors.green.shade600
        : Colors.red.shade600;
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

  String _newId() {
    final rand = Random().nextInt(0xFFFFFF).toRadixString(36);
    return 'req_${DateTime.now().microsecondsSinceEpoch}_$rand';
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

  void _upsertHeader(String key, String value) {
    for (final row in _headerRows) {
      if (row.key.text.trim().toLowerCase() == key.toLowerCase()) {
        row.value.text = value;
        setState(() {});
        return;
      }
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

  // ============================================================
  // 发送请求
  // ============================================================

  Future<void> _send() async {
    if (_sending) return;

    final target = _urlCtrl.text.trim();
    if (target.isEmpty) {
      _toast('请先填写请求地址 URL');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final timeoutSec =
        int.tryParse(_timeoutCtrl.text.trim()) ?? _defaultTimeoutSec;
    final safeTimeout = timeoutSec <= 0 ? _defaultTimeoutSec : timeoutSec;

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
        isJson: isJsonText(body),
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

    // 落库为一条请求记录（只存本机）
    final record = _HttpRecord(
      id: _newId(),
      name: _formName.isNotEmpty
          ? _formName
          : _defaultName(_method, target),
      method: _method,
      url: target,
      timeoutSec: safeTimeout,
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
      _sending = false;
      _response = result;
      _bodyExpanded = true;
      _records = [record, ..._records];
      if (_records.length > LocalStorage.httpRecordsLimit) {
        _records = _records.sublist(0, LocalStorage.httpRecordsLimit);
      }
    });

    if (result.error != null) {
      messenger.showSnackBar(
        SnackBar(
            content: Text(result.error!),
            backgroundColor: Colors.red.shade600),
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
        SnackBar(
            content:
                Text('请求成功（${result.statusCode}，${result.durationMs}ms）')),
      );
    }
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
  // 接口列表（Tab1）
  // ============================================================

  Future<void> _loadApis() async {
    try {
      final rows = await LocalStorage.instance.getHttpApis();
      if (!mounted) return;
      setState(() => _apis = rows.map(_HttpApi.fromMap).toList());
    } catch (e) {
      _toast('读取接口列表失败: $e', error: true);
    }
  }

  /// 点击接口条目：回填参数并切到「接口请求」Tab
  void _applyApi(_HttpApi api) {
    setState(() {
      _editingApiId = api.id;
      _formName = api.name;
      _method = api.method;
      _urlCtrl.text = api.url;
      _timeoutCtrl.text = '${api.timeoutSec}';
      _bodyCtrl.text = api.body;
      _clearHeaderRows();
      if (api.headers.isEmpty) {
        _headerRows.add(_HeaderRow());
      } else {
        for (final h in api.headers) {
          _headerRows.add(_HeaderRow(k: h['key'] ?? '', v: h['value'] ?? ''));
        }
      }
      _response = null;
      _currentTab = 1;
    });
    _tabCtrl.animateTo(1);
  }

  /// 新增一份空参数（不切 tab 的场景由调用方决定）
  void _startNewForm() {
    setState(() {
      _editingApiId = null;
      _formName = '';
      _method = 'GET';
      _urlCtrl.text = '$_serverOrigin/api/v1/health';
      _timeoutCtrl.text = '$_defaultTimeoutSec';
      _bodyCtrl.text = '';
      _clearHeaderRows();
      _headerRows.add(_HeaderRow());
      _response = null;
      _currentTab = 1;
    });
    _tabCtrl.animateTo(1);
  }

  /// 保存 / 更新接口（Tab2 的「保存」按钮）
  Future<void> _saveApi() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写请求地址 URL');
      return;
    }

    final suggested = _formName.isNotEmpty
        ? _formName
        : _defaultName(_method, url);
    final name = await _promptName(suggested);
    if (name == null) return; // 用户取消
    if (name.trim().isEmpty) {
      _toast('接口名称不能为空');
      return;
    }

    final now = DateTime.now();
    final api = _HttpApi(
      id: _editingApiId ?? _newId(),
      name: name.trim(),
      method: _method,
      url: url,
      timeoutSec:
          int.tryParse(_timeoutCtrl.text.trim()) ?? _defaultTimeoutSec,
      headers: _headerRows
          .map((row) => {'key': row.key.text, 'value': row.value.text})
          .toList(),
      body: _bodyCtrl.text,
      createdAt: now,
      updatedAt: now,
    );

    try {
      await LocalStorage.instance.saveHttpApi(api.toMap());
    } catch (e) {
      _toast('保存接口失败: $e', error: true);
      return;
    }

    if (!mounted) return;
    setState(() {
      _editingApiId = api.id;
      _formName = api.name;
      _apis = [api, ..._apis.where((a) => a.id != api.id)];
    });
    _toast(_apis.any((a) => a.id == api.id) ? '接口已保存' : '接口已新增');
  }

  /// 重命名接口（弹窗输入）
  Future<void> _renameApi(_HttpApi api) async {
    final name = await _promptName(api.name);
    if (name == null || name.trim().isEmpty || name.trim() == api.name) return;

    final updated = _HttpApi(
      id: api.id,
      name: name.trim(),
      method: api.method,
      url: api.url,
      timeoutSec: api.timeoutSec,
      headers: api.headers,
      body: api.body,
      createdAt: api.createdAt,
      updatedAt: DateTime.now(),
    );
    try {
      await LocalStorage.instance.saveHttpApi(updated.toMap());
    } catch (e) {
      _toast('重命名失败: $e', error: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _apis = _apis.map((a) => a.id == api.id ? updated : a).toList();
      if (_editingApiId == api.id) _formName = updated.name;
    });
    _toast('已重命名');
  }

  Future<void> _deleteApi(_HttpApi api) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除接口'),
        content: Text('确认删除接口「${api.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await LocalStorage.instance.deleteHttpApi(api.id);
    } catch (e) {
      _toast('删除失败: $e', error: true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _apis = _apis.where((a) => a.id != api.id).toList();
      if (_editingApiId == api.id) _editingApiId = null;
    });
    _toast('接口已删除');
  }

  /// 弹窗输入接口名称；返回 null 表示取消
  Future<String?> _promptName(String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接口名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：获取设备列表',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('确定')),
        ],
      ),
    );
  }

  // ============================================================
  // 请求记录（Tab3）
  // ============================================================

  Future<void> _loadRecords() async {
    try {
      final rows = await LocalStorage.instance.getHttpRecords();
      if (!mounted) return;
      setState(() => _records = rows.map(_HttpRecord.fromMap).toList());
    } catch (e) {
      _toast('读取请求记录失败: $e', error: true);
    }
  }

  Future<void> _deleteRecord(String id) async {
    try {
      await LocalStorage.instance.deleteHttpRecord(id);
    } catch (e) {
      _toast('删除失败: $e', error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _records = _records.where((r) => r.id != id).toList());
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
    setState(() => _records = []);
    _toast('请求记录已清空');
  }

  /// 详情页点击「一键重发」：回填参数 → 跳到接口请求页 → 立即发起请求
  Future<void> _resendFromDetail(_HttpRecord rec) async {
    setState(() {
      _editingApiId = null;
      _formName = rec.name;
      _method = rec.method;
      _urlCtrl.text = rec.url;
      _timeoutCtrl.text = '${rec.timeoutSec}';
      _bodyCtrl.text = rec.body;
      _clearHeaderRows();
      if (rec.headers.isEmpty) {
        _headerRows.add(_HeaderRow());
      } else {
        for (final h in rec.headers) {
          _headerRows.add(_HeaderRow(k: h['key'] ?? '', v: h['value'] ?? ''));
        }
      }
      _response = null;
      _currentTab = 1;
    });

    // IndexedStack 同步切换，无需等待动画
    _tabCtrl.animateTo(1);
    await _send();
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HTTP 接口调试'),
        bottom: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '接口列表'),
            Tab(text: '接口请求'),
            Tab(text: '请求记录'),
          ],
        ),
      ),
      // 用 IndexedStack 而不是 TabBarView：
      //  - 三个页面常驻，切 Tab 不销毁/重建子树，TextField 的 controller
      //    永远不会在仍被引用时被释放，避开 InheritedElement 相关的框架断言；
      //  - 切换只做显示/隐藏，交互更稳定（代价是没有左右滑动手势）。
      body: IndexedStack(
        index: _currentTab,
        children: [
          _buildApiListTab(),
          _buildRequestTab(),
          _buildRecordsTab(),
        ],
      ),
    );
  }

  // ---- Tab1：接口列表 ----
  Widget _buildApiListTab() {
    final theme = _theme;
    return RefreshIndicator(
      onRefresh: _loadApis,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('接口列表', style: theme.textTheme.titleMedium),
              const SizedBox(width: 6),
              Text('（${_apis.length}）',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
              const Spacer(),
              FilledButton.icon(
                onPressed: _startNewForm,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增接口'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '点击接口会切到「接口请求」页并自动回填全部参数',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 12),

          if (_apis.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.http, size: 44, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text('还没有保存过接口', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    Text('在「接口请求」页填好参数后点「保存」',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
                  ],
                ),
              ),
            )
          else
            ..._apis.map((api) => _buildApiCard(api, theme)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildApiCard(_HttpApi api, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _applyApi(api),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 54,
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: _methodColor(api.method).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  api.method,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _methodColor(api.method),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      api.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      api.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                color: Colors.grey,
                tooltip: '重命名',
                onPressed: () => _renameApi(api),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                color: Colors.grey,
                tooltip: '删除接口',
                onPressed: () => _deleteApi(api),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Tab2：接口请求 ----
  Widget _buildRequestTab() {
    final theme = _theme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 编辑状态提示
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _editingApiId != null
                ? theme.colorScheme.primary.withOpacity(0.08)
                : Colors.grey.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                _editingApiId != null ? Icons.edit : Icons.add_circle_outline,
                size: 16,
                color: Colors.grey.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _editingApiId != null
                      ? '正在编辑接口「${_formName.isEmpty ? '未命名' : _formName}」，点「保存」会更新它'
                      : '新参数，点「保存」可存入「接口列表」',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (_editingApiId != null)
                GestureDetector(
                  onTap: _startNewForm,
                  child: const Text('新建',
                      style: TextStyle(fontSize: 12, color: Colors.blue)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        _buildRequestCard(theme),
        const SizedBox(height: 16),
        _buildResponseCard(theme),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildRequestCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                  avatar: const Icon(Icons.key, size: 14),
                  label: const Text('认证头', style: TextStyle(fontSize: 11)),
                  onPressed: _sending ? null : _addAuthHeaders,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 超时
            TextField(
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
            const SizedBox(height: 16),

            // Headers
            Row(
              children: [
                Text('请求头 Headers', style: theme.textTheme.bodyMedium),
                const Spacer(),
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

            // 操作：只有「发送请求」和「保存」，按需求不放「一键重发」
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sending ? null : _send,
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
                  onPressed: _sending ? null : _saveApi,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
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

  // ---- 本次响应（Tab2 底部，发送后立即看结果）----
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
                Text('本次响应', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (res != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (res.error != null
                              ? Colors.red
                              : _statusColor(res.statusCode))
                          .withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      res.error != null
                          ? '请求失败'
                          : '${res.statusCode} ${res.statusText}'.trim(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: res.error != null
                            ? Colors.red
                            : _statusColor(res.statusCode),
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
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    '点击「发送请求」后在此查看响应；完整历史见「请求记录」',
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
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text('响应头（${res.headers.length}）',
                      style: theme.textTheme.bodySmall),
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

  // ---- Tab3：请求记录 ----
  Widget _buildRecordsTab() {
    final theme = _theme;
    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('请求记录', style: theme.textTheme.titleMedium),
              const SizedBox(width: 6),
              Text('（${_records.length}）',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
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
          const SizedBox(height: 4),
          Text(
            '点击记录查看完整入参与响应，详情页可一键重发',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 12),

          if (_records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.history, size: 44, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text('暂无请求记录', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    Text('只保存在本机，重装 App 后会清空',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
                  ],
                ),
              ),
            )
          else
            ..._records.map((rec) => _buildRecordTile(rec, theme)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildRecordTile(_HttpRecord rec, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        onTap: () => _openRecordDetail(rec),
        leading: Container(
          width: 54,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: _methodColor(rec.method).withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            rec.method,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
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
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              rec.error != null ? '失败' : '${rec.statusCode ?? '-'}',
              style: TextStyle(
                fontSize: 12,
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              color: Colors.grey,
              tooltip: '删除该记录',
              onPressed: () => _deleteRecord(rec.id),
            ),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }

  void _openRecordDetail(_HttpRecord rec) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecordDetailScreen(
          record: rec,
          onResend: () => _resendFromDetail(rec),
        ),
      ),
    );
  }
}

// ============================================================
// 辅助模型
// ============================================================

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

/// 接口模板（「接口列表」的数据源，只存本机）
class _HttpApi {
  final String id;
  final String name;
  final String method;
  final String url;
  final int timeoutSec;
  final List<Map<String, String>> headers;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;

  const _HttpApi({
    required this.id,
    required this.name,
    required this.method,
    required this.url,
    required this.timeoutSec,
    required this.headers,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });

  factory _HttpApi.fromMap(Map<String, dynamic> map) {
    return _HttpApi(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      method: map['method'] as String? ?? 'GET',
      url: map['url'] as String? ?? '',
      timeoutSec: map['timeout_sec'] as int? ?? 10,
      headers: _HttpRecord._decodeHeaders(map['headers']),
      body: map['body'] as String? ?? '',
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
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
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
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
    final responseBody = map['response_body'] as String? ?? '';
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
      responseBody: responseBody,
      // isJson 不入库（表里没有该列），由响应体内容推导
      isJson: isJsonText(responseBody),
      error: map['error'] as String?,
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
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

/// 判断文本是否为 JSON（与存储解耦，避免表结构与写入字段不一致）
bool isJsonText(String text) {
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

// ============================================================
// 请求记录详情页（完整入参 + 完整响应 + 一键重发）
// ============================================================
class _RecordDetailScreen extends StatelessWidget {
  final _HttpRecord record;
  final VoidCallback onResend;

  const _RecordDetailScreen({required this.record, required this.onResend});

  Color _statusColor(BuildContext context, int? code) {
    if (code == null) return Colors.red;
    return (code >= 200 && code < 400) ? Colors.green : Colors.red;
  }

  Color _methodColor(String m) {
    switch (m.toUpperCase()) {
      case 'GET':
        return Colors.green;
      case 'POST':
        return Colors.blue;
      case 'PUT':
        return Colors.orange;
      case 'DELETE':
        return Colors.red;
      case 'PATCH':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rec = record;

    return Scaffold(
      appBar: AppBar(
        title: Text(rec.name, overflow: TextOverflow.ellipsis),
        actions: [
          FilledButton.icon(
            onPressed: onResend,
            icon: const Icon(Icons.replay, size: 18),
            label: const Text('一键重发'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- 完整入参 ----
          _sectionTitle(theme, '完整入参'),
          // 请求方式用彩色徽标展示
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 64,
                  child: Text('请求方式',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _methodColor(rec.method).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    rec.method,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _methodColor(rec.method),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _kvRow(theme, '请求地址', rec.url, mono: true),
          _kvRow(theme, '超时时间', '${rec.timeoutSec} 秒'),
          _kvRow(theme, '发起时间', _fmtTime(rec.createdAt)),

          const SizedBox(height: 12),
          if (rec.headers.any((h) => (h['key'] ?? '').isNotEmpty)) ...[
            Text('请求头', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
            const SizedBox(height: 4),
            _darkBlock(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: rec.headers
                    .where((h) => (h['key'] ?? '').isNotEmpty)
                    .map((h) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: SelectableText.rich(
                            TextSpan(
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                              children: [
                                TextSpan(
                                    text: h['key'],
                                    style: TextStyle(color: Colors.blue.shade300)),
                                const TextSpan(
                                    text: ': ', style: TextStyle(color: Colors.grey)),
                                TextSpan(
                                    text: h['value'],
                                    style: const TextStyle(color: Color(0xFFE2E8F0))),
                              ],
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],

          Text('请求体', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
          const SizedBox(height: 4),
          _darkBlock(
            context,
            child: SelectableText(
              rec.body.isEmpty ? '（无请求体）' : rec.body,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                fontFamily: 'monospace',
                color: Color(0xFFE2E8F0),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ---- 完整响应 ----
          _sectionTitle(theme, '完整响应'),
          if (rec.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                rec.error!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade700),
              ),
            )
          else ...[
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _statusColor(context, rec.statusCode).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${rec.statusCode ?? '-'}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: _statusColor(context, rec.statusCode),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('耗时 ${rec.durationMs} ms',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 10),

            if (rec.responseHeaders.isNotEmpty) ...[
              Text('响应头', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: 4),
              _darkBlock(
                context,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rec.responseHeaders
                      .map((h) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: SelectableText.rich(
                              TextSpan(
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                                children: [
                                  TextSpan(
                                      text: h['key'],
                                      style: TextStyle(color: Colors.blue.shade300)),
                                  const TextSpan(
                                      text: ': ', style: TextStyle(color: Colors.grey)),
                                  TextSpan(
                                      text: h['value'],
                                      style: const TextStyle(color: Color(0xFFE2E8F0))),
                                ],
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: 10),
            ],

            Text('响应体', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
            const SizedBox(height: 4),
            _darkBlock(
              context,
              child: SelectableText(
                rec.responseBody.isEmpty ? '(无响应体)' : rec.responseBody,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  fontFamily: 'monospace',
                  color: Color(0xFFE2E8F0),
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
    );
  }

  Widget _kvRow(ThemeData theme, String label, String value, {bool mono = false}) {
    final valueStyle = TextStyle(fontSize: 12, fontFamily: mono ? 'monospace' : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
          ),
          Expanded(child: SelectableText(value, style: valueStyle)),
        ],
      ),
    );
  }

  Widget _darkBlock(BuildContext context, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
      ),
      // 用 LayoutBuilder 取宽度，避免 MediaQuery.of 造成的跨树依赖
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}
