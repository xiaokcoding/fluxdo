import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../widgets/topic/topic_card.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/common/error_view.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 浏览历史页面
class BrowsingHistoryPage extends ConsumerStatefulWidget {
  const BrowsingHistoryPage({super.key});

  @override
  ConsumerState<BrowsingHistoryPage> createState() => _BrowsingHistoryPageState();
}

class _BrowsingHistoryPageState extends ConsumerState<BrowsingHistoryPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(browsingHistoryProvider.notifier).loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await ref.read(browsingHistoryProvider.notifier).refresh();
  }

  void _onItemTap(Topic topic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(browsingHistoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('浏览历史')),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: historyAsync.when(
          data: (topics) {
            if (topics.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.history, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无浏览历史', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              );
            }

            return ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: topics.length + 1,
              itemBuilder: (context, index) {
                if (index == topics.length) {
                  final hasMore = ref.read(browsingHistoryProvider.notifier).hasMore;
                  if (!hasMore) {
                    return const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Center(
                        child: Text(
                          '没有更多了',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    );
                  }
                  if (historyAsync.isLoading) {
                    return const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return const SizedBox();
                }

                final topic = topics[index];
                return TopicCard(
                  topic: topic,
                  onTap: () => _onItemTap(topic),
                );
              },
            );
          },
          loading: () => const TopicListSkeleton(),
          error: (error, stack) => ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: _onRefresh,
          ),
        ),
      ),
    );
  }
}
