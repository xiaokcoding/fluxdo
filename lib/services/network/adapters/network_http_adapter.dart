import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../network_logger.dart';
import '../doh/network_settings_service.dart';
import '../proxy/proxy_settings_service.dart';

class NetworkHttpAdapter implements HttpClientAdapter {
  NetworkHttpAdapter(this._settings, this._proxySettings);

  final NetworkSettingsService _settings;
  final ProxySettingsService _proxySettings;
  HttpClient? _cachedClient;
  int _cachedVersion = -1;
  int _cachedProxyVersion = -1;
  bool _closed = false;
  bool _cachedProxyCaEnabled = false;
  Uint8List? _proxyCaBytes;
  Future<void>? _proxyCaLoad;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) {
      throw StateError("Can't establish connection after the adapter was closed.");
    }
    return _fetch(options, requestStream, cancelFuture);
  }

  Future<ResponseBody> _fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await _ensureProxyCaLoaded();
    final httpClient = _configHttpClient(options.connectTimeout);
    final reqFuture = httpClient.openUrl(options.method, options.uri);
    late HttpClientRequest request;
    try {
      final connectionTimeout = options.connectTimeout;
      if (connectionTimeout != null && connectionTimeout > Duration.zero) {
        request = await reqFuture.timeout(
          connectionTimeout,
          onTimeout: () {
            throw DioException.connectionTimeout(
              requestOptions: options,
              timeout: connectionTimeout,
            );
          },
        );
      } else {
        request = await reqFuture;
      }

      final requestWR = WeakReference<HttpClientRequest>(request);
      cancelFuture?.whenComplete(() {
        requestWR.target?.abort();
      });

      options.headers.forEach((key, value) {
        if (value != null) {
          request.headers.set(
            key,
            value,
            preserveHeaderCase: options.preserveHeaderCase,
          );
        }
      });
    } on SocketException catch (e) {
      if (e.message.contains('timed out')) {
        final Duration effectiveTimeout;
        if (options.connectTimeout != null &&
            options.connectTimeout! > Duration.zero) {
          effectiveTimeout = options.connectTimeout!;
        } else if (httpClient.connectionTimeout != null &&
            httpClient.connectionTimeout! > Duration.zero) {
          effectiveTimeout = httpClient.connectionTimeout!;
        } else {
          effectiveTimeout = Duration.zero;
        }
        throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: effectiveTimeout,
          error: e,
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: e.message,
        error: e,
      );
    }

    request.followRedirects = options.followRedirects;
    request.maxRedirects = options.maxRedirects;
    request.persistentConnection = options.persistentConnection;

    if (requestStream != null) {
      Future<dynamic> future = request.addStream(requestStream);
      final sendTimeout = options.sendTimeout;
      if (sendTimeout != null && sendTimeout > Duration.zero) {
        future = future.timeout(
          sendTimeout,
          onTimeout: () {
            request.abort();
            throw DioException.sendTimeout(
              timeout: sendTimeout,
              requestOptions: options,
            );
          },
        );
      }
      await future;
    }

    Future<HttpClientResponse> future = request.close();
    final receiveTimeout = options.receiveTimeout ?? Duration.zero;
    if (receiveTimeout > Duration.zero) {
      future = future.timeout(
        receiveTimeout,
        onTimeout: () {
          request.abort();
          throw DioException.receiveTimeout(
            timeout: receiveTimeout,
            requestOptions: options,
          );
        },
      );
    }
    final responseStream = await future;

    final headers = <String, List<String>>{};
    responseStream.headers.forEach((key, values) {
      headers[key] = values;
    });
    return ResponseBody(
      responseStream.cast(),
      responseStream.statusCode,
      headers: headers,
      isRedirect: responseStream.isRedirect || responseStream.redirects.isNotEmpty,
      redirects: responseStream.redirects
          .map((e) => RedirectRecord(e.statusCode, e.method, e.location))
          .toList(),
      statusMessage: responseStream.reasonPhrase,
    );
  }

  HttpClient _configHttpClient(Duration? connectionTimeout) {
    final currentVersion = _settings.version;
    final currentProxyVersion = _proxySettings.version;
    final proxyCaEnabled = _shouldTrustProxyCa();
    if (_cachedClient == null ||
        _cachedVersion != currentVersion ||
        _cachedProxyVersion != currentProxyVersion ||
        _cachedProxyCaEnabled != proxyCaEnabled) {
      _cachedClient?.close(force: true);
      _cachedClient = _createHttpClient();
      _cachedVersion = currentVersion;
      _cachedProxyVersion = currentProxyVersion;
      _cachedProxyCaEnabled = proxyCaEnabled;
    }
    connectionTimeout ??= Duration.zero;
    if (connectionTimeout > Duration.zero) {
      _cachedClient!.connectionTimeout = connectionTimeout;
    } else {
      _cachedClient!.connectionTimeout = null;
    }
    return _cachedClient!;
  }

  HttpClient _createHttpClient() {
    final context = _buildSecurityContext();
    final client = HttpClient(context: context)
      ..idleTimeout = const Duration(seconds: 30);
    final dohSettings = _settings.current;
    final proxySettings = _proxySettings.current;

    // 优先使用用户设置的 HTTP 代理
    if (proxySettings.isValid) {
      final host = proxySettings.host;
      final port = proxySettings.port;
      final proxy = 'PROXY $host:$port';
      client.findProxy = (_) => proxy;

      // 添加代理认证
      final username = proxySettings.username;
      final password = proxySettings.password;
      if (username != null &&
          username.isNotEmpty &&
          password != null &&
          password.isNotEmpty) {
        client.addProxyCredentials(
          host,
          port,
          'Basic',
          HttpClientBasicCredentials(username, password),
        );
      }
      return client;
    }

    // 使用 DOH 代理端口（Rust 代理统一处理 DOH + ECH）
    final proxyPort = dohSettings.proxyPort;
    if (dohSettings.dohEnabled && proxyPort != null) {
      final proxy = 'PROXY 127.0.0.1:$proxyPort';
      client.findProxy = (_) => proxy;
    }

    return client;
  }

  bool _shouldTrustProxyCa() {
    final settings = _settings.current;
    return settings.dohEnabled && settings.proxyPort != null && _proxyCaBytes != null;
  }

  SecurityContext? _buildSecurityContext() {
    if (!_shouldTrustProxyCa()) {
      return null;
    }
    final context = SecurityContext(withTrustedRoots: true);
    try {
      context.setTrustedCertificatesBytes(_proxyCaBytes!);
    } catch (e) {
      NetworkLogger.log('[DOH] 导入代理 CA 失败: $e');
      return null;
    }
    return context;
  }

  Future<void> _ensureProxyCaLoaded() async {
    final settings = _settings.current;
    if (!settings.dohEnabled || settings.proxyPort == null) {
      return;
    }
    if (_proxyCaBytes != null) {
      return;
    }
    _proxyCaLoad ??= _loadProxyCa();
    await _proxyCaLoad;
  }

  Future<void> _loadProxyCa() async {
    try {
      final data = await rootBundle.load('assets/certs/proxy_ca.pem');
      _proxyCaBytes = data.buffer.asUint8List();
    } catch (e) {
      NetworkLogger.log('[DOH] 读取代理 CA 失败: $e');
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _cachedClient?.close(force: force);
  }
}
