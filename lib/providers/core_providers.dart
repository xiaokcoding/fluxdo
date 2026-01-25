import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user.dart';
import '../services/discourse_service.dart';
import '../services/preloaded_data_service.dart';

/// Discourse 服务 Provider
final discourseServiceProvider = Provider((ref) => DiscourseService());

/// 认证错误 Provider（监听登录失效事件）
final authErrorProvider = StreamProvider<String>((ref) {
  final service = ref.watch(discourseServiceProvider);
  return service.authErrorStream;
});

/// 认证状态变化 Provider（登录/退出）
final authStateProvider = StreamProvider<void>((ref) {
  final service = ref.watch(discourseServiceProvider);
  return service.authStateStream;
});

/// 当前用户 Provider
/// 优先使用预加载数据同步返回，避免启动时短暂显示未登录状态
class CurrentUserNotifier extends AsyncNotifier<User?> {
  @override
  FutureOr<User?> build() {
    final service = ref.read(discourseServiceProvider);
    final preloaded = PreloadedDataService().currentUserSync;
    if (preloaded != null) {
      final preloadedUser = User.fromJson(preloaded);
      service.currentUserNotifier.value = preloadedUser;
      _refreshUser(service, preloadedUser);
      return preloadedUser;
    }
    return _loadUser(service);
  }

  Future<User?> _loadUser(DiscourseService service) async {
    final preloadedUser = await service.getPreloadedCurrentUser();
    final user = await service.getCurrentUser();
    if (user == null) return preloadedUser;
    if (preloadedUser == null) return user;
    return _mergeUser(user, preloadedUser);
  }

  void _refreshUser(DiscourseService service, User preloadedUser) {
    Future(() async {
      final user = await service.getCurrentUser();
      if (user == null) return;
      state = AsyncValue.data(_mergeUser(user, preloadedUser));
    });
  }

  User _mergeUser(User user, User preloadedUser) {
    return user.copyWith(
      unreadNotifications: preloadedUser.unreadNotifications,
      unreadHighPriorityNotifications: preloadedUser.unreadHighPriorityNotifications,
      allUnreadNotificationsCount: preloadedUser.allUnreadNotificationsCount,
      seenNotificationId: preloadedUser.seenNotificationId,
      notificationChannelPosition: preloadedUser.notificationChannelPosition,
    );
  }
}

final currentUserProvider =
    AsyncNotifierProvider<CurrentUserNotifier, User?>(CurrentUserNotifier.new);

/// 用户统计数据 Provider
final userSummaryProvider = FutureProvider<UserSummary?>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  final user = await ref.watch(currentUserProvider.future);
  if (user == null) return null;
  return service.getUserSummary(user.username);
});
