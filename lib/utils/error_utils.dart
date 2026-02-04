import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../services/network/exceptions/api_exception.dart';

/// 错误信息工具类
/// 将各种异常转换为用户友好的错误提示
class ErrorUtils {
  /// 获取用户友好的错误消息
  static String getFriendlyMessage(Object? error) {
    if (error == null) return '未知错误';

    // 自定义异常（已经有友好的 toString）
    if (error is RateLimitException ||
        error is ServerException ||
        error is CfChallengeException) {
      return error.toString();
    }

    // Dio 异常
    if (error is DioException) {
      return _handleDioException(error);
    }

    // 网络相关异常
    if (error is SocketException) {
      return '网络连接失败，请检查网络设置';
    }
    if (error is TimeoutException) {
      return '请求超时，请稍后重试';
    }
    if (error is HttpException) {
      return '网络请求失败';
    }

    // 通用 Exception
    if (error is Exception) {
      final message = error.toString();
      // 移除 "Exception: " 前缀
      if (message.startsWith('Exception: ')) {
        return message.substring(11);
      }
      return message;
    }

    return error.toString();
  }

  /// 获取完整的错误详情（用于调试）
  static String getErrorDetails(Object? error, [StackTrace? stackTrace]) {
    final buffer = StringBuffer();
    
    buffer.writeln('错误类型: ${error.runtimeType}');
    buffer.writeln('错误信息: $error');
    
    if (error is DioException) {
      buffer.writeln('');
      buffer.writeln('=== 请求详情 ===');
      buffer.writeln('URL: ${error.requestOptions.uri}');
      buffer.writeln('方法: ${error.requestOptions.method}');
      if (error.response != null) {
        buffer.writeln('状态码: ${error.response?.statusCode}');
        buffer.writeln('响应: ${error.response?.data}');
      }
    }
    
    if (stackTrace != null) {
      buffer.writeln('');
      buffer.writeln('=== 堆栈跟踪 ===');
      buffer.writeln(stackTrace.toString());
    }
    
    return buffer.toString();
  }

  static String _handleDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '请求超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络设置';
      case DioExceptionType.badResponse:
        return _handleHttpStatus(error.response?.statusCode);
      case DioExceptionType.cancel:
        return '请求已取消';
      default:
        // 尝试从响应中提取错误信息
        final data = error.response?.data;
        if (data is Map) {
          final errorMsg = data['error'] ?? data['message'];
          if (errorMsg is String && errorMsg.isNotEmpty) {
            return errorMsg;
          }
          final errors = data['errors'];
          if (errors is List && errors.isNotEmpty) {
            return errors.first.toString();
          }
        }
        return '网络请求失败';
    }
  }

  static String _handleHttpStatus(int? statusCode) {
    switch (statusCode) {
      case 400:
        return '请求参数错误';
      case 401:
        return '未登录或登录已过期';
      case 403:
        return '没有权限访问';
      case 404:
        return '内容不存在或已被删除';
      case 410:
        return '内容已被删除';
      case 422:
        return '请求无法处理';
      case 429:
        return '请求过于频繁，请稍后再试';
      case 500:
        return '服务器内部错误';
      case 502:
      case 503:
      case 504:
        return '服务器暂时不可用，请稍后重试';
      default:
        return '请求失败 ($statusCode)';
    }
  }
}
