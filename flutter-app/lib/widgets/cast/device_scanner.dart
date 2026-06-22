import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';

/// 二维码扫码组件
///
/// 基于 qr_code_scanner，扫描成功后振动反馈并弹窗确认。
class DeviceScanner extends StatefulWidget {
  final ValueChanged<String> onDeviceScanned; // 回调解码后的设备 UUID

  const DeviceScanner({
    super.key,
    required this.onDeviceScanned,
  });

  @override
  State<DeviceScanner> createState() => _DeviceScannerState();
}

class _DeviceScannerState extends State<DeviceScanner>
    with WidgetsBindingObserver {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? _controller;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null) return;
    if (state == AppLifecycleState.resumed) {
      _controller!.resumeCamera();
    } else if (state == AppLifecycleState.paused) {
      _controller!.pauseCamera();
    }
  }

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    controller.scannedDataStream.listen(_onScan);
  }

  void _onScan(Barcode barcode) {
    if (_isProcessing || barcode.code == null) return;

    final code = barcode.code!;
    _isProcessing = true;

    try {
      final data = jsonDecode(code) as Map<String, dynamic>;
      final deviceUuid = data['deviceUuid'] as String?;
      final roomType = data['roomType'] as String?;

      if (deviceUuid != null && deviceUuid.isNotEmpty) {
        // 暂停扫描
        _controller?.pauseCamera();

        // 振动反馈（平台相关，此处使用简化方式）
        _showConfirmDialog(deviceUuid, roomType);
      } else {
        _isProcessing = false;
      }
    } catch (_) {
      // JSON 解析失败，不是有效二维码
      _isProcessing = false;
    }
  }

  void _showConfirmDialog(String deviceUuid, String? roomType) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('扫描成功'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('设备 UUID: ${deviceUuid.truncate(20)}'),
            if (roomType != null) ...[
              const SizedBox(height: 8),
              Text('类型: $roomType'),
            ],
            const SizedBox(height: 12),
            const Text('是否连接到此设备？'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _isProcessing = false;
              _controller?.resumeCamera();
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDeviceScanned(deviceUuid);
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        QRView(
          key: _qrKey,
          onQRViewCreated: _onQRViewCreated,
          overlay: QrScannerOverlayShape(
            borderColor: Theme.of(context).colorScheme.primary,
            borderRadius: 12,
            borderLength: 30,
            borderWidth: 10,
            cutOutSize: 280,
          ),
        ),
        Positioned(
          bottom: 40,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              '将二维码对准框内扫描',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }
}

/// String 扩展（就地定义，避免额外 import）
extension _StringExtension on String {
  String truncate(int maxLength) {
    if (length <= maxLength) return this;
    return '${substring(0, maxLength)}...';
  }
}
