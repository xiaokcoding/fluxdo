import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../constants.dart';
import '../../models/topic.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/message_bus_providers.dart';
import '../../services/discourse_service.dart';
import '../../services/screen_track.dart';
import '../../widgets/content/lazy_load_scope.dart';
import '../../widgets/post/post_item_skeleton.dart';
import '../../widgets/post/reply_sheet.dart';
import '../../widgets/topic/topic_progress.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/content/discourse_html_content/chunked/chunked_html_content.dart';
import 'controllers/post_highlight_controller.dart';
import 'controllers/post_visibility_tracker.dart';
import 'controllers/topic_scroll_controller.dart';
import 'widgets/topic_detail_overlay.dart';
import 'widgets/topic_post_list.dart';

/// 话题详情页面
class TopicDetailPage extends ConsumerStatefulWidget {
  final int topicId;
  final String? initialTitle;
  final int? scrollToPostNumber; // 外部控制的跳转位置（如从通知跳转到指定楼层）

  const TopicDetailPage({
    super.key,
    required this.topicId,
    this.initialTitle,
    this.scrollToPostNumber,
  });

  @override
  ConsumerState<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends ConsumerState<TopicDetailPage> with WidgetsBindingObserver {
  /// 唯一实例 ID，确保每次打开页面都创建新的 provider 实例
  final String _instanceId = const Uuid().v4();

  // Controllers
  late final TopicScrollController _scrollController;
  late final PostHighlightController _highlightController;
  late final PostVisibilityTracker _visibilityTracker;
  late final ScreenTrack _screenTrack;

  // UI State
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _centerKey = GlobalKey();
  bool _showTitle = false;
  bool _hasFirstPost = false;
  bool _isCheckTitleVisibilityScheduled = false;
  bool _isRefreshing = false;

  Timer? _throttleTimer;
  Set<int> _lastReadPostNumbers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final trackEnabled = ref.read(currentUserProvider).value != null;

    _screenTrack = ScreenTrack(
      DiscourseService(),
      onTimingsSent: (topicId, postNumbers, highestSeen) {
        print('[TopicDetail] onTimingsSent callback triggered: topicId=$topicId, highestSeen=$highestSeen');
        ref.read(topicListProvider(TopicListFilter.latest).notifier).updateSeen(topicId, highestSeen);
        ref.read(topicListProvider(TopicListFilter.unread).notifier).updateSeen(topicId, highestSeen);
        // 更新会话已读状态，触发 PostItem 消除未读圆点
        ref.read(topicSessionProvider(topicId).notifier).markAsRead(postNumbers);
      },
    );

    if (trackEnabled) {
      _screenTrack.start(widget.topicId);
    }

    _scrollController = TopicScrollController(
      scrollController: AutoScrollController(),
      initialPostNumber: widget.scrollToPostNumber,
      onScrolled: () {
        if (_visibilityTracker.trackEnabled) {
          _screenTrack.scrolled();
        }
      },
    );

    _highlightController = PostHighlightController();

    _visibilityTracker = PostVisibilityTracker(
      screenTrack: _screenTrack,
      trackEnabled: trackEnabled,
      onStreamIndexChanged: _updateStreamIndexForPostNumber,
    );

    _scrollController.scrollController.addListener(_onScroll);
    _scrollController.addListener(_onScrollStateChanged);
    _highlightController.addListener(_onHighlightChanged);
    _visibilityTracker.addListener(_onVisibilityChanged);
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.scrollController.removeListener(_onScroll);
    _scrollController.removeListener(_onScrollStateChanged);
    _highlightController.removeListener(_onHighlightChanged);
    _visibilityTracker.removeListener(_onVisibilityChanged);
    _screenTrack.stop();
    _scrollController.dispose();
    _highlightController.dispose();
    _visibilityTracker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final hasFocus = state == AppLifecycleState.resumed;
    _screenTrack.setHasFocus(hasFocus);
  }

  void _onScrollStateChanged() {
    if (mounted) setState(() {});
  }

  void _onHighlightChanged() {
    if (mounted) setState(() {});
  }

