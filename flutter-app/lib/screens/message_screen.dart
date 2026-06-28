import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../providers/message_provider.dart';
import '../providers/device_provider.dart';
import '../utils/open_file.dart';

class MessageScreen extends ConsumerStatefulWidget {
  const MessageScreen({super.key});
  @override
  ConsumerState<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends ConsumerState<MessageScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _autoConnectTried = false;
  bool _shouldScrollDown = false;

  void _scrollDown() {
    if (!_shouldScrollDown) return;
    Future.delayed(const Duration(milliseconds: 150), () {
      if (_scroll.hasClients && _shouldScrollDown) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(messageProvider.notifier).startListening();
      ref.read(messageProvider.notifier).setViewing(true);
    });
  }

  @override
  void dispose() {
    ref.read(messageProvider.notifier).setViewing(false);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final s = ref.watch(messageProvider);
    final d = ref.watch(deviceProvider);
    final n = ref.read(messageProvider.notifier);
    final pid = d.pairedDevices.isNotEmpty ? d.pairedDevices.first.deviceUuid : '';
    final pname = d.pairedDevices.isNotEmpty ? d.pairedDevices.first.deviceName : 'PC';

    if (!_autoConnectTried && pid.isNotEmpty && !s.isConnected && !s.isConnecting) {
      _autoConnectTried = true;
      Future.microtask(() => n.connect(pid));
    }
    if (pid.isEmpty) _autoConnectTried = false;

    // 新消息到达时自动滚动到底部
    ref.listen(messageProvider, (prev, next) {
      if (next.messages.length > (prev?.messages.length ?? 0)) {
        _shouldScrollDown = true;
        _scrollDown();
      }
    });

    return Scaffold(
      backgroundColor: theme.brightness == Brightness.light ? const Color(0xFFEDEDED) : null,
      appBar: AppBar(
        title: Text(pname),
        actions: [
          if (s.isConnected)
            IconButton(icon: const Icon(Icons.link_off), tooltip: '断开连接', onPressed: () { n.disconnect(); _autoConnectTried = false; }),
        ],
      ),
      body: Column(children: [
        // 连接断开横幅（之前有连接，现在断了）
        if (!s.isConnected && !s.isConnecting && s.messages.isNotEmpty && s.error == null && pid.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.orange.shade50,
            child: Row(children: [
              const Icon(Icons.link_off, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              const Expanded(child: Text('连接已断开', style: TextStyle(color: Colors.orange, fontSize: 14, fontWeight: FontWeight.w600))),
              TextButton(
                onPressed: () { _autoConnectTried = false; n.connect(pid); },
                style: TextButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
                child: const Text('重新连接', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ),
        // 连接失败错误横幅
        if (!s.isConnected && !s.isConnecting && s.error != null && pid.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.red.shade50,
            child: Row(children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('连接失败', style: TextStyle(color: Colors.red, fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(s.error!, style: const TextStyle(color: Colors.red, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
                ]),
              ),
              TextButton(
                onPressed: () { _autoConnectTried = false; n.connect(pid); },
                style: TextButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
                child: const Text('重新连接', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ),
        // 状态栏（未连接且无错误）
        if (!s.isConnected && (!s.isConnecting && s.error == null || pid.isEmpty))
          Container(
            width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10),
            color: theme.colorScheme.primaryContainer,
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (s.isConnecting) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(s.isConnecting ? '正在连接...' : (pid.isEmpty ? '请先在首页输入连接码绑定 PC 设备' : '未连接'),
                  style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontSize: 13)),
              ]),
              if (!s.isConnecting && pid.isNotEmpty) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () { _autoConnectTried = false; n.connect(pid); },
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('连接消息通道', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.onPrimaryContainer),
                ),
              ],
              if (pid.isEmpty) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => Navigator.pushNamed(ctx, '/scan').then((_) => ref.read(deviceProvider.notifier).fetchDeviceList()),
                  icon: const Icon(Icons.bluetooth, size: 16),
                  label: const Text('输入连接码绑定 PC 设备', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.onPrimaryContainer),
                ),
              ],
            ]),
          ),
        // 连接中状态
        if (s.isConnecting)
          Container(
            width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 12),
            color: Colors.blue.shade50,
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('正在连接 PC 端...', style: TextStyle(color: Colors.blue, fontSize: 13)),
            ]),
          ),
        // 消息列表
        Expanded(
          child: s.messages.isEmpty
              ? Center(child: Text(s.isConnected ? '开始聊天吧~' : '连接后可发送消息', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  controller: _scroll, padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  itemCount: s.messages.length,
                  itemBuilder: (ctx, i) => _bubble(theme, s.messages[i], n),
                ),
        ),
        // 输入栏（微信风格）
        if (s.isConnected)
          Container(
            decoration: BoxDecoration(color: theme.colorScheme.surface, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 2, offset: const Offset(0, -1))]),
            padding: EdgeInsets.fromLTRB(8, 6, 8, MediaQuery.of(ctx).padding.bottom + 6),
            child: Row(children: [
              IconButton(icon: const Icon(Icons.add_circle_outline, size: 28), color: Colors.grey, onPressed: () => n.sendFile()),
              Expanded(
                child: TextField(
                  controller: _ctrl, maxLines: 4, minLines: 1,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: '输入消息...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    filled: true, fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  ),
                  onSubmitted: _send,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                child: IconButton(icon: const Icon(Icons.send, size: 20, color: Colors.white), onPressed: () => _send(_ctrl.text)),
              ),
            ]),
          )
        else
          // 未连接状态输入栏：禁用状态引导用户
          Container(
            decoration: BoxDecoration(color: theme.colorScheme.surface, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 2, offset: const Offset(0, -1))]),
            padding: EdgeInsets.fromLTRB(8, 8, 8, MediaQuery.of(ctx).padding.bottom + 8),
            child: Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('请先在首页输入连接码绑定 PC 设备'),
                        duration: Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Text('连接 PC 设备后可发送消息', style: TextStyle(color: Colors.grey, fontSize: 14)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(color: Colors.grey.shade300, shape: BoxShape.circle),
                child: const IconButton(icon: Icon(Icons.send, size: 20, color: Colors.white), onPressed: null),
              ),
            ]),
          ),
      ]),
    );
  }

  void _send(String t) {
    if (t.trim().isEmpty) return;
    final s = ref.read(messageProvider);
    if (!s.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先在首页输入连接码绑定 PC 设备后再发送消息'),
          duration: Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    ref.read(messageProvider.notifier).sendText(t);
    _ctrl.clear();
    _shouldScrollDown = true;
    _scrollDown();
  }

  Widget _bubble(ThemeData t, ChatMessage m, MessageNotifier n) {
    final me = m.isFromMe;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!me) ...[
            CircleAvatar(radius: 18, backgroundColor: t.colorScheme.primary.withOpacity(0.1), child: const Icon(Icons.person, size: 20)),
            const SizedBox(width: 8),
          ],
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
            decoration: BoxDecoration(
              color: me ? const Color(0xFF95EC69) : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16), topRight: const Radius.circular(16),
                bottomLeft: me ? const Radius.circular(16) : const Radius.circular(4),
                bottomRight: me ? const Radius.circular(4) : const Radius.circular(16),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m.isText) Text(m.text ?? '', style: const TextStyle(fontSize: 16, height: 1.4)),
              if (m.isFile) _fileCard(m, n, me),
              const SizedBox(height: 4),
              // 时间 + 状态行
              Row(mainAxisSize: MainAxisSize.min, children: [
                // 状态图标
                if (me && m.isText) _statusIcon(m),
                if (me && m.isFile) _statusIcon(m),
                const SizedBox(width: 4),
                Text('${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 11, color: Colors.black38)),
              ]),
              // 状态文字（飞书风格）
              if (me) _statusLabel(m),
            ]),
          ),
          if (me) const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 飞书风格的状态图标
  Widget _statusIcon(ChatMessage m) {
    if (m.isFailed) {
      return const Icon(Icons.error_outline, size: 14, color: Colors.red);
    }
    if (m.isSending) {
      return const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5));
    }
    if (m.readStatus == ReadStatus.read) {
      return const Icon(Icons.done_all, size: 14, color: Color(0xFF3370FF));
    }
    if (m.status == MessageStatus.sent) {
      return const Icon(Icons.check, size: 14, color: Colors.black38);
    }
    return const SizedBox.shrink();
  }

  /// 状态文字（发送中 / 已发送 / 已读 / 发送失败）
  Widget _statusLabel(ChatMessage m) {
    String text = '';
    Color color = Colors.black38;
    if (m.isFailed) {
      text = '发送失败';
      color = Colors.red;
    } else if (m.isSending) {
      text = '发送中';
      color = Colors.black38;
    } else if (m.readStatus == ReadStatus.read) {
      text = '已读';
      color = const Color(0xFF3370FF);
    } else if (m.status == MessageStatus.sent) {
      text = '已发送';
      color = Colors.black38;
    }
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _fileCard(ChatMessage m, MessageNotifier n, bool me) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.insert_drive_file, size: 28),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.fileName ?? '文件', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(m.fileSizeFormatted.isNotEmpty ? m.fileSizeFormatted : '', style: const TextStyle(fontSize: 12, color: Colors.black45)),
        ])),
      ]),
      if (m.isTransferring) ...[
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: m.progress, minHeight: 5)),
        const SizedBox(height: 4),
        Text('${(m.progress * 100).toInt()}%', style: const TextStyle(fontSize: 12, color: Colors.black45)),
        if (me) TextButton(onPressed: () => n.cancelTransfer(m.id), child: const Text('取消', style: TextStyle(fontSize: 12))),
      ],
      if (m.isCompleted) ...[
        const SizedBox(height: 6),
        const Text('✓ 已接收', style: TextStyle(fontSize: 12, color: Colors.green)),
        if (!me) ...[
          if (m.filePath != null) ...[
            const SizedBox(height: 4),
            // 下载路径（可点击复制）
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.filePath!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('路径已复制'), duration: Duration(seconds: 1), behavior: SnackBarBehavior.floating),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.folder_open, size: 14, color: Colors.black54),
                  const SizedBox(width: 4),
                  Flexible(child: Text(m.filePath!, style: const TextStyle(fontSize: 10, color: Colors.black54), maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              // 打开文件按钮
              TextButton.icon(
                onPressed: () => openFile(m.filePath!),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('打开', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
              const SizedBox(width: 8),
              // 复制路径按钮
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: m.filePath!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('路径已复制'), duration: Duration(seconds: 1), behavior: SnackBarBehavior.floating),
                  );
                },
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('复制', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
            ]),
          ] else ...[
            // filePath 为空（如 Web 平台下载），显示简要提示
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle_outline, size: 14, color: Colors.black54),
                SizedBox(width: 4),
                Text('文件已保存', style: TextStyle(fontSize: 10, color: Colors.black54)),
              ]),
            ),
          ],
        ],
      ],
    ]);
  }
}
