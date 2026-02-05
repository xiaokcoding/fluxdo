import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

import '../doh/network_settings_service.dart';
import '../proxy/proxy_settings_service.dart';
import 'cronet_fallback_service.dart';
import 'network_http_adapter.dart';
import 'webview_http_adapter.dart';

/// 当前使用的适配器类型
enum AdapterType {
  webview, // WebView 适配器（Windows）
  native, // Native 适配器（Cronet/Cupertino）
  network, // Network 适配器（通过代理）
}

/// 全局变量：记录当前使用的适配器类型
AdapterType? _currentAdapterType;

/// 获取当前使用的适配器类型
AdapterType? getCurrentAdapterType() => _currentAdapterType;

/// 获取适配器类型的显示名称
String getAdapterDisplayName(AdapterType type) {
  switch (type) {
    case AdapterType.webview:
      return 'WebView 适配器';
    case AdapterType.native:
      return Platform.isAndroid ? 'Cronet 适配器' : 'Cupertino 适配器';
    case AdapterType.network:
      return 'Network 适配器';
  }
}

/// 配置平台适配器
void configurePlatformAdapter(Dio dio) {
  final settings = NetworkSettingsService.instance;
  final proxySettings = ProxySettingsService.instance;
  final fallbackService = CronetFallbackService.instance;

  if (Platform.isWindows) {
    // Windows: 始终使用 WebView 适配器
    _configureWebViewAdapter(dio);
    _currentAdapterType = AdapterType.webview;
  } else if (proxySettings.current.isValid) {
    // 用户 HTTP 代理启用: 使用 NetworkHttpAdapter
    debugPrint('[DIO] Using NetworkHttpAdapter (HTTP Proxy)');
    _configureNetworkAdapter(dio, settings, proxySettings);
    _currentAdapterType = AdapterType.network;
  } else if (settings.current.dohEnabled) {
    // DOH 启用: 使用 NetworkHttpAdapter
    _configureNetworkAdapter(dio, settings, proxySettings);
    _currentAdapterType = AdapterType.network;
  } else if (fallbackService.hasFallenBack) {
    // 已降级: 使用 NetworkHttpAdapter
    debugPrint('[DIO] Using NetworkHttpAdapter (fallback from Cronet)');
    _configureNetworkAdapter(dio, settings, proxySettings);
    _currentAdapterType = AdapterType.network;
  } else {
    // 默认: 使用 NativeAdapter
    // 注意: 调试模式下使用 IOHttpClientAdapter 避免热重启崩溃
    if (kDebugMode && (Platform.isMacOS || Platform.isIOS)) {
      // 调试模式下使用默认适配器，避免 native_dio_adapter 热重启崩溃
      debugPrint('[DIO] Using IOHttpClientAdapter on ${Platform.operatingSystem} (debug mode)');
      _currentAdapterType = AdapterType.native;
    } else {
      dio.httpClientAdapter = NativeAdapter();
      debugPrint('[DIO] Using NativeAdapter on ${Platform.operatingSystem}');
      _currentAdapterType = AdapterType.native;
    }
  }
}

/// 配置 WebView 适配器
void _configureWebViewAdapter(Dio dio) {
  final adapter = WebViewHttpAdapter();
  dio.httpClientAdapter = adapter;
  adapter.initialize().then((_) {
    debugPrint('[DIO] Using WebViewHttpAdapter on Windows');
  }).catchError((e) {
    debugPrint('[DIO] WebViewHttpAdapter init failed: $e');
  });
}

/// 配置 Network 适配器
void _configureNetworkAdapter(Dio dio, NetworkSettingsService settings, ProxySettingsService proxySettings) {
  dio.httpClientAdapter = NetworkHttpAdapter(settings, proxySettings);
  debugPrint('[DIO] Using NetworkHttpAdapter on ${Platform.operatingSystem}');
}

/// 根据当前设置重新配置适配器
void reconfigurePlatformAdapter(Dio dio) {
  dio.httpClientAdapter.close();
  configurePlatformAdapter(dio);
}
