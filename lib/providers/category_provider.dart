import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/category.dart';
import '../models/topic.dart';
import 'core_providers.dart';

class ActiveCategorySlugsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void add(String slug) {
    if (slug.isEmpty) return;
    if (state.contains(slug)) return;
    state = {...state, slug};
  }

  void reset() {
    state = <String>{};
  }
}

final activeCategorySlugsProvider =
    NotifierProvider<ActiveCategorySlugsNotifier, Set<String>>(
        () => ActiveCategorySlugsNotifier());

/// 分类列表 Provider（已过滤系统默认的"未分类"）
final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  final categories = await service.getCategories();
  return categories.where((c) => c.id != 1).toList();
});

/// 分类 Map Provider (ID -> Category)
/// 用于快速查找
final categoryMapProvider = Provider<AsyncValue<Map<int, Category>>>((ref) {
  final categoriesAsync = ref.watch(categoriesProvider);
  return categoriesAsync.whenData((categories) {
    return {for (var c in categories) c.id: c};
  });
});

/// 热门标签列表 Provider
final tagsProvider = FutureProvider<List<String>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getTags();
});

/// 站点是否支持标签功能
final canTagTopicsProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.canTagTopics();
});

/// 话题标题最小长度
final minTopicTitleLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinTopicTitleLength();
});

/// 私信标题最小长度
final minPmTitleLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinPmTitleLength();
});

/// 首贴内容最小长度
final minFirstPostLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinFirstPostLength();
});

/// 私信内容最小长度
final minPmPostLengthProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getMinPmPostLength();
});

/// 分类下的话题列表 Provider
final categoryTopicsProvider = FutureProvider.family<TopicListResponse, String>((ref, slug) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getCategoryTopics(slug);
});
