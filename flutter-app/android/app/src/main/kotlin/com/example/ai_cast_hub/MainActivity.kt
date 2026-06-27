package com.example.ai_cast_hub

import io.flutter.embedding.android.FlutterActivity

/**
 * MainActivity — 使用 flutter_webrtc 内置的屏幕捕获能力。
 *
 * flutter_webrtc 插件通过其自身的 FlutterWebRTCPlugin 注册 MethodChannel，
 * 并在内部处理 MediaProjection 权限请求和 ForegroundService 生命周期。
 * 无需在此 Activity 中额外处理 MethodChannel 或 onActivityResult。
 */
class MainActivity : FlutterActivity()
