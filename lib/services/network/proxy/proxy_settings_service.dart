import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// HTTP 代理设置数据模型
class ProxySettings {
  const ProxySettings({
    this.enabled = false,
    this.host = '',
    this.port = 0,
    this.username,
    this.password,
  });

  /// 是否启用 HTTP 代理
  final bool enabled;
  /// 代理服务器地址
  final String host;
  /// 代理服务器端口
  final int port;
  /// 用户名（可选）
  final String? username;
  /// 密码（可选）
  final String? password;

  /// 代理是否有效配置
  bool get isValid => enabled && host.isNotEmpty && port > 0;

  ProxySettings copyWith({
    bool? enabled,
    String? host,
    int? port,
    String? username,
    String? password,
  }) {
    return ProxySettings(
      enabled: enabled ?? this.enabled,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }
}

/// HTTP 代理设置服务（独立于 DOH）
class ProxySettingsService {
  ProxySettingsService._internal();

  static final ProxySettingsService instance = ProxySettingsService._internal();

  static const _enabledKey = 'http_proxy_enabled';
  static const _hostKey = 'http_proxy_host';
  static const _portKey = 'http_proxy_port';
  static const _usernameKey = 'http_proxy_username';
  static const _passwordKey = 'http_proxy_password';

  final ValueNotifier<ProxySettings> notifier = ValueNotifier(
    const ProxySettings(),
  );

  SharedPreferences? _prefs;
  int _version = 0;

  /// 版本号，用于触发适配器重建
  int get version => _version;

  ProxySettings get current => notifier.value;

  /// 启用代理时的回调，用于通知其他服务（如 DOH）
  VoidCallback? onProxyEnabled;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;

    final enabled = prefs.getBool(_enabledKey) ?? false;
    final host = prefs.getString(_hostKey) ?? '';
    final port = prefs.getInt(_portKey) ?? 0;
    final username = prefs.getString(_usernameKey);
    final password = prefs.getString(_passwordKey);

    notifier.value = ProxySettings(
      enabled: enabled,
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }

  /// 启用/禁用 HTTP 代理
  Future<void> setEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;

    notifier.value = notifier.value.copyWith(enabled: enabled);
    await prefs.setBool(_enabledKey, enabled);

    // 启用代理时通知其他服务
    if (enabled) {
      onProxyEnabled?.call();
    }

    _touch();
  }

  /// 设置代理服务器地址和端口
  Future<void> setServer({
    required String host,
    required int port,
    String? username,
    String? password,
  }) async {
    final prefs = _prefs;
    if (prefs == null) return;

    notifier.value = notifier.value.copyWith(
      host: host,
      port: port,
      username: username,
      password: password,
    );

    await prefs.setString(_hostKey, host);
    await prefs.setInt(_portKey, port);

    if (username != null && username.isNotEmpty) {
      await prefs.setString(_usernameKey, username);
    } else {
      await prefs.remove(_usernameKey);
    }

    if (password != null && password.isNotEmpty) {
      await prefs.setString(_passwordKey, password);
    } else {
      await prefs.remove(_passwordKey);
    }

    _touch();
  }

  /// 关闭代理（供外部调用，如 DOH 启用时）
  Future<void> disable() async {
    if (!current.enabled) return;
    await setEnabled(false);
  }

  void _touch() {
    _version++;
    notifier.value = notifier.value.copyWith();
  }
}
