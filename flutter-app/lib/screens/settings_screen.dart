import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_provider.dart';
import '../services/api_client.dart';
import '../services/local_storage.dart';
import '../services/debug_service.dart';
import '../utils/constants.dart';
import '../utils/extensions.dart';
import '../utils/model_config.dart';
import '../app.dart';

/// 设置页面 — 服务器配置、模型配置、背景风格、设备信息
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _serverUrlController = TextEditingController();
  final LocalStorage _storage = LocalStorage.instance;

  List<Map<String, String>> _modelConfigs = [];
  late BackgroundStyle _currentStyle;

  // 新增行的临时控制器
  String? _newProvider;
  final TextEditingController _newKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _serverUrlController.text = _storage.getServerUrl();
    _modelConfigs = _storage.getApiKeys();
    _currentStyle = _parseSavedStyle();
  }

  BackgroundStyle _parseSavedStyle() {
    switch (_storage.getBackgroundStyle()) {
      case 'night':
        return BackgroundStyle.night;
      case 'eyeCare':
        return BackgroundStyle.eyeCare;
      default:
        return BackgroundStyle.day;
    }
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _newKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceState = ref.watch(deviceProvider);
    final device = deviceState.device;
    final deviceUuid = _storage.getDeviceUuid() ?? '未注册';
    final transferKey = _storage.getTransferKey() ?? '未生成';

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 服务器配置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('服务器配置', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serverUrlController,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'http://192.168.1.100:3000',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.dns),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _saveServerUrl,
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 模型配置（本地直连用）
          _buildModelConfigCard(theme),

          const SizedBox(height: 16),

          // 背景风格
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('背景风格', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _buildStyleOption(
                    context,
                    icon: Icons.light_mode,
                    label: '白天',
                    subtitle: '明亮清爽的经典浅色主题',
                    value: BackgroundStyle.day,
                  ),
                  const Divider(height: 1),
                  _buildStyleOption(
                    context,
                    icon: Icons.dark_mode,
                    label: '黑夜',
                    subtitle: '暗色主题，适合弱光环境',
                    value: BackgroundStyle.night,
                  ),
                  const Divider(height: 1),
                  _buildStyleOption(
                    context,
                    icon: Icons.health_and_safety,
                    label: '护眼',
                    subtitle: '暖色调纸张质感，减少蓝光刺激',
                    value: BackgroundStyle.eyeCare,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 设备信息
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设备信息', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _infoRow('设备名称', device?.deviceName ?? '未注册'),
                  _infoRow('平台', device?.platform ?? '-'),
                  _infoRow('UUID', deviceUuid.truncate(28)),
                  _infoRow('传输密钥', '${transferKey.substring(0, min(12, transferKey.length))}...'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _copyToClipboard('deviceUuid', deviceUuid),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制 UUID'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _copyToClipboard('transferKey', transferKey),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制密钥'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 重置传输密钥
          Card(
            child: ListTile(
              leading: Icon(Icons.refresh, color: theme.colorScheme.error),
              title: Text('重置传输密钥', style: TextStyle(color: theme.colorScheme.error)),
              subtitle: const Text('重置后将断开所有已绑定设备'),
              onTap: _resetTransferKey,
            ),
          ),

          const SizedBox(height: 16),

          // 调试悬浮球开关
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.bug_report),
              title: const Text('调试悬浮球'),
              subtitle: const Text('在首页显示可拖拽的调试面板，查看日志和网络请求'),
              value: _storage.getDebugBallEnabled(),
              onChanged: (val) {
                _storage.saveDebugBallEnabled(val);
                DebugService().enabled.value = val;
                setState(() {});
                _showSnackBar(val ? '调试悬浮球已开启' : '调试悬浮球已关闭');
              },
            ),
          ),

          const SizedBox(height: 16),

          // 网络工具入口
          Card(
            child: ListTile(
              leading: Icon(Icons.network_ping, color: theme.colorScheme.primary),
              title: const Text('网络工具'),
              subtitle: const Text('Ping 测试 · 查看本机 IP'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pushNamed(context, '/network-tools'),
            ),
          ),

          const SizedBox(height: 16),

          // 关于
          Card(
            child: ListTile(
              leading: Icon(Icons.info_outline, color: theme.colorScheme.primary),
              title: const Text('关于 AI Cast Hub'),
              subtitle: const Text('版本 ${AppConstants.appVersion}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                showAboutDialog(
                  context: context,
                  applicationName: AppConstants.appName,
                  applicationVersion: AppConstants.appVersion,
                  applicationLegalese: '跨设备 AI 协作平台\nMIT License',
                );
              },
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ============ 模型配置卡片 ============

  Widget _buildModelConfigCard(ThemeData theme) {
    final localProviders = ModelConfig.localProviders;
    // 已配置的 provider key 集合（用于过滤下拉选项）
    final usedProviders = _modelConfigs
        .map((c) => c['provider'])
        .where((p) => p != null && p.isNotEmpty)
        .toSet();

    // 下拉可选的 provider（排除已配置的）
    final availableProviders = localProviders
        .where((p) => !usedProviders.contains(p.key))
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('模型配置', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '本地直连模式使用，配置大模型 API Key',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // 已配置的模型列表
            if (_modelConfigs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    '暂未配置，请在下方添加',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              ..._modelConfigs.asMap().entries.map((entry) {
                final index = entry.key;
                final config = entry.value;
                final provider = ModelConfig.getProvider(config['provider'] ?? '');
                return _buildConfigItem(
                  theme,
                  index: index,
                  provider: provider,
                  apiKey: config['key'] ?? '',
                  models: provider?.models ?? [],
                );
              }),

            const Divider(height: 24),

            // 新增配置行
            if (availableProviders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '所有支持的模型均已配置',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              _buildNewConfigRow(theme, availableProviders),
          ],
        ),
      ),
    );
  }

  /// 已配置项的展示行
  Widget _buildConfigItem(
    ThemeData theme, {
    required int index,
    required ProviderConfig? provider,
    required String apiKey,
    required List<ModelInfo> models,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Provider 图标 + 名称
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    (provider?.displayName ?? '?').substring(0, 1),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      provider?.displayName ?? '未知',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'sk-...${apiKey.length > 8 ? apiKey.substring(apiKey.length - 4) : ""}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              // 删除按钮
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: theme.colorScheme.error,
                tooltip: '删除',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () => _deleteConfig(index),
              ),
            ],
          ),
          // 可用模型标签
          if (models.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: models.map((m) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    m.name,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  /// 新增配置行
  Widget _buildNewConfigRow(ThemeData theme, List<ProviderConfig> available) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Provider 下拉框（全宽）
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _newProvider,
                  decoration: const InputDecoration(
                    labelText: '选择模型',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  items: available.map((p) {
                    return DropdownMenuItem(
                      value: p.key,
                      child: Text(
                        p.displayName,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setState(() => _newProvider = val);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // API Key 输入框（全宽，独立行）
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newKeyController,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    hintText: 'sk-...',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  obscureText: true,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 自动保存提示（使用 Wrap 避免窄屏溢出）
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.info_outline, size: 14, color: theme.colorScheme.onSurfaceVariant),
              Text(
                '填写完成后点击保存即可，API Key 仅存储在本地',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _canSaveNew() ? _saveNewConfig : null,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('保存'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 是否可以保存新配置
  bool _canSaveNew() {
    return _newProvider != null && _newKeyController.text.trim().isNotEmpty;
  }

  /// 保存新配置
  void _saveNewConfig() {
    final provider = _newProvider;
    final key = _newKeyController.text.trim();
    if (provider == null || key.isEmpty) return;

    setState(() {
      _modelConfigs.add({'provider': provider, 'key': key});
      _storage.saveApiKeys(_modelConfigs);
      _newProvider = null;
      _newKeyController.clear();
    });
    _showSnackBar('模型配置已保存');
  }

  /// 删除配置
  void _deleteConfig(int index) {
    setState(() {
      _modelConfigs.removeAt(index);
      _storage.saveApiKeys(_modelConfigs);
    });
    _showSnackBar('已删除');
  }

  // ============ 其他方法 ============

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  void _saveServerUrl() {
    final url = _serverUrlController.text.trim();
    if (url.isEmpty) {
      _showSnackBar('请输入有效的 URL');
      return;
    }
    _storage.saveServerUrl(url);
    ApiClient.instance.updateBaseUrl(url);
    _showSnackBar('服务器地址已保存，正在重新注册设备...');
    ref.read(deviceProvider.notifier).registerDevice();
  }

  void _copyToClipboard(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    _showSnackBar('$label 已复制到剪贴板');
  }

  void _resetTransferKey() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置传输密钥'),
        content: const Text('重置后将生成新的传输密钥，所有已绑定设备将被断开。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              final newKey =
                  'tk_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
              _storage.saveTransferKey(newKey);
              setState(() {});
              _showSnackBar('传输密钥已重置');
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('重置'),
          ),
        ],
      ),
    );
  }

  Widget _buildStyleOption(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required BackgroundStyle value,
  }) {
    final selected = _currentStyle == value;
    return InkWell(
      onTap: () => _setStyle(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon,
                size: 28,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      )),
                  Text(subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          )),
                ],
              ),
            ),
            Radio<BackgroundStyle>(
              value: value,
              groupValue: _currentStyle,
              onChanged: (v) => v != null ? _setStyle(v) : null,
            ),
          ],
        ),
      ),
    );
  }

  void _setStyle(BackgroundStyle style) {
    setState(() => _currentStyle = style);
    _storage.saveBackgroundStyle(style.name);
    backgroundStyleNotifier.value = style;
    _showSnackBar('背景风格已切换为 ${_styleLabel(style)}');
  }

  String _styleLabel(BackgroundStyle style) {
    switch (style) {
      case BackgroundStyle.day:
        return '白天';
      case BackgroundStyle.night:
        return '黑夜';
      case BackgroundStyle.eyeCare:
        return '护眼';
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  int min(int a, int b) => a < b ? a : b;
}
