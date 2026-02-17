import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../cf_challenge_service.dart';
import '../../cf_challenge_logger.dart';
import '../cookie/cookie_jar_service.dart';
import '../exceptions/api_exception.dart';

/// Cloudflare 验证拦截器
/// 处理 CF Turnstile 验证
class CfChallengeInterceptor extends Interceptor {
  CfChallengeInterceptor({
    required this.dio,
    required this.cookieJarService,
  });

  final Dio dio;
  final CookieJarService cookieJarService;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final statusCode = err.response?.statusCode;
    final data = err.response?.data;

    // 检查是否标记跳过 CF 验证（防止重试后再次触发）
    final skipCfChallenge = err.requestOptions.extra['skipCfChallenge'] == true;

    if (statusCode == 403 &&
        CfChallengeService.isCfChallenge(data) &&
        !skipCfChallenge) {
      final requestUrl = err.requestOptions.uri.toString();
      debugPrint('[Dio] CF Challenge detected, showing manual verify...');
      CfChallengeLogger.logInterceptorDetected(url: requestUrl, statusCode: statusCode!);
      unawaited(CfChallengeLogger.logAccessIps(url: requestUrl, context: 'interceptor'));

      final cfService = CfChallengeService();

      // 检查是否在冷却期
      if (cfService.isInCooldown) {
        debugPrint('[Dio] CF Challenge in cooldown, throwing exception');
        CfChallengeLogger.log('[INTERCEPTOR] Skipped: in cooldown');
        CfChallengeService.showGlobalMessage('安全验证失败，已进入冷却期，请稍后再试');
        throw CfChallengeException(inCooldown: true);
      }

      // 检查请求是否标记为静默（后台验证）
      final isSilent = err.requestOptions.extra['isSilent'] == true;
      // 默认为前台强制验证，除非明确标记为静默
      final forceForeground = !isSilent;
      
      final result = await cfService.showManualVerify(null, forceForeground);

      if (result == true) {
        // 等待 Cookie 从 WebView 引擎 flush 到系统 HTTPCookieStorage
        // iOS/macOS 的 WKWebView 异步写入，需要足够时间
        await Future.delayed(const Duration(milliseconds: 1500));

        // CF 验证成功后从 WebView 同步 Cookie 回 CookieJar
        await cookieJarService.syncFromWebView();

        // 验证 cf_clearance 是否真的保存成功，最多重试 3 次
        String? cfClearance;
        for (var i = 0; i < 3; i++) {
          cfClearance = await cookieJarService.getCfClearance();
          if (cfClearance != null && cfClearance.isNotEmpty) break;
          debugPrint('[Dio] cf_clearance not found, retry ${i + 1}/3...');
          await Future.delayed(const Duration(milliseconds: 500));
          await cookieJarService.syncFromWebView();
        }

        if (cfClearance == null || cfClearance.isEmpty) {
          debugPrint('[Dio] cf_clearance not found after sync, entering cooldown');
          CfChallengeLogger.log('[INTERCEPTOR] cf_clearance not found after sync');
          cfService.startCooldown();
          CfChallengeService.showGlobalMessage('验证未生效，请稍后重试');
          throw CfChallengeException();
        }
        CfChallengeLogger.log('[INTERCEPTOR] cf_clearance verified: ${cfClearance.length} chars');

        // 重试请求，并标记跳过 CF 验证拦截（防止循环）
        try {
          final retryOptions = err.requestOptions;
          retryOptions.extra['skipCfChallenge'] = true;
          // 清除原始请求中残留的 cookie header，让 CookieManager 重新读取最新的 cookie
          retryOptions.headers.remove('cookie');
          retryOptions.headers.remove('Cookie');
          final response = await dio.fetch(retryOptions);
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: true,
            statusCode: response.statusCode,
          );
          return handler.resolve(response);
        } catch (e) {
          debugPrint('[Dio] Retry after CF verify failed: $e');
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: false,
            error: e.toString(),
          );
          // 重试仍然失败，说明验证可能没有真正成功，进入冷却期
          cfService.startCooldown();
          CfChallengeService.showGlobalMessage('验证后请求失败，请稍后重试');
          throw CfChallengeException();
        }
      } else if (result == null) {
        // null 可能是冷却期内，也可能是无 context
        if (cfService.isInCooldown) {
          CfChallengeService.showGlobalMessage('安全验证失败，已进入冷却期，请稍后再试');
          throw CfChallengeException(inCooldown: true);
        }
        // 无 context（应用刚启动，context 还没设置好）
        debugPrint(
            '[Dio] CF Challenge: no context available, cannot show verify page');
        CfChallengeLogger.log('[INTERCEPTOR] No context available');
        CfChallengeService.showGlobalMessage('无法打开验证页面，请稍后重试');
        throw CfChallengeException(); // 通用错误，提示重试
      } else {
        // result == false：用户取消或验证失败
        CfChallengeLogger.log('[INTERCEPTOR] User cancelled or verify failed');
        CfChallengeService.showGlobalMessage('验证未完成，请重试');
        throw CfChallengeException(userCancelled: true);
      }
    }

    handler.next(err);
  }
}
