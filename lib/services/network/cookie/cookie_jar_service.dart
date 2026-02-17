import 'dart:io' as io;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../../../constants.dart';
import '../../cf_challenge_logger.dart';

/// 统一的 Cookie 管理服务
/// 使用 cookie_jar 库管理 Cookie，支持持久化和 WebView 同步
class CookieJarService {
  static final CookieJarService _instance = CookieJarService._internal();
  factory CookieJarService() => _instance;
  CookieJarService._internal();

  CookieJar? _cookieJar;
  bool _initialized = false;
  final _webViewCookieManager = CookieManager.instance();

  /// 获取 CookieJar 实例（用于 Dio CookieManager）
  CookieJar get cookieJar {
    if (_cookieJar == null) {
      throw StateError('CookieJarService not initialized. Call initialize() first.');
    }
    return _cookieJar!;
  }

  /// 是否已初始化
  bool get isInitialized => _initialized;

  /// 初始化 CookieJar（应用启动时调用）
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final cookiePath = path.join(directory.path, '.cookies');

      // 确保目录存在
      final cookieDir = io.Directory(cookiePath);
      if (!await cookieDir.exists()) {
        await cookieDir.create(recursive: true);
      }

      _cookieJar = PersistCookieJar(
        ignoreExpires: false, // 不忽略过期时间，自动清理过期 Cookie
        storage: FileStorage(cookiePath),
      );

