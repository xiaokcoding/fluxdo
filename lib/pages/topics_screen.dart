import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/discourse_providers.dart';
import '../providers/topic_sort_provider.dart';
import '../widgets/layout/master_detail_layout.dart';
import 'topics_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'create_topic_page.dart';

/// 话题屏幕
/// 在手机上显示单栏列表，平板上显示 Master-Detail 双栏
class TopicsScreen extends ConsumerStatefulWidget {
  const TopicsScreen({super.key});

  @override
  ConsumerState<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends ConsumerState<TopicsScreen> {
  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;

  void _maybePushDetail(SelectedTopicState selectedTopic, bool canShowDetailPane) {
    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    if (_isAutoSwitching) return;

    // 从双栏切到单栏时自动 push；如果 previous 为空但当前为单栏且有选中，
    // 也执行 push，避免因状态丢失导致无法自动进入详情。
    if (!canShowDetailPane && selectedTopic.hasSelection && (previous == null || previous == true)) {
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        return;
      }

      final topicId = selectedTopic.topicId;
      if (topicId == null) return;

      _isAutoSwitching = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final navigator = Navigator.of(context);
        ref.read(selectedTopicProvider.notifier).clear();
        navigator
            .push(
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topicId,
              initialTitle: selectedTopic.initialTitle,
              scrollToPostNumber: selectedTopic.scrollToPostNumber,
              autoSwitchToMasterDetail: true,
            ),
          ),
        )
            .whenComplete(() {
          if (mounted) {
            setState(() => _isAutoSwitching = false);
          }
        });
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedTopic = ref.watch(selectedTopicProvider);
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);
    final user = ref.watch(currentUserProvider).value;

    _maybePushDetail(selectedTopic, canShowDetailPane);

    // 统一使用 MasterDetailLayout 处理所有情况
    // 手机/平板单栏：只显示 master
    // 平板双栏：显示 master + detail
    return MasterDetailLayout(
      master: const TopicsPage(),
      detail: selectedTopic.hasSelection && canShowDetailPane
          ? TopicDetailPane(
              key: ValueKey(selectedTopic.topicId),
              topicId: selectedTopic.topicId!,
              initialTitle: selectedTopic.initialTitle,
              scrollToPostNumber: selectedTopic.scrollToPostNumber,
            )
          : null,
      masterFloatingActionButton: user != null
          ? FloatingActionButton(
              onPressed: () => _createTopic(context, ref),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Future<void> _createTopic(BuildContext context, WidgetRef ref) async {
    final topicId = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => const CreateTopicPage()),
    );
    if (topicId != null && context.mounted) {
      // 刷新当前排序模式的列表
      final currentSort = ref.read(topicSortProvider);
      ref.invalidate(topicListProvider(currentSort));
      // 在 Master-Detail 模式下，选中新话题
      ref.read(selectedTopicProvider.notifier).select(topicId: topicId);
    }
  }
}

/// 话题详情面板（用于双栏模式，不包含返回按钮）
class TopicDetailPane extends ConsumerWidget {
  const TopicDetailPane({
    super.key,
    required this.topicId,
    this.initialTitle,
    this.scrollToPostNumber,
  });

  final int topicId;
  final String? initialTitle;
  final int? scrollToPostNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TopicDetailPage(
      topicId: topicId,
      initialTitle: initialTitle,
      scrollToPostNumber: scrollToPostNumber,
      embeddedMode: true, // 嵌入模式，不显示返回按钮
    );
  }
}
