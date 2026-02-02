import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/message_bus_service.dart';
import '../../services/local_notification_service.dart';
import '../../widgets/topic/topic_filter_sheet.dart';
import '../discourse_providers.dart';
import 'message_bus_service_provider.dart';
import 'notification_providers.dart';

/// 话题追踪状态元数据 Provider（MessageBus 频道初始 message ID）
final topicTrackingStateMetaProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getPreloadedTopicTrackingMeta();
});

/// MessageBus 初始化 Notifier
/// 统一管理所有频道的批量订阅，避免串行等待
class MessageBusInitNotifier extends Notifier<void> {
  final Map<String, MessageBusCallback> _allCallbacks = {};
  
  @override
  void build() {
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;
    final metaAsync = ref.watch(topicTrackingStateMetaProvider);
    
    // 清理之前的订阅
    if (_allCallbacks.isNotEmpty) {
      debugPrint('[MessageBusInit] 清理旧订阅: ${_allCallbacks.keys}');
      for (final entry in _allCallbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _allCallbacks.clear();
    }
    
    if (currentUser == null) {
      debugPrint('[MessageBusInit] 用户未登录，跳过订阅');
      return;
    }
    
    final meta = metaAsync.value;
    if (meta == null) {
      debugPrint('[MessageBusInit] topicTrackingStateMeta 未加载');
      return;
    }
    
    // 准备批量订阅数据
    final subscriptions = <String, ({int messageId, MessageBusCallback callback})>{};
    
    // 1. 添加通知频道
    final notificationChannel = '/notification/${currentUser.id}';
    final notificationMessageId = currentUser.notificationChannelPosition;
    
    void onNotification(MessageBusMessage message) {
      final data = message.data;
      if (data is Map<String, dynamic>) {
        final allUnreadCount = data['all_unread_notifications_count'] as int?;
        final unreadCount = data['unread_notifications'] as int?;
        final unreadHighPriority = data['unread_high_priority_notifications'] as int?;
        
        debugPrint('[Notification] 收到 MessageBus 推送: allUnread=$allUnreadCount, unread=$unreadCount, highPriority=$unreadHighPriority');
        
        if (allUnreadCount != null || unreadCount != null || unreadHighPriority != null) {
          ref.read(notificationCountStateProvider.notifier).update(
            allUnread: allUnreadCount,
            unread: unreadCount,
            highPriority: unreadHighPriority,
          );
        }
      }
      ref.invalidate(notificationListProvider);
    }
    
    subscriptions[notificationChannel] = (messageId: notificationMessageId, callback: onNotification);
    _allCallbacks[notificationChannel] = onNotification;
    
    // 2. 添加通知提醒频道（用于系统通知，复刻 Discourse 官方实现）
    final notificationAlertChannel = '/notification-alert/${currentUser.id}';
    
    void onNotificationAlert(MessageBusMessage message) {
      final data = message.data;
      debugPrint('[NotificationAlert] 收到提醒: $data');

      if (data is Map<String, dynamic>) {
        // Discourse payload 格式:
        // notification_type, topic_title, topic_id, post_number, excerpt, username, post_url
        final topicTitle = data['topic_title'] as String? ?? '';
        final topicId = data['topic_id'] as int?;
        final postNumber = data['post_number'] as int?;
        final excerpt = data['excerpt'] as String? ?? '';
        final username = data['username'] as String? ?? '';

        String title = topicTitle.isNotEmpty ? topicTitle : '新通知';
        String body = excerpt.isNotEmpty ? excerpt : username;

        debugPrint('[NotificationAlert] 发送系统通知: title=$title, body=$body, topicId=$topicId, postNumber=$postNumber');

        LocalNotificationService().show(
          title: title,
          body: body,
          id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
          topicId: topicId,
          postNumber: postNumber,
        );
      }
    }
    
    subscriptions[notificationAlertChannel] = (messageId: -1, callback: onNotificationAlert);
    _allCallbacks[notificationAlertChannel] = onNotificationAlert;
    
    // 3. 添加话题追踪频道
    for (final entry in meta.entries) {
      final channel = entry.key;
      final messageId = entry.value as int;
      
      void onTopicTracking(MessageBusMessage message) {
        debugPrint('[TopicTracking] 收到消息: ${message.channel} #${message.messageId}');
        // TODO: 根据频道类型更新对应的话题列表
      }
      
      subscriptions[channel] = (messageId: messageId, callback: onTopicTracking);
      _allCallbacks[channel] = onTopicTracking;
    }
    
    // 4. 批量订阅所有频道（只发起一次轮询）
    debugPrint('[MessageBusInit] 批量订阅 ${subscriptions.length} 个频道: ${subscriptions.keys}');
    messageBus.subscribeMultiple(subscriptions);
    
    ref.onDispose(() {
      debugPrint('[MessageBusInit] 取消所有订阅: ${_allCallbacks.keys}');
      for (final entry in _allCallbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _allCallbacks.clear();
    });
  }
}

final messageBusInitProvider = NotifierProvider<MessageBusInitNotifier, void>(
  MessageBusInitNotifier.new,
);

/// 话题追踪频道监听器
/// 订阅 /latest, /new, /unread 等频道，用于实时更新话题列表
class TopicTrackingChannelsNotifier extends Notifier<void> {
  final Map<String, MessageBusCallback> _subscriptions = {};
  
  @override
  void build() {
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;
    final metaAsync = ref.watch(topicTrackingStateMetaProvider);
    
    // 清理之前的订阅
    if (_subscriptions.isNotEmpty) {
      debugPrint('[TopicTracking] 清理旧订阅: ${_subscriptions.keys}');
      for (final entry in _subscriptions.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _subscriptions.clear();
    }
    
    if (currentUser == null) {
      debugPrint('[TopicTracking] 用户未登录，跳过订阅');
      return;
    }
    
    final meta = metaAsync.value;
    if (meta == null || meta.isEmpty) {
      debugPrint('[TopicTracking] topicTrackingStateMeta 未加载或为空');
      return;
    }
    
    debugPrint('[TopicTracking] 订阅频道: ${meta.keys}');
    
    for (final entry in meta.entries) {
      final channel = entry.key;
      final messageId = entry.value as int;
      
      void onMessage(MessageBusMessage message) {
        debugPrint('[TopicTracking] 收到消息: ${message.channel} #${message.messageId}');
      }
      
      _subscriptions[channel] = onMessage;
      messageBus.subscribeWithMessageId(channel, onMessage, messageId);
    }
    
    ref.onDispose(() {
      debugPrint('[TopicTracking] 取消所有订阅: ${_subscriptions.keys}');
      for (final entry in _subscriptions.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _subscriptions.clear();
    });
  }
}

final topicTrackingChannelsProvider = NotifierProvider<TopicTrackingChannelsNotifier, void>(
  TopicTrackingChannelsNotifier.new,
);

/// 话题列表新消息状态
class TopicListIncomingState {
  final Set<int> incomingTopicIds;
  
  const TopicListIncomingState({this.incomingTopicIds = const {}});
  
  bool get hasIncoming => incomingTopicIds.isNotEmpty;
  int get incomingCount => incomingTopicIds.length;
  
  TopicListIncomingState copyWith({Set<int>? incomingTopicIds}) {
    return TopicListIncomingState(
      incomingTopicIds: incomingTopicIds ?? this.incomingTopicIds,
    );
  }
}

/// 话题列表频道监听器
/// 只标记有新话题，不主动刷新（避免频繁 API 调用）
/// 根据当前筛选条件（分类、标签）过滤消息
/// 使用防抖机制批量更新，避免频繁触发 UI 刷新
class LatestChannelNotifier extends Notifier<TopicListIncomingState> {
  Timer? _debounceTimer;
  final Set<int> _pendingTopicIds = {};
  static const _debounceDuration = Duration(seconds: 3);

  @override
  TopicListIncomingState build() {
    final messageBus = ref.watch(messageBusServiceProvider);
    // 监听筛选条件变化，变化时自动 rebuild（重置 incoming 状态）
    ref.watch(topicFilterProvider);
    const channel = '/latest';

    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      final topicId = data['topic_id'] as int?;
      if (topicId == null) return;

      // 获取当前筛选条件
      final filter = ref.read(topicFilterProvider);

      // 检查分类筛选
      if (filter.categoryId != null) {
        final payload = data['payload'] as Map<String, dynamic>?;
        final topicCategoryId = payload?['category_id'] as int? ?? data['category_id'] as int?;
        if (topicCategoryId != filter.categoryId) {
          debugPrint('[LatestChannel] 分类不匹配，跳过: topic=$topicId, topicCategory=$topicCategoryId, filterCategory=${filter.categoryId}');
          return; // 分类不匹配，不添加
        }
      }

      // 检查标签筛选
      if (filter.tags.isNotEmpty) {
        final payload = data['payload'] as Map<String, dynamic>?;
        final topicTags = (payload?['tags'] ?? data['tags']) as List?;
        // 兼容新旧格式：如果是对象则取 name 字段，如果是字符串则直接用
        final topicTagStrings = topicTags?.map((t) {
          if (t is Map<String, dynamic>) {
            return t['name'] as String? ?? '';
          }
          return t.toString();
        }).toList() ?? [];

        // 检查话题标签是否包含筛选中的任意一个标签
        final hasMatchingTag = filter.tags.any((t) => topicTagStrings.contains(t));
        if (!hasMatchingTag) {
          debugPrint('[LatestChannel] 标签不匹配，跳过: topic=$topicId, topicTags=$topicTagStrings, filterTags=${filter.tags}');
          return; // 标签不匹配，不添加
        }
      }

      debugPrint('[LatestChannel] 收到新话题: $topicId，等待批量更新');

      // 添加到待处理集合
      _pendingTopicIds.add(topicId);

      // 取消之前的定时器并重新开始
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDuration, () {
        if (_pendingTopicIds.isNotEmpty) {
          debugPrint('[LatestChannel] 批量添加 ${_pendingTopicIds.length} 条新话题');
          state = state.copyWith(
            incomingTopicIds: {...state.incomingTopicIds, ..._pendingTopicIds},
          );
          _pendingTopicIds.clear();
        }
      });
    }

    messageBus.subscribe(channel, onMessage);

    ref.onDispose(() {
      _debounceTimer?.cancel();
      _pendingTopicIds.clear();
      messageBus.unsubscribe(channel, onMessage);
    });

    return const TopicListIncomingState();
  }

  /// 清除新话题标记
  void clearNewTopics() {
    _debounceTimer?.cancel();
    _pendingTopicIds.clear();
    state = const TopicListIncomingState();
  }
}

final latestChannelProvider = NotifierProvider<LatestChannelNotifier, TopicListIncomingState>(() {
  return LatestChannelNotifier();
});
