import 'dart:async';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Cookie 同步服务
/// 简化版：只管理 CSRF token
class CookieSyncService {
  static final CookieSyncService _instance = CookieSyncService._internal();
  factory CookieSyncService() => _instance;
  CookieSyncService._internal();

  static const String _csrfTokenKey = 'linux_do_csrf_token';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  String? _csrfToken;

  String? get csrfToken => _csrfToken;

  /// 初始化：从本地存储恢复 CSRF token
  Future<void> init() async {
    final raw = await _storage.read(key: _csrfTokenKey);
    if (raw != null && raw.isNotEmpty) {
      _csrfToken = raw;
    }
  }

  void setCsrfToken(String? token) {
    if (token == null || token.isEmpty) return;
    _csrfToken = token;
    unawaited(_storage.write(key: _csrfTokenKey, value: token));
  }

  /// 重置（登出时调用）
  Future<void> reset() async {
    _csrfToken = null;
    await _storage.delete(key: _csrfTokenKey);
  }
}
