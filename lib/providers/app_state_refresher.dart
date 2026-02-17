import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';
import 'notification_list_provider.dart';
import 'topic_list_provider.dart';
import 'topic_sort_provider.dart';
import 'pinned_categories_provider.dart';
import 'user_content_providers.dart';
import 'category_provider.dart';
import 'message_bus/notification_providers.dart';
import 'message_bus/topic_tracking_providers.dart';
import 'ldc_providers.dart';

class AppStateRefresher {
  AppStateRefresher._();

  static void refreshAll(WidgetRef ref) {
    for (final refresh in _refreshers) {
      refresh(ref);
    }
  }

  static Future<void> resetForLogout(WidgetRef ref) async {
    refreshAll(ref);
    ref.read(topicSortProvider.notifier).setSort(TopicListFilter.latest);
    // 清理各 tab 的标签筛选
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    ref.read(tabTagsProvider(null).notifier).state = [];
    for (final id in pinnedIds) {
      ref.read(tabTagsProvider(id).notifier).state = [];
    }
    ref.read(activeCategorySlugsProvider.notifier).reset();
    await ref.read(ldcUserInfoProvider.notifier).disable();
  }

  static final List<void Function(WidgetRef ref)> _refreshers = [
    (ref) => ref.invalidate(currentUserProvider),
    (ref) => ref.invalidate(userSummaryProvider),
    (ref) => ref.invalidate(notificationListProvider),
    (ref) => ref.invalidate(categoriesProvider),
    (ref) => ref.invalidate(tagsProvider),
    (ref) => ref.invalidate(canTagTopicsProvider),
    (ref) {
      final activeSlugs = ref.read(activeCategorySlugsProvider);
      for (final slug in activeSlugs) {
        ref.invalidate(categoryTopicsProvider(slug));
      }
    },
    (ref) => ref.invalidate(browsingHistoryProvider),
    (ref) => ref.invalidate(bookmarksProvider),
    (ref) => ref.invalidate(myTopicsProvider),
    (ref) => ref.invalidate(topicTrackingStateMetaProvider),
    (ref) => ref.invalidate(notificationCountStateProvider),
    (ref) => ref.invalidate(notificationChannelProvider),
    (ref) => ref.invalidate(notificationAlertChannelProvider),
    (ref) => ref.invalidate(topicTrackingChannelsProvider),
    (ref) => ref.invalidate(latestChannelProvider),
    (ref) => ref.invalidate(messageBusInitProvider),
    (ref) => ref.invalidate(ldcUserInfoProvider),
    (ref) {
      final pinnedIds = ref.read(pinnedCategoriesProvider);
      for (final sort in TopicListFilter.values) {
        // 全部 tab
        ref.invalidate(topicListProvider((sort, null)));
        // 各分类 tab
        for (final id in pinnedIds) {
          ref.invalidate(topicListProvider((sort, id)));
        }
      }
    },
  ];
}
