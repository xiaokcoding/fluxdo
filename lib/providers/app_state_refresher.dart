import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';
import 'notification_list_provider.dart';
import 'topic_list_provider.dart';
import 'topic_sort_provider.dart';
import 'user_content_providers.dart';
import 'category_provider.dart';
import 'message_bus/notification_providers.dart';
import 'message_bus/topic_tracking_providers.dart';
import 'ldc_providers.dart';
import '../widgets/topic/topic_filter_sheet.dart';

class AppStateRefresher {
  AppStateRefresher._();

  static void refreshAll(WidgetRef ref) {
    for (final refresh in _refreshers) {
      refresh(ref);
    }
  }

  static Future<void> resetForLogout(WidgetRef ref) async {
    refreshAll(ref);
    ref.read(topicFilterProvider.notifier).clearAll();
    ref.read(topicSortProvider.notifier).state = TopicListFilter.latest;
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
      for (final filter in TopicListFilter.values) {
        ref.invalidate(topicListProvider(filter));
      }
    },
  ];
}
