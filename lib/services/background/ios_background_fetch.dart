import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../local_notification_service.dart';
import '../network/cookie/cookie_jar_service.dart';
import '../network/cookie/cookie_sync_service.dart';
import '../network/discourse_dio.dart';
import '../../models/notification.dart';

/// iOS 后台任务标识符
const String kNotificationPollTask = 'com.fluxdo.notificationPoll';

/// SharedPreferences 键名
const String _kUserId = 'bg_notification_user_id';
const String _kLastMessageId = 'bg_notification_last_message_id';

/// iOS 后台拉取回调（顶层函数，由 workmanager 在独立 Isolate 中调用）
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      debugPrint('[iOSBgFetch] 开始执行后台任务: $taskName');

      // 1. 初始化 Cookie 相关服务
      await CookieJarService().initialize();
      await CookieSyncService().init();

      // 2. 从 SharedPreferences 读取 userId 和 lastMessageId
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt(_kUserId);
      if (userId == null) {
        debugPrint('[iOSBgFetch] 未找到 userId，跳过');
        return true;
      }

      final lastMessageId = prefs.getInt(_kLastMessageId) ?? -1;
      final channel = '/notification-alert/$userId';

      // 3. 创建临时 Dio，短超时单次轮询
      final dio = DiscourseDio.create(
        receiveTimeout: const Duration(seconds: 10),
        defaultHeaders: {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      );

      // 生成简单的 clientId
      final clientId = 'ios_bg_${DateTime.now().millisecondsSinceEpoch}';

      final response = await dio.post<String>(
        '/message-bus/$clientId/poll',
        data: {channel: lastMessageId.toString()},
      );

      if (response.data == null || response.data!.isEmpty) {
        debugPrint('[iOSBgFetch] 无新消息');
        return true;
      }

      // 4. 解析消息
      final parsed = jsonDecode(response.data!);
      if (parsed is! List) return true;

      int newLastMessageId = lastMessageId;

      // 初始化通知服务
      await LocalNotificationService().initialize();

      for (final item in parsed) {
        if (item is! Map<String, dynamic>) continue;

        final msgChannel = item['channel'] as String?;
        final messageId = item['message_id'] as int?;
        final data = item['data'];

        if (msgChannel == channel && data is Map<String, dynamic>) {
          // 更新 lastMessageId
          if (messageId != null && messageId > newLastMessageId) {
            newLastMessageId = messageId;
          }

          // 弹出系统通知
          final topicTitle = data['topic_title'] as String? ?? '';
          final topicId = data['topic_id'] as int?;
          final postNumber = data['post_number'] as int?;
          final excerpt = data['excerpt'] as String? ?? '';
          final username = data['username'] as String? ?? '';
          final notificationType = data['notification_type'] as int?;

          String title = topicTitle;
          if (title.isEmpty) {
            title = notificationType != null
                ? NotificationType.fromId(notificationType).label
                : '新通知';
          }

          String body = excerpt;
          if (body.isEmpty && username.isNotEmpty) {
            body = username;
          }

          await LocalNotificationService().show(
            title: title,
            body: body,
            topicId: topicId,
            postNumber: postNumber,
          );
        }
      }

      // 5. 持久化 lastMessageId
      if (newLastMessageId > lastMessageId) {
        await prefs.setInt(_kLastMessageId, newLastMessageId);
        debugPrint('[iOSBgFetch] 更新 lastMessageId: $newLastMessageId');
      }

      debugPrint('[iOSBgFetch] 后台任务完成');
      return true;
    } catch (e, stack) {
      debugPrint('[iOSBgFetch] 后台任务失败: $e');
      debugPrint('[iOSBgFetch] $stack');
      return false;
    }
  });
}

/// 保存 userId 到 SharedPreferences（主 Isolate 调用）
Future<void> saveBackgroundUserId(int userId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kUserId, userId);
}

/// 保存 lastMessageId 到 SharedPreferences（主 Isolate 调用）
Future<void> saveBackgroundLastMessageId(int lastMessageId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kLastMessageId, lastMessageId);
}