      _initialized = true;
      debugPrint('[CookieJar] Initialized with path: $cookiePath');
    } catch (e) {
      // 降级为内存 Cookie 管理
      debugPrint('[CookieJar] Failed to create persistent storage, using memory: $e');
      _cookieJar = CookieJar();
      _initialized = true;
    }
  }

  /// 从 WebView 同步 Cookie 到 CookieJar
  Future<void> syncFromWebView() async {
    if (!_initialized) await initialize();

    try {
      final webViewCookies = await _webViewCookieManager.getCookies(
        url: WebUri(AppConstants.baseUrl),
      );
      
      debugPrint('[CookieJar] Got ${webViewCookies.length} cookies from WebView for ${AppConstants.baseUrl}');

      // 记录到 CF 日志
      if (CfChallengeLogger.isEnabled) {
        final cookieEntries = webViewCookies.map((wc) => CookieLogEntry(
          name: wc.name,
          domain: wc.domain,
          path: wc.path,
          expires: wc.expiresDate != null
              ? DateTime.fromMillisecondsSinceEpoch(wc.expiresDate!.toInt())
              : null,
          valueLength: wc.value.length,
        )).toList();
        CfChallengeLogger.logCookieSync(
          direction: 'WebView -> CookieJar',
          cookies: cookieEntries,
        );
      }

      if (webViewCookies.isEmpty) {
        debugPrint('[CookieJar] No cookies from WebView after filtering');
        return;
      }

      // 打印每个 cookie 的详细信息
      for (final wc in webViewCookies) {
        debugPrint('[CookieJar] WebView cookie: ${wc.name} domain=${wc.domain} valueLen=${wc.value.length}');
      }

      final baseUri = Uri.parse(AppConstants.baseUrl);

      // 不需要完全删除，否则会丢失 WebView 中不存在但 App 中存在的 Session Cookie（针对 Host-only type）
      // await _cookieJar!.delete(baseUri, true);
      // form: delete(uri, true);

      // 按域名 + path + name 去重，避免跨子域覆盖
      final bucketedCookies = <Uri, Map<String, io.Cookie>>{};

      for (final wc in webViewCookies) {
        final rawDomain = wc.domain?.trim();
        String? domainAttr;
        String hostForUri = baseUri.host;

        if (rawDomain != null && rawDomain.isNotEmpty) {
          if (rawDomain.startsWith('.')) {
            domainAttr = rawDomain;
            hostForUri = rawDomain.substring(1);
          } else {
            // Host-only cookie，保留原始 host
            hostForUri = rawDomain;
          }
        }

        // Dart Cookie 构造函数对值有严格校验（不允许双引号等），
        // 但浏览器允许 JSON 等特殊值。用 fromSetCookieValue 绕过校验保留原始值。
        io.Cookie cookie;
        try {
          cookie = io.Cookie(wc.name, wc.value)
            ..path = wc.path ?? '/';
        } catch (_) {
          cookie = io.Cookie.fromSetCookieValue('${wc.name}=${wc.value}')
            ..path = wc.path ?? '/';
        }

        if (domainAttr != null) {
          cookie.domain = domainAttr;
        }

        if (wc.expiresDate != null) {
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(wc.expiresDate!.toInt());
        }

        final bucketUri = Uri(scheme: baseUri.scheme, host: hostForUri);
        final dedupeKey = '${cookie.name}|${cookie.path}|${cookie.domain ?? hostForUri}';
        final bucket = bucketedCookies.putIfAbsent(bucketUri, () => <String, io.Cookie>{});
        bucket[dedupeKey] = cookie;
      }

      var totalSynced = 0;
      for (final entry in bucketedCookies.entries) {
        final cookies = entry.value.values.toList();
        if (cookies.isEmpty) continue;
        await _cookieJar!.saveFromResponse(entry.key, cookies);
        totalSynced += cookies.length;
      }

      debugPrint('[CookieJar] Synced $totalSynced cookies from WebView (deduplicated from ${webViewCookies.length})');
    } catch (e) {
      debugPrint('[CookieJar] Failed to sync from WebView: $e');
    }
  }

  /// 从 CookieJar 同步 Cookie 到 WebView
  Future<void> syncToWebView() async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      // 先清除 WebView 中该 URL 的所有 cookie，避免遗留旧 cookie 导致重复
      await _webViewCookieManager.deleteCookies(url: WebUri(AppConstants.baseUrl));
      debugPrint('[CookieJar] Cleared WebView cookies before sync');

      if (cookies.isEmpty) {
        debugPrint('[CookieJar] No cookies to sync to WebView');
        if (CfChallengeLogger.isEnabled) {
          CfChallengeLogger.logCookieSync(
            direction: 'CookieJar -> WebView',
            cookies: [],
          );
        }
        return;
      }

      // 记录到 CF 日志
      if (CfChallengeLogger.isEnabled) {
        final cookieEntries = cookies.map((c) => CookieLogEntry(
          name: c.name,
          domain: c.domain,
          path: c.path,
          expires: c.expires,
          valueLength: c.value.length,
        )).toList();
        CfChallengeLogger.logCookieSync(
          direction: 'CookieJar -> WebView',
          cookies: cookieEntries,
        );
      }

      for (final cookie in cookies) {
        await _webViewCookieManager.setCookie(
          url: WebUri(AppConstants.baseUrl),
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path ?? '/',
          isSecure: cookie.secure,
          isHttpOnly: cookie.httpOnly,
          expiresDate: cookie.expires?.millisecondsSinceEpoch,
        );
      }

      debugPrint('[CookieJar] Synced ${cookies.length} cookies to WebView');
    } catch (e) {
      debugPrint('[CookieJar] Failed to sync to WebView: $e');
    }
  }

  /// 获取指定 Cookie 的值
  Future<String?> getCookieValue(String name) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      for (final cookie in cookies) {
        if (cookie.name == name) {
          return cookie.value;
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie $name: $e');
    }
    return null;
  }

  /// 设置 Cookie
  Future<void> setCookie(String name, String value, {
    String? domain,
    String? path,
    DateTime? expires,
    bool secure = true,
    bool httpOnly = false,
  }) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookie = io.Cookie(name, value)
        ..path = path ?? '/';
      
      // 只有当 domain 以点开头时才设置，否则保持 null（host-only cookie）
      if (domain != null && domain.startsWith('.')) {
        cookie.domain = domain;
      }

      if (expires != null) {
        cookie.expires = expires;
      }

      await _cookieJar!.saveFromResponse(uri, [cookie]);
      debugPrint('[CookieJar] Set cookie: $name');
    } catch (e) {
      debugPrint('[CookieJar] Failed to set cookie $name: $e');
    }
  }

  /// 删除指定 Cookie
  Future<void> deleteCookie(String name) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);

      // 设置过期时间为过去，让 cookie_jar 自动清理
      // 不设置 domain（保持 null），匹配 hostCookies 中的 cookie
      final expiredCookie = io.Cookie(name, '')
        ..path = '/'
        ..expires = DateTime.now().subtract(const Duration(days: 1));

      await _cookieJar!.saveFromResponse(uri, [expiredCookie]);
      debugPrint('[CookieJar] Deleted cookie: $name');
    } catch (e) {
      debugPrint('[CookieJar] Failed to delete cookie $name: $e');
    }
  }

  /// 清除所有 Cookie
  Future<void> clearAll() async {
    if (!_initialized) return;

    try {
      await _cookieJar!.deleteAll();
      await _webViewCookieManager.deleteAllCookies();
      debugPrint('[CookieJar] Cleared all cookies');
    } catch (e) {
      debugPrint('[CookieJar] Failed to clear cookies: $e');
    }
  }

  /// 获取所有 Cookie 的字符串形式（用于请求头）
  Future<String?> getCookieHeader() async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      if (cookies.isEmpty) return null;

      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie header: $e');
      return null;
    }
  }

  /// 获取 _t token
  Future<String?> getTToken() => getCookieValue('_t');

  /// 获取 cf_clearance
  Future<String?> getCfClearance() => getCookieValue('cf_clearance');

  /// 设置 _t token
  Future<void> setTToken(String value) => setCookie('_t', value);

  /// 设置 cf_clearance
  Future<void> setCfClearance(String value) => setCookie('cf_clearance', value);
}
