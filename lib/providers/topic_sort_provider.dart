// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'topic_list_provider.dart';

/// 当前排序模式（不持久化，每次启动默认 latest）
final topicSortProvider = StateProvider<TopicListFilter>((ref) => TopicListFilter.latest);
