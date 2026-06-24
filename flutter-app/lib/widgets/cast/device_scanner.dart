import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../utils/extensions.dart';

/// 二维码扫码组件
///
/// 基于 mobile_scanner，扫描成功后弹窗确认。
class DeviceScanner extends StatefulWidget {
  /// 扫码成功回调，返回解析出的扫码数据
  final ValueChanged<ScannedDeviceData> onDeviceScanned;
  /// 扫码原始数据回调，用于实时展示扫描结果
  final void Function(String rawCode, bool isValid, String? info)? onScanResult;

  const DeviceScanner({
    super.key,
    required this.onDeviceScanned,
    this.onScanResult,
  });

  @override
  State<DeviceScanner> createState() => _DeviceScannerState();
}

/// 扫码解析后的设备数据
class ScannedDeviceData {
  final String deviceUuid;
  final String? roomType;
  final String? serverUrl;

  const ScannedDeviceData({
    required this.deviceUuid,
    this.roomType,
    this.serverUrl,
  });

  @override
  String toString() => 'ScannedDeviceData(deviceUuid=$deviceUuid, roomType=$roomType, serverUrl=$serverUrl)';
}

class _DeviceScannerState extends State<DeviceScanner> {
  final MobileScannerController _controller = MobileScannerController();
  bool _isProcessing = false;
  int _scanCount = 0; // 扫描计数，避免重复处理同一个码

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScan(BarcodeCapture capture) {
    if (_isProcessing) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final code = barcode.rawValue!;
    _isProcessing = true;
    _scanCount++;

    // 通知外部扫描结果
    widget.onScanResult?.call(code, false, '正在解析第 $_scanCount 次扫描...');

    try {
      final data = jsonDecode(code) as Map<String, dynamic>;
      final deviceUuid = data['deviceUuid'] as String?;
      final roomType = data['roomType'] as String?;
      final serverUrl = data['serverUrl'] as String?;

      if (deviceUuid != null && deviceUuid.isNotEmpty) {
        // 暂停扫描
        _controller.stop();

        final info = 'UUID: ${deviceUuid.truncate(20)}\n'
            '类型: ${roomType ?? "未知"}\n'
            '服务器: ${serverUrl ?? "未提供"}';
        widget.onScanResult?.call(code, true, info);

        // 弹窗确认
        _showConfirmDialog(deviceUuid, roomType, serverUrl);
      } else {
        widget.onScanResult?.call(
          code,
          false,
          'JSON 中缺少 deviceUuid 字段\n原始数据: ${code.length > 80 ? "${code.substring(0, 80)}..." : code}',
        );
        _isProcessing = false;
      }
    } catch (e) {
      // JSON 解析失败
      widget.onScanResult?.call(
        code,
        false,
        'JSON 解析失败: ${e.toString().length > 60 ? "${e.toString().substring(0, 60)}..." : e}\n'
        '原始: ${code.length > 60 ? "${code.substring(0, 60)}..." : code}',
      );
      _isProcessing = false;
    }
  }

  void _showConfirmDialog(String deviceUuid, String? roomType, String? serverUrl) {
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
            if (serverUrl != null) ...[
              const SizedBox(height: 8),
              Text('服务器: $serverUrl'),
            ],
            const SizedBox(height: 12),
            const Text('是否连接到此设备？'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _isProcessing = false;
              _controller.start();
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDeviceScanned(ScannedDeviceData(
                deviceUuid: deviceUuid,
                roomType: roomType,
                serverUrl: serverUrl,
              ));
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scanWindow = Rect.fromCenter(
      center: const Offset(0, 0),
      width: 280,
      height: 280,
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          controller: _controller,
          scanWindow: scanWindow,
          onDetect: _onScan,
        ),
        // 扫描框边框
        Positioned.fill(
          child: CustomPaint(
            painter: _ScannerOverlayPainter(
              borderColor: theme.colorScheme.primary,
              scanWindow: scanWindow,
            ),
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

/// 自定义扫描框边框绘制
class _ScannerOverlayPainter extends CustomPainter {
  final Color borderColor;
  final Rect scanWindow;

  _ScannerOverlayPainter({
    required this.borderColor,
    required this.scanWindow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: scanWindow.width,
      height: scanWindow.height,
    );

    const cornerLength = 30.0;
    final r = RRect.fromRectAndRadius(rect, const Radius.circular(12));

    void drawCorner(Offset p1, Offset p2, Offset p3) {
      canvas.drawLine(p1, p2, paint);
      canvas.drawLine(p1, p3, paint);
    }

    drawCorner(
      Offset(r.left, r.top),
      Offset(r.left + cornerLength, r.top),
      Offset(r.left, r.top + cornerLength),
    );
    drawCorner(
      Offset(r.right, r.top),
      Offset(r.right - cornerLength, r.top),
      Offset(r.right, r.top + cornerLength),
    );
    drawCorner(
      Offset(r.left, r.bottom),
      Offset(r.left + cornerLength, r.bottom),
      Offset(r.left, r.bottom - cornerLength),
    );
    drawCorner(
      Offset(r.right, r.bottom),
      Offset(r.right - cornerLength, r.bottom),
      Offset(r.right, r.bottom - cornerLength),
    );
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) {
    return borderColor != oldDelegate.borderColor ||
        scanWindow != oldDelegate.scanWindow;
  }
}
