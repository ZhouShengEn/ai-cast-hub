import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_provider.dart';
import '../services/api_client.dart';
import '../services/local_storage.dart';
import '../utils/constants.dart';
import '../utils/extensions.dart';

/// 设置页面 — 服务器配置、API Key 管理、设备信息
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _providerController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final LocalStorage _storage = LocalStorage.instance;

  List<Map<String, String>> _apiKeys = [];

  @override
  void initState() {
    super.initState();
    _serverUrlController.text = _storage.getServerUrl();
    _apiKeys = _storage.getApiKeys();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _providerController.dispose();
    _apiKeyController.dispose();
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
      appBar: AppBar(
        title: const Text('设置'),
      ),
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

          // API Key 管理
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('API Key 管理', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),

                  // 添加新 Key
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _providerController,
                          decoration: const InputDecoration(
                            labelText: 'Provider',
                            hintText: 'openai',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _apiKeyController,
                          decoration: const InputDecoration(
                            labelText: 'API Key',
                            hintText: 'sk-...',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          obscureText: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _addApiKey,
                      child: const Text('添加'),
                    ),
                  ),

                  // 已配置 Keys 列表
                  if (_apiKeys.isNotEmpty) ...[
                    const Divider(height: 24),
                    ..._apiKeys.asMap().entries.map((entry) {
                      final index = entry.key;
                      final key = entry.value;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          child: Text(
                            key['provider']?.substring(0, 1).toUpperCase() ?? '?',
                            style: TextStyle(
                              color: theme.colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(key['provider'] ?? ''),
                        subtitle: Text(
                          '${(key['key'] ?? '').substring(0, 8)}...',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteApiKey(index),
                          tooltip: '删除',
                        ),
                      );
                    }),
                  ],
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
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 13),
            ),
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
    // 同步更新 ApiClient 的 baseUrl
    ApiClient.instance.updateBaseUrl(url);
    _showSnackBar('服务器地址已保存，正在重新注册设备...');

    // 保存后重新注册设备
    ref.read(deviceProvider.notifier).registerDevice();
  }

  void _addApiKey() {
    final provider = _providerController.text.trim();
    final key = _apiKeyController.text.trim();

    if (provider.isEmpty || key.isEmpty) {
      _showSnackBar('请填写 Provider 和 API Key');
      return;
    }

    // 检查重复
    final exists = _apiKeys.any((k) => k['provider'] == provider);
    if (exists) {
      // 更新已存在的 key
      final index = _apiKeys.indexWhere((k) => k['provider'] == provider);
      _apiKeys[index] = {'provider': provider, 'key': key};
    } else {
      _apiKeys.add({'provider': provider, 'key': key});
    }

    _storage.saveApiKeys(_apiKeys);
    _providerController.clear();
    _apiKeyController.clear();
    setState(() {});
    _showSnackBar('API Key 已添加');
  }

  void _deleteApiKey(int index) {
    setState(() {
      _apiKeys.removeAt(index);
      _storage.saveApiKeys(_apiKeys);
    });
    _showSnackBar('API Key 已删除');
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
              // 生成新密钥
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

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  int min(int a, int b) => a < b ? a : b;
}