  void _onVisibilityChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleCheckTitleVisibility() {
    if (_isCheckTitleVisibilityScheduled || !mounted) return;
    _isCheckTitleVisibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isCheckTitleVisibilityScheduled = false;
      if (mounted) {
        _checkTitleVisibility();
      }
    });
  }

  void _onScroll() {
    if (_isRefreshing) return;
    _scheduleCheckTitleVisibility();
    _scrollController.handleScroll();

    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detailAsync = ref.read(topicDetailProvider(params));

    if (detailAsync.isLoading) return;

    final notifier = ref.read(topicDetailProvider(params).notifier);

    if (_scrollController.shouldLoadPrevious(notifier.hasMoreBefore, notifier.isLoadingPrevious)) {
      notifier.loadPrevious();
    }

    if (_scrollController.shouldLoadMore(notifier.hasMoreAfter, notifier.isLoadingMore)) {
      notifier.loadMore();
    }
  }

  void _checkTitleVisibility() {
    final barHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    final ctx = _headerKey.currentContext;

    if (ctx == null) {
      if (_hasFirstPost && !_showTitle) {
        setState(() => _showTitle = true);
      }
    } else {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final position = box.localToGlobal(Offset.zero);
        final headerVisible = position.dy >= barHeight;

        if (headerVisible && _showTitle) {
          setState(() => _showTitle = false);
        } else if (!headerVisible && !_showTitle) {
          setState(() => _showTitle = true);
        }
      }
    }
  }

  void _updateStreamIndexForPostNumber(int postNumber) {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final stream = detail.postStream.stream;

    final post = posts.firstWhere(
      (p) => p.postNumber == postNumber,
      orElse: () => posts.first,
    );

    final streamIndex = stream.indexOf(post.id);
    if (streamIndex != -1) {
      final newIndex = streamIndex + 1;
      _visibilityTracker.updateStreamIndex(newIndex);
    }
  }

  void _handleVoteChanged() {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    ref.invalidate(topicDetailProvider(params));
  }

  void _updateReadPostNumbers(Set<int> readPostNumbers) {
    if (setEquals(_lastReadPostNumbers, readPostNumbers)) return;
    _lastReadPostNumbers = readPostNumbers;
    _visibilityTracker.setReadPostNumbers(readPostNumbers);
  }

  Future<void> _handleRefresh() async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detailAsync = ref.read(topicDetailProvider(params));
    if (detailAsync.isLoading) return;

    final detail = ref.read(topicDetailProvider(params)).value;
    final anchorPostNumber = _visibilityTracker.getRefreshAnchorPostNumber(
      detail?.postStream.posts.firstOrNull?.postNumber ?? _scrollController.currentPostNumber,
    );

    setState(() => _isRefreshing = true);
    await ref.read(topicDetailProvider(params).notifier).refreshWithPostNumber(anchorPostNumber);

    if (!mounted) return;
    setState(() => _isRefreshing = false);

    if (ref.read(topicDetailProvider(params)).value == null) return;

    _scrollController.prepareRefresh(anchorPostNumber, skipHighlight: true);
    _highlightController.skipNextJumpHighlight = true;
  }

  Future<void> _handleReply(Post? replyToPost) async {
    final success = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      replyToPost: replyToPost,
    );

    if (success && mounted) {
      final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
      ref.invalidate(topicDetailProvider(params));
    }
  }

  void _shareTopic() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final url = '${AppConstants.baseUrl}/t/topic/${widget.topicId}${username.isNotEmpty ? '?u=$username' : ''}';
    Share.share(url);
  }

  Future<void> _openInBrowser() async {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final url = '${AppConstants.baseUrl}/t/topic/${widget.topicId}${username.isNotEmpty ? '?u=$username' : ''}';
    final uri = Uri.parse(url);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开浏览器')),
        );
      }
    }
  }

  Future<void> _scrollToTop() async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;

    if (detail != null && detail.postStream.posts.isNotEmpty &&
        detail.postStream.posts.first.postNumber == 1) {
      _scrollController.scrollToTop();
      return;
    }

    print('[TopicDetail] First post not loaded, reloading from post 1');
    _scrollController.prepareJumpToPost(1);
    _highlightController.skipNextJumpHighlight = false;

    final notifier = ref.read(topicDetailProvider(params).notifier);
    await notifier.reloadWithPostNumber(1);
  }

  Future<void> _scrollToPost(int postNumber) async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.postNumber == postNumber);

    if (postIndex == -1) {
      print('[TopicDetail] Post $postNumber not in list, reloading with new postNumber');
      _scrollController.prepareJumpToPost(postNumber);
      _highlightController.skipNextJumpHighlight = false;

      final notifier = ref.read(topicDetailProvider(params).notifier);
      await notifier.reloadWithPostNumber(postNumber);
      return;
    }

    await _scrollController.scrollToPost(postNumber, posts);
    _highlightController.triggerHighlight(postNumber);
  }

  Future<void> _scrollToPostById(int postId) async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.id == postId);

    if (postIndex != -1) {
      final post = posts[postIndex];
      await _scrollController.scrollController.scrollToIndex(
        postIndex,
        preferPosition: AutoScrollPosition.begin,
        duration: const Duration(milliseconds: 200),
      );
      _highlightController.triggerHighlight(post.postNumber);
      return;
    }

    print('[TopicDetail] Post ID $postId not in loaded posts, fetching post info...');

    try {
      final service = DiscourseService();
      final postStream = await service.getPosts(widget.topicId, [postId]);

      if (postStream.posts.isEmpty) {
        print('[TopicDetail] Failed to fetch post $postId');
        return;
      }

      final targetPost = postStream.posts.first;
      final realPostNumber = targetPost.postNumber;
      print('[TopicDetail] Got real post_number: $realPostNumber for post ID $postId');

      _scrollController.prepareJumpToPost(realPostNumber);
      _highlightController.skipNextJumpHighlight = false;

      final notifier = ref.read(topicDetailProvider(params).notifier);
      await notifier.reloadWithPostNumber(realPostNumber);
    } catch (e) {
      print('[TopicDetail] Error fetching post $postId: $e');
    }
  }

  void _scrollToInitialPosition(List<Post> posts, int? dividerPostIndex) {
    _doInitialScroll(posts, dividerPostIndex, retryCount: 0);
  }

  void _doInitialScroll(List<Post> posts, int? dividerPostIndex, {required int retryCount}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      if (retryCount == 0) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      if (!mounted) return;

      if (!_scrollController.scrollController.hasClients) {
        if (retryCount < 5) {
          await Future.delayed(const Duration(milliseconds: 50));
          if (mounted) {
            _doInitialScroll(posts, dividerPostIndex, retryCount: retryCount + 1);
          }
          return;
        } else {
          if (mounted && !_scrollController.isPositioned) {
            _scrollController.markPositioned();
          }
          return;
        }
      }

      try {
        int? targetPostIndex;
        bool shouldHighlight = false;
        final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
        final jumpTarget = _scrollController.jumpTargetPostNumber;
        final currentPostNumber = _scrollController.currentPostNumber;

        if (jumpTarget != null) {
          for (int i = 0; i < posts.length; i++) {
            if (posts[i].postNumber >= jumpTarget) {
              targetPostIndex = i;
              shouldHighlight = !_highlightController.skipNextJumpHighlight;
              break;
            }
          }
        } else if (dividerPostIndex != null && dividerPostIndex < posts.length) {
          targetPostIndex = dividerPostIndex;
          shouldHighlight = true;
        } else if (currentPostNumber != null && currentPostNumber > 0) {
          for (int i = 0; i < posts.length; i++) {
            if (posts[i].postNumber >= currentPostNumber) {
              targetPostIndex = i;
              shouldHighlight = true;
              break;
            }
          }
        }

        if (targetPostIndex != null) {
          if (hasFirstPost && targetPostIndex == 0) {
            await _scrollController.scrollController.animateTo(
              _scrollController.scrollController.position.minScrollExtent,
              duration: const Duration(milliseconds: 1),
              curve: Curves.linear,
            );
          } else {
            await _scrollController.scrollController.scrollToIndex(
              targetPostIndex,
              preferPosition: AutoScrollPosition.begin,
              duration: const Duration(milliseconds: 1),
            );
          }

          _scrollController.clearJumpTarget();
          _highlightController.skipNextJumpHighlight = false;

          if (shouldHighlight) {
            _highlightController.pendingHighlightPostNumber = posts[targetPostIndex].postNumber;
          }
        }
      } catch (e, stack) {
        print('[TopicDetail] Scroll error: $e\n$stack');
      } finally {
        if (mounted && !_scrollController.isPositioned) {
          _scrollController.markPositioned();
          if (_highlightController.pendingHighlightPostNumber != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _highlightController.consumePendingHighlight();
              }
            });
          }
        }
      }
    });
  }

  void _showTimelineSheet(TopicDetail detail) {
    showTopicTimelineSheet(
      context: context,
      currentIndex: _visibilityTracker.currentVisibleStreamIndex,
      stream: detail.postStream.stream,
      onJumpToPostId: _scrollToPostById,
      title: detail.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = ref.watch(currentUserProvider).value != null;

    ref.listen<AsyncValue<void>>(authStateProvider, (_, __) {
      if (!mounted) return;
      final stillLoggedIn = ref.read(currentUserProvider).value != null;
      if (!stillLoggedIn && _visibilityTracker.trackEnabled) {
        _visibilityTracker.trackEnabled = false;
      }
    });

    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detailAsync = ref.watch(topicDetailProvider(params));
    final detail = detailAsync.value;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    // 监听 MessageBus 新回复通知
    ref.listen(topicChannelProvider(widget.topicId), (previous, next) {
      if (next.hasNewReplies && !(previous?.hasNewReplies ?? false)) {
        print('[TopicDetail] New replies detected via MessageBus, loading...');
        notifier.loadNewReplies();
      }

      if (next.typingUsers.isNotEmpty || next.hasNewReplies) {
        if (_throttleTimer?.isActive ?? false) return;
        _throttleTimer = Timer(const Duration(milliseconds: 200), () {
          if (mounted) {
            _scrollController.scrollToBottomIfNeeded();
          }
        });
      }
    });

    // 预解析帖子 HTML
    ref.listen(topicDetailProvider(params), (previous, next) {
      final posts = next.value?.postStream.posts;
      if (posts != null && posts.isNotEmpty) {
        final htmlList = posts.map((p) => p.cooked).toList();
        ChunkedHtmlContent.preloadAll(htmlList);

        final hasFirstPost = posts.first.postNumber == 1;
        if (_hasFirstPost != hasFirstPost) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _hasFirstPost = hasFirstPost);
              _scheduleCheckTitleVisibility();
            }
          });
        }
      }
    });

    final channelState = ref.watch(topicChannelProvider(widget.topicId));
    final typingUsers = channelState.typingUsers;

    return LazyLoadScope(
      child: Scaffold(
        appBar: AppBar(
          title: AnimatedOpacity(
            opacity: _showTitle || !_hasFirstPost ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.titleMedium,
                children: [
                  if (detail?.closed ?? false)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.lock_outline,
                          size: 18,
                          color: theme.textTheme.titleMedium?.color ?? theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ...EmojiText.buildEmojiSpans(context, detail?.title ?? widget.initialTitle ?? '', theme.textTheme.titleMedium),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          centerTitle: false,
        ),
        body: _buildBody(context, detailAsync, detail, notifier, isLoggedIn, typingUsers),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AsyncValue<TopicDetail> detailAsync,
    TopicDetail? detail,
    dynamic notifier,
    bool isLoggedIn,
    List<TypingUser> typingUsers,
  ) {
    final theme = Theme.of(context);
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);

    // 初始加载 loading
    if (detailAsync.isLoading && detail == null) {
      final showHeaderSkeleton = widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return PostListSkeleton(withHeader: showHeaderSkeleton);
    }

    // 跳转中：等待包含目标帖子的新数据
    if (_scrollController.jumpTargetPostNumber != null && detail != null) {
      final posts = detail.postStream.posts;
      final hasTarget = posts.isNotEmpty &&
          posts.first.postNumber <= _scrollController.jumpTargetPostNumber! &&
          posts.last.postNumber >= _scrollController.jumpTargetPostNumber!;
      if (!hasTarget) {
        return const PostListSkeleton();
      }
    }

    // 错误
    if (detailAsync.hasError && detail == null) {
      return CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('加载失败\n${detailAsync.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => ref.refresh(topicDetailProvider(params)),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (detail == null) return const SizedBox();

    final posts = detail.postStream.posts;
    final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
    final sessionState = ref.watch(topicSessionProvider(widget.topicId));

    if (posts.isNotEmpty) {
      final readPostNumbers = <int>{};
      for (final post in posts) {
        if (post.read) {
          readPostNumbers.add(post.postNumber);
        }
      }
      readPostNumbers.addAll(sessionState.readPostNumbers);
      _updateReadPostNumbers(readPostNumbers);
    }

    // 计算分割线位置
    int? dividerPostIndex;
    final lastRead = detail.lastReadPostNumber;
    final totalPosts = detail.postsCount;
    if (lastRead != null && lastRead > 3 && (totalPosts - lastRead) > 1) {
      for (int i = 0; i < posts.length; i++) {
        if (posts[i].postNumber > lastRead) {
          dividerPostIndex = i;
          break;
        }
      }
    }

    // 初始定位
    if (!_scrollController.hasInitialScrolled && posts.isNotEmpty) {
      _scrollController.markInitialScrolled(posts.first.postNumber);
      if (_scrollController.currentPostNumber == null || _scrollController.currentPostNumber == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_scrollController.isPositioned) {
            _scrollController.markPositioned();
          }
        });
      } else {
        _scrollToInitialPosition(posts, dividerPostIndex);
      }
    }

    final centerPostIndex = _scrollController.findCenterPostIndex(posts);

    Widget scrollView = TopicPostList(
      detail: detail,
      scrollController: _scrollController.scrollController,
      centerKey: _centerKey,
      headerKey: _headerKey,
      highlightPostNumber: _highlightController.highlightPostNumber,
      typingUsers: typingUsers,
      isLoggedIn: isLoggedIn,
      hasMoreBefore: notifier.hasMoreBefore,
      hasMoreAfter: notifier.hasMoreAfter,
      isLoadingPrevious: notifier.isLoadingPrevious,
      isLoadingMore: notifier.isLoadingMore,
      centerPostIndex: centerPostIndex,
      dividerPostIndex: dividerPostIndex,
      onPostVisibilityChanged: _visibilityTracker.onPostVisibilityChanged,
      onJumpToPost: _scrollToPost,
      onReply: _handleReply,
      onVoteChanged: _handleVoteChanged,
      onScrollNotification: _scrollController.handleScrollNotification,
    );

    scrollView = RefreshIndicator(
      onRefresh: _handleRefresh,
      notificationPredicate: (notification) {
        if (!hasFirstPost) return false;
        return notification.metrics.pixels <= notification.metrics.minScrollExtent;
      },
      child: scrollView,
    );

    final content = Opacity(
      opacity: _scrollController.isPositioned ? 1.0 : 0.0,
      child: scrollView,
    );

    return Stack(
      children: [
        content,
        TopicDetailOverlay(
          showBottomBar: _scrollController.showBottomBar,
          isLoggedIn: isLoggedIn,
          currentStreamIndex: _visibilityTracker.currentVisibleStreamIndex,
          totalCount: detail.postStream.stream.length,
          detail: detail,
          onScrollToTop: _scrollToTop,
          onShare: _shareTopic,
          onOpenInBrowser: _openInBrowser,
          onReply: () => _handleReply(null),
          onProgressTap: () => _showTimelineSheet(detail),
        ),
      ],
    );
  }
}
