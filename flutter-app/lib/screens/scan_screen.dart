import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_provider.dart';
import '../services/api_client.dart';
import '../services/debug_service.dart';
import '../services/local_storage.dart';

/// 连接码绑定页面
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isBinding = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      // 限制最多 6 位数字
      final text = _controller.text;
      if (text.length > 6) {
        _controller.text = text.substring(0, 6);
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String get _pairCode => _controller.text;

  void _checkComplete() {
    if (_pairCode.length == 6 && RegExp(r'^\d{6}$').hasMatch(_pairCode) && !_isBinding) {
      _bindDevice(_pairCode);
    }
  }

  Future<void> _bindDevice(String code) async {
    if (_isBinding) return;
    final debug = DebugService();

    final storage = LocalStorage.instance;
    final currentUrl = storage.getServerUrl();
    ApiClient.instance.updateBaseUrl(currentUrl);
    debug.info('[连接码] 服务器地址: $currentUrl');
    debug.info('[连接码] 开始绑定，码: $code');

    setState(() => _isBinding = true);
    _focusNode.unfocus();

    try {
      await ref.read(deviceProvider.notifier).bindByCode(code);
      debug.info('[连接码] 绑定成功');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 设备绑定成功'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      debug.error('[连接码] 绑定失败: $e');
      if (!mounted) return;
      String errorMsg;
      final errStr = e.toString();
      if (errStr.contains('404')) {
        errorMsg = '连接码无效或已过期，请在 PC 端刷新连接码后重试';
      } else if (errStr.contains('SocketException') || errStr.contains('Connection refused')) {
        errorMsg = '无法连接服务器，请检查网络和服务器地址';
      } else if (errStr.contains('timeout')) {
        errorMsg = '请求超时，请检查网络连接';
      } else {
        errorMsg = '绑定失败: $e';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMsg),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
      // 清空输入框重新输入
      _controller.clear();
      _focusNode.requestFocus();
    } finally {
      if (mounted) {
        setState(() => _isBinding = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceState = ref.watch(deviceProvider);
    final code = _pairCode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('输入连接码'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 32),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.devices,
                  size: 40,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '输入 PC 端连接码',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '在 PC 端首页查看 6 位数字连接码',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 40),

              // 6 位数字展示框 + 隐藏的单个 TextField
              Stack(
                children: [
                  // 隐藏的输入框，捕获所有键盘输入
                  Opacity(
                    opacity: 0,
                    child: SizedBox(
                      height: 1,
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        maxLength: 6,
                        onChanged: (_) {
                          setState(() {});
                          _checkComplete();
                        },
                      ),
                    ),
                  ),
                  // 可视化的 6 个方框
                  GestureDetector(
                    onTap: () => _focusNode.requestFocus(),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(6, (index) {
                        final hasValue = index < code.length;
                        final isCurrent = index == code.length;
                        return Container(
                          width: 48,
                          height: 64,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isCurrent && _focusNode.hasFocus
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                              width: isCurrent && _focusNode.hasFocus ? 2 : 1,
                            ),
                          ),
                          child: Text(
                            hasValue ? code[index] : '',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 32),
              // 绑定按钮
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _isBinding || _pairCode.length != 6
                      ? null
                      : () => _bindDevice(_pairCode),
                  child: _isBinding
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('绑定设备', style: TextStyle(fontSize: 16)),
                ),
              ),
              // 错误提示
              if (deviceState.error != null && !_isBinding) ...[
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          deviceState.error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              Text(
                '提示：连接码 5 分钟内有效，过期请刷新',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
