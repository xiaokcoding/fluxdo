import 'package:flutter/material.dart';
import '../common/skeleton.dart';

/// 话题列表骨架屏
class TopicListSkeleton extends StatelessWidget {
  const TopicListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: 8,
        itemBuilder: (context, index) => const _TopicCardSkeleton(),
      ),
    );
  }
}

/// 单个话题卡片的骨架屏
class _TopicCardSkeleton extends StatelessWidget {
  const _TopicCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(width: double.infinity, height: 20),
                      const SizedBox(height: 6),
                      SkeletonBox(width: 200, height: 20),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 分类和标签行
            Row(
              children: [
                SkeletonBox(width: 24, height: 24, borderRadius: 6),
                const SizedBox(width: 8),
                SkeletonBox(width: 80, height: 16),
                const SizedBox(width: 12),
                SkeletonBox(width: 60, height: 16),
              ],
            ),
            const SizedBox(height: 12),
            // 底部信息行
            Row(
              children: [
                SkeletonCircle(size: 24),
                const SizedBox(width: 8),
                SkeletonBox(width: 60, height: 14),
                const Spacer(),
                SkeletonBox(width: 40, height: 14),
                const SizedBox(width: 12),
                SkeletonBox(width: 40, height: 14),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
