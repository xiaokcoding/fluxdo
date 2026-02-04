import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../models/topic.dart';
import '../../utils/responsive.dart';
import '../../utils/share_utils.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/selected_topic_provider.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/message_bus_providers.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/screen_track.dart';
import '../../widgets/content/lazy_load_scope.dart';
import '../../widgets/post/post_item_skeleton.dart';
import '../../widgets/post/reply_sheet.dart';
import '../../widgets/topic/topic_progress.dart';
import '../../widgets/topic/topic_notification_button.dart';
import '../../widgets/common/emoji_text.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/content/discourse_html_content/chunked/chunked_html_content.dart';
import 'controllers/post_highlight_controller.dart';
import 'controllers/post_visibility_tracker.dart';
import 'controllers/topic_scroll_controller.dart';
import 'widgets/topic_detail_overlay.dart';
import 'widgets/topic_post_list.dart';
import 'widgets/topic_detail_header.dart';
import '../../widgets/layout/master_detail_layout.dart';
import '../edit_topic_page.dart';

/// 话题详情页面
class TopicDetailPage extends ConsumerStatefulWidget {
  final int topicId;
  final String? initialTitle;
  final int? scrollToPostNumber; // 外部控制的跳转位置（如从通知跳转到指定楼层）
  final bool embeddedMode; // 嵌入模式（双栏布局中使用，不显示返回按钮）

  const TopicDetailPage({
    super.key,
    required this.topicId,
    this.initialTitle,
    this.scrollToPostNumber,
    this.embeddedMode = false,
  });

  @override
  ConsumerState<TopicDetailPage> createState() => _TopicDetailPageState();
}

class _TopicDetailPageState extends ConsumerState<TopicDetailPage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
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

  /// 展开头部是否可见（用 ValueNotifier 隔离 UI 更新）
  final ValueNotifier<bool> _isOverlayVisibleNotifier = ValueNotifier<bool>(false);
  bool _isScrolledUnder = false;
  bool _isSwitchingMode = false;  // 切换热门回复模式
  late final AnimationController _expandController;
  late final Animation<Offset> _animation;
  Timer? _throttleTimer;
  bool _isScrollToBottomScheduled = false;
  Set<int> _lastReadPostNumbers = {};
  bool? _lastCanShowDetailPane;
  bool _isAutoSwitching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    
    _animation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
    ))..addStatusListener((status) {
      if (status == AnimationStatus.forward) {
        _isOverlayVisibleNotifier.value = true;
      } else if (status == AnimationStatus.dismissed) {
        _isOverlayVisibleNotifier.value = false;
      }
    });

    final trackEnabled = ref.read(currentUserProvider).value != null;

    _screenTrack = ScreenTrack(
      DiscourseService(),
      onTimingsSent: (topicId, postNumbers, highestSeen) {
        debugPrint('[TopicDetail] onTimingsSent callback triggered: topicId=$topicId, highestSeen=$highestSeen');
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
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _expandController.dispose();
    _isOverlayVisibleNotifier.dispose();
    _scrollController.scrollController.removeListener(_onScroll);
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
      final shouldScrolledUnder = !_hasFirstPost || true;
      if (_isScrolledUnder != shouldScrolledUnder) {
        setState(() => _isScrolledUnder = shouldScrolledUnder);
      }
    } else {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final position = box.localToGlobal(Offset.zero);
        final headerVisible = position.dy >= barHeight;
        final shouldShowTitle = !headerVisible;
        final shouldScrolledUnder = !_hasFirstPost || !headerVisible;
        if (shouldShowTitle != _showTitle || shouldScrolledUnder != _isScrolledUnder) {
          setState(() {
            _showTitle = shouldShowTitle;
            _isScrolledUnder = shouldScrolledUnder;
          });
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

  void _handleVoteChanged(int newVoteCount, bool userVoted) {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    ref.read(topicDetailProvider(params).notifier).updateTopicVote(newVoteCount, userVoted);
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
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final anchorPostNumber = _visibilityTracker.getRefreshAnchorPostNumber(
      detail?.postStream.posts.firstOrNull?.postNumber ?? _scrollController.currentPostNumber,
    );

    setState(() => _isRefreshing = true);
    await notifier.refreshWithPostNumber(anchorPostNumber);

    if (!mounted) return;
    setState(() => _isRefreshing = false);

    final updatedDetail = ref.read(topicDetailProvider(params)).value;
    if (updatedDetail == null) return;

    final isFiltered = notifier.isSummaryMode || notifier.isAuthorOnlyMode;
    final hasAnchor = updatedDetail.postStream.posts.any((p) => p.postNumber == anchorPostNumber);
    if (!isFiltered || hasAnchor) {
      _scrollController.prepareRefresh(anchorPostNumber, skipHighlight: true);
    } else {
      _scrollController.clearJumpTarget();
    }
    _highlightController.skipNextJumpHighlight = true;
  }

  Future<void> _handleReply(Post? replyToPost) async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;

    final newPost = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      categoryId: detail?.categoryId,
      replyToPost: replyToPost,
    );

    if (newPost != null && mounted) {
      // 添加新帖子，返回是否添加到视图
      final addedToView = ref.read(topicDetailProvider(params).notifier).addPost(newPost);

      if (addedToView) {
        // 用户在底部：滚动到新帖子位置并高亮
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToPost(newPost.postNumber);
          }
        });
      } else {
        // 用户不在底部：显示 SnackBar 提示，点击可跳转
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('回复已发送'),
              action: SnackBarAction(
                label: '查看',
                onPressed: () => _scrollToPost(newPost.postNumber),
              ),
              behavior: SnackBarBehavior.floating,
              persist: false,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    }
  }

  Future<void> _handleEdit(Post post) async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;

    final updatedPost = await showEditSheet(
      context: context,
      topicId: widget.topicId,
      post: post,
      categoryId: detail?.categoryId,
    );

    if (updatedPost != null && mounted) {
      // 直接更新帖子，不重新请求
      ref.read(topicDetailProvider(params).notifier).updatePost(updatedPost);
    }
  }

  Future<void> _handleEditTopic() async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    // 获取首贴：优先从已加载的帖子中查找
    final firstPost = detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull;
    // 首贴 id（用于在编辑页面内加载）
    final firstPostId = detail.postStream.stream.isNotEmpty ? detail.postStream.stream.first : null;

    final result = await Navigator.of(context).push<EditTopicResult>(
      MaterialPageRoute(
        builder: (context) => EditTopicPage(
          topicDetail: detail,
          firstPost: firstPost,
          firstPostId: firstPostId,
        ),
      ),
    );

    if (result != null && mounted) {
      ref.read(topicDetailProvider(params).notifier).updateTopicInfo(
        title: result.title,
        categoryId: result.categoryId,
        tags: result.tags,
        firstPost: result.updatedFirstPost,
      );
    }
  }

  void _handleSolutionChanged(int postId, bool accepted) {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    ref.read(topicDetailProvider(params).notifier).updatePostSolution(postId, accepted);
  }

  void _handleRefreshPost(int postId) {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    ref.read(topicDetailProvider(params).notifier).refreshPost(postId);
  }

  void _shareTopic() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
    SharePlus.instance.share(ShareParams(text: url));
  }

  Future<void> _openInBrowser() async {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
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

    debugPrint('[TopicDetail] First post not loaded, reloading from post 1');
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
    final notifier = ref.read(topicDetailProvider(params).notifier);

    if (postIndex == -1) {
      debugPrint('[TopicDetail] Post $postNumber not in list, reloading with new postNumber');
      _scrollController.prepareJumpToPost(postNumber);
      _highlightController.skipNextJumpHighlight = false;

      // 如果处于过滤模式，先尝试保持过滤跳转，失败则回退取消过滤
      if (notifier.isSummaryMode || notifier.isAuthorOnlyMode) {
        await _reloadWithFilterFallback(postNumber: postNumber);
      } else {
        await notifier.reloadWithPostNumber(postNumber);
      }
      return;
    }

    // 计算距离，如果距离过大直接使用本地跳转（即使已渲染）
    bool forceLocalJump = false;
    final stream = detail.postStream.stream;
    final currentVisibleIndex = _visibilityTracker.currentVisibleStreamIndex;
    
    // 找到目标帖子的流索引
    final targetPost = posts.firstWhere((p) => p.postNumber == postNumber, orElse: () => posts.first);
    final targetStreamIndex = stream.indexOf(targetPost.id);

    if (currentVisibleIndex != -1 && targetStreamIndex != -1) {
      if ((targetStreamIndex - currentVisibleIndex).abs() > 15) {
        forceLocalJump = true;
      }
    }

    if (!forceLocalJump && _scrollController.isPostRendered(postIndex)) {
      await _scrollController.scrollToPost(postNumber, posts);
    } else {
      // 如果目标帖子接近列表末尾（例如最后 20 个），
      // 则将锚点设置在更前面的位置，以防止 centerKey 导致底部留白
      int? anchorPostNumber;
      if (posts.length - 1 - postIndex < 20) {
        final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
        anchorPostNumber = posts[safeIndex].postNumber;
      }
      _visibilityTracker.reset(); // 清除旧的可见性数据，防止"占位"导致进度条回跳
      _scrollController.jumpToPostLocally(postNumber, anchorPostNumber: anchorPostNumber);
      // 触发重建，让 _buildPostListContent 重新进入初始定位逻辑
      if (mounted) setState(() {});
    }
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
      
      // 同样应用距离检查
      bool forceLocalJump = false;
      final currentVisibleIndex = _visibilityTracker.currentVisibleStreamIndex;
      final targetStreamIndex = detail.postStream.stream.indexOf(postId);
      
      if (currentVisibleIndex != -1 && targetStreamIndex != -1) {
        if ((targetStreamIndex - currentVisibleIndex).abs() > 15) {
          forceLocalJump = true;
        }
      }

      if (!forceLocalJump && _scrollController.isPostRendered(postIndex)) {
        await _scrollController.scrollController.scrollToIndex(
          postIndex,
          preferPosition: AutoScrollPosition.begin,
          duration: const Duration(milliseconds: 1), // 瞬时跳转
        );
      } else {
         // 锚点优化防止底部留白
        int? anchorPostNumber;
        if (posts.length - 1 - postIndex < 20) {
          final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
          anchorPostNumber = posts[safeIndex].postNumber;
        }

        _visibilityTracker.reset(); // 清除旧的可见性数据
        _scrollController.jumpToPostLocally(post.postNumber, anchorPostNumber: anchorPostNumber);
        // 触发重建，让 _buildPostListContent 重新进入初始定位逻辑
        if (mounted) setState(() {});
      }
      _highlightController.triggerHighlight(post.postNumber);
      return;
    }

    debugPrint('[TopicDetail] Post ID $postId not in loaded posts, fetching post info...');

    try {
      final service = DiscourseService();
      final postStream = await service.getPosts(widget.topicId, [postId]);

      if (postStream.posts.isEmpty) {
        debugPrint('[TopicDetail] Failed to fetch post $postId');
        return;
      }

      final targetPost = postStream.posts.first;
      final realPostNumber = targetPost.postNumber;
      debugPrint('[TopicDetail] Got real post_number: $realPostNumber for post ID $postId');

      _scrollController.prepareJumpToPost(realPostNumber);
      _highlightController.skipNextJumpHighlight = false;

      final notifier = ref.read(topicDetailProvider(params).notifier);

      // 如果处于过滤模式，先尝试保持过滤跳转，失败则回退取消过滤
      if (notifier.isSummaryMode || notifier.isAuthorOnlyMode) {
        await _reloadWithFilterFallback(postNumber: realPostNumber, postId: postId);
      } else {
        await notifier.reloadWithPostNumber(realPostNumber);
      }
    } catch (e) {
      debugPrint('[TopicDetail] Error fetching post $postId: $e');
    }
  }

  bool _detailHasTargetPost(TopicDetail detail, {int? postNumber, int? postId}) {
    if (postId != null) {
      if (detail.postStream.stream.contains(postId)) return true;
      if (detail.postStream.posts.any((p) => p.id == postId)) return true;
    }
    if (postNumber != null) {
      if (detail.postStream.posts.any((p) => p.postNumber == postNumber)) return true;
    }
    return false;
  }

  Future<void> _reloadWithFilterFallback({required int postNumber, int? postId}) async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final wasSummaryMode = notifier.isSummaryMode;
    final wasAuthorOnlyMode = notifier.isAuthorOnlyMode;

    setState(() => _isSwitchingMode = true);
    _visibilityTracker.reset();

    try {
      await notifier.reloadWithPostNumber(postNumber);
      if (!mounted) return;

      final detail = ref.read(topicDetailProvider(params)).value;
      final hasTarget = detail != null && _detailHasTargetPost(detail, postNumber: postNumber, postId: postId);
      final shouldFallback = detail != null && _shouldFallbackFilter(detail, wasSummaryMode, wasAuthorOnlyMode);
      if (!hasTarget || shouldFallback) {
        _visibilityTracker.reset();
        await notifier.cancelFilterAndReloadWithPostNumber(postNumber);
      }
    } finally {
      if (mounted) setState(() => _isSwitchingMode = false);
    }
  }

  bool _shouldFallbackFilter(TopicDetail detail, bool wasSummaryMode, bool wasAuthorOnlyMode) {
    if (wasSummaryMode) {
      if (!detail.hasSummary) return true;
      if (detail.postsCount > 0 && detail.postStream.stream.length >= detail.postsCount) {
        return true;
      }
    }

    if (wasAuthorOnlyMode) {
      final author = detail.createdBy?.username;
      if (author == null || author.isEmpty) return true;
      final hasOtherUsers = detail.postStream.posts.any((p) => p.username != author);
      if (hasOtherUsers) return true;
    }

    return false;
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
        debugPrint('[TopicDetail] Scroll error: $e\n$stack');
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

  void _handleNotificationLevelChanged(dynamic notifier, TopicNotificationLevel level) async {
    try {
      await notifier.updateNotificationLevel(level);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已设置为${level.label}')),
        );
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    }
  }


  Future<void> _handleShowTopReplies() async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final notifier = ref.read(topicDetailProvider(params).notifier);

    // 显示骨架屏
    setState(() => _isSwitchingMode = true);

    // 重置状态，和跳转到未加载数据时一样
    _scrollController.prepareJumpToPost(1);
    _highlightController.skipNextJumpHighlight = true;
    _visibilityTracker.reset();

    await notifier.showTopReplies();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
    }
  }

  Future<void> _handleCancelFilter() async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final notifier = ref.read(topicDetailProvider(params).notifier);

    // 显示骨架屏
    setState(() => _isSwitchingMode = true);

    // 重置状态，和跳转到未加载数据时一样
    _scrollController.prepareJumpToPost(1);
    _highlightController.skipNextJumpHighlight = true;
    _visibilityTracker.reset();

    await notifier.cancelFilter();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
    }
  }

  Future<void> _handleShowAuthorOnly() async {
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);
    final detail = ref.read(topicDetailProvider(params)).value;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    final authorUsername = detail?.createdBy?.username;
    if (authorUsername == null || authorUsername.isEmpty) return;

    // 显示骨架屏
    setState(() => _isSwitchingMode = true);

    // 重置状态，和跳转到未加载数据时一样
    _scrollController.prepareJumpToPost(1);
    _highlightController.skipNextJumpHighlight = true;
    _visibilityTracker.reset();

    await notifier.showAuthorOnly(authorUsername);

    if (mounted) {
      setState(() => _isSwitchingMode = false);
    }
  }

  void _toggleExpandedHeader() {
    if (_expandController.status == AnimationStatus.completed || 
        _expandController.status == AnimationStatus.forward) {
      _expandController.reverse();
    } else {
      _expandController.forward();
    }
  }

  void _maybeSwitchToMasterDetail(bool canShowDetailPane, TopicDetail? detail) {
    if (widget.embeddedMode) {
      _lastCanShowDetailPane = canShowDetailPane;
      return;
    }

    final previous = _lastCanShowDetailPane;
    _lastCanShowDetailPane = canShowDetailPane;

    if (_isAutoSwitching || previous == null || previous == canShowDetailPane) {
      return;
    }

    if (!previous && canShowDetailPane) {
      _isAutoSwitching = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final navigator = Navigator.of(context);
        if (!navigator.canPop()) {
          _isAutoSwitching = false;
          return;
        }

        final currentPostNumber = _scrollController.currentPostNumber ?? widget.scrollToPostNumber;
        ref.read(selectedTopicProvider.notifier).select(
          topicId: widget.topicId,
          initialTitle: detail?.title ?? widget.initialTitle,
          scrollToPostNumber: currentPostNumber,
        );
        navigator.pop();
      });
    }
  }

  /// 在大屏上为内容添加宽度约束
  Widget _wrapWithConstraint(Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.maxContentWidth),
        child: child,
      ),
    );
  }

  /// 构建带动画的 AppBar
  PreferredSizeWidget _buildAppBar({
    required ThemeData theme,
    required TopicDetail? detail,
    required dynamic notifier,
  }) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: AnimatedBuilder(
        animation: _expandController,
        builder: (context, child) {
          final targetElevation = _isScrolledUnder ? 3.0 : 0.0;
          final currentElevation = targetElevation * (1.0 - _expandController.value);
          final expandProgress = _expandController.value;
          final shouldShowTitle = _showTitle || !_hasFirstPost;

          return AppBar(
            automaticallyImplyLeading: !widget.embeddedMode,
            elevation: currentElevation,
            scrolledUnderElevation: currentElevation,
            shadowColor: Colors.transparent,
            surfaceTintColor: theme.colorScheme.surfaceTint.withValues(alpha:(1.0 - expandProgress).clamp(0.0, 1.0)),
            backgroundColor: theme.colorScheme.surface,
            title: _buildAppBarTitle(
              theme: theme,
              detail: detail,
              shouldShowTitle: shouldShowTitle,
              expandProgress: expandProgress,
            ),
            centerTitle: false,
            actions: _buildAppBarActions(
              detail: detail,
              notifier: notifier,
              shouldShowTitle: shouldShowTitle,
              expandProgress: expandProgress,
            ),
          );
        },
      ),
    );
  }

  /// 构建 AppBar 标题
  Widget _buildAppBarTitle({
    required ThemeData theme,
    required TopicDetail? detail,
    required bool shouldShowTitle,
    required double expandProgress,
  }) {
    return Opacity(
      opacity: shouldShowTitle ? (1.0 - expandProgress).clamp(0.0, 1.0) : 0.0,
      child: GestureDetector(
        onTap: () {
          if (shouldShowTitle && detail != null) {
            _toggleExpandedHeader();
          }
        },
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
              if (detail?.hasAcceptedAnswer ?? false)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.check_box,
                      size: 18,
                      color: Colors.green,
                    ),
                  ),
                ),
              ...EmojiText.buildEmojiSpans(context, detail?.title ?? widget.initialTitle ?? '', theme.textTheme.titleMedium),
            ],
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 构建 AppBar Actions
  List<Widget> _buildAppBarActions({
    required TopicDetail? detail,
    required dynamic notifier,
    required bool shouldShowTitle,
    required double expandProgress,
  }) {
    if (detail == null || !shouldShowTitle) {
      return [];
    }

    // 编辑话题入口：可以编辑话题元数据 或 可以编辑首贴内容
    final firstPost = detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull;
    final canEditTopic = detail.canEdit || (firstPost?.canEdit ?? false);

    return [
      IgnorePointer(
        ignoring: expandProgress > 0.0,
        child: Opacity(
          opacity: (1.0 - expandProgress).clamp(0.0, 1.0),
          child: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多选项',
            onSelected: (value) {
              if (value == 'subscribe') {
                showNotificationLevelSheet(
                  context,
                  detail.notificationLevel,
                  (level) => _handleNotificationLevelChanged(notifier, level),
                );
              } else if (value == 'edit_topic') {
                _handleEditTopic();
              }
            },
            itemBuilder: (context) => [
              if (canEditTopic)
                PopupMenuItem(
                  value: 'edit_topic',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.edit_outlined,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      const SizedBox(width: 12),
                      const Text('编辑话题'),
                    ],
                  ),
                ),
              PopupMenuItem(
                value: 'subscribe',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      TopicNotificationButton.getIcon(detail.notificationLevel),
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(width: 12),
                    const Text('订阅设置'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ];
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
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    ref.listen<AsyncValue<void>>(authStateProvider, (_, _) {
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

    _maybeSwitchToMasterDetail(canShowDetailPane, detail);

    // 监听 MessageBus 新回复通知
    ref.listen(topicChannelProvider(widget.topicId), (previous, next) {
      if (next.hasNewReplies && !(previous?.hasNewReplies ?? false)) {
        debugPrint('[TopicDetail] New replies detected via MessageBus, loading...');
        notifier.loadNewReplies();
      }

      if (next.typingUsers.isNotEmpty || next.hasNewReplies) {
        if (_throttleTimer?.isActive ?? false) return;
        _throttleTimer = Timer(const Duration(milliseconds: 200), () {
          if (!mounted) return;
          if (_isScrollToBottomScheduled) return;
          _isScrollToBottomScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _isScrollToBottomScheduled = false;
            if (mounted) {
              _scrollController.scrollToBottomIfNeeded();
            }
          });
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
        appBar: _buildAppBar(
          theme: theme,
          detail: detail,
          notifier: notifier,
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
    final params = TopicDetailParams(widget.topicId, postNumber: _scrollController.currentPostNumber, instanceId: _instanceId);

    // 初始加载或切换模式时显示骨架屏
    // 注意：当 hasError 为 true 时，即使 isLoading 也为 true（AsyncLoading.copyWithPrevious 语义），
    // 也应该优先显示错误页面而不是骨架屏
    if (_isSwitchingMode) {
      final showHeaderSkeleton = widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return _wrapWithConstraint(PostListSkeleton(withHeader: showHeaderSkeleton));
    }
    
    if (detailAsync.isLoading && detail == null && !detailAsync.hasError) {
      final showHeaderSkeleton = widget.scrollToPostNumber == null || widget.scrollToPostNumber == 0;
      return _wrapWithConstraint(PostListSkeleton(withHeader: showHeaderSkeleton));
    }

    // 跳转中：等待包含目标帖子的新数据 - 显示骨架屏
    final jumpTarget = _scrollController.jumpTargetPostNumber;
    if (jumpTarget != null && detail != null) {
      final posts = detail.postStream.posts;
      // 检查目标帖子是否在当前加载的范围内
      final hasTarget = posts.isNotEmpty &&
          posts.first.postNumber <= jumpTarget &&
          posts.last.postNumber >= jumpTarget;
      if (!hasTarget) {
        return _wrapWithConstraint(const PostListSkeleton(withHeader: false));
      }
    }

    Widget content = const SizedBox();

    if (detailAsync.hasError && detail == null) {
      // 错误页面
      content = CustomScrollView(
        slivers: [
          SliverErrorView(
            error: detailAsync.error!,
            onRetry: () => ref.refresh(topicDetailProvider(params)),
          ),
        ],
      );
    } else if (detail != null) {
       // 正常内容构建 (保持原有逻辑，但简化提取)
       content = _buildPostListContent(context, detail, notifier, isLoggedIn, typingUsers);
    }

    // Stack 组装
    return Stack(
        children: [
          content,
          
          // TopicDetailOverlay (Bottom Bar)
          // 使用 ValueListenableBuilder 隔离状态变化，避免整页重建
          if (detail != null)
            ValueListenableBuilder<bool>(
              valueListenable: _scrollController.showBottomBarNotifier,
              builder: (context, showBottomBar, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: _visibilityTracker.streamIndexNotifier,
                  builder: (context, currentStreamIndex, _) {
                    return TopicDetailOverlay(
                      showBottomBar: showBottomBar,
                      isLoggedIn: isLoggedIn,
                      currentStreamIndex: currentStreamIndex,
                      totalCount: detail.postStream.stream.length,
                      detail: detail,
                      onScrollToTop: _scrollToTop,
                      onShare: _shareTopic,
                      onOpenInBrowser: _openInBrowser,
                      onReply: () => _handleReply(null),
                      onProgressTap: () => _showTimelineSheet(detail),
                      isSummaryMode: notifier.isSummaryMode,
                      isAuthorOnlyMode: notifier.isAuthorOnlyMode,
                      isLoading: _isSwitchingMode,
                      onShowTopReplies: _handleShowTopReplies,
                      onShowAuthorOnly: _handleShowAuthorOnly,
                      onCancelFilter: _handleCancelFilter,
                    );
                  },
                );
              },
            ),

          // Expanded Header 相关组件（使用 ValueListenableBuilder 隔离状态变化）
          ValueListenableBuilder<bool>(
            valueListenable: _isOverlayVisibleNotifier,
            builder: (context, isOverlayVisible, _) {
              if (!isOverlayVisible) return const SizedBox.shrink();

              return Stack(
                children: [
                  // Expanded Header Barrier
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _toggleExpandedHeader,
                      child: FadeTransition(
                        opacity: _expandController,
                        child: Container(color: Colors.black54),
                      ),
                    ),
                  ),

                  // Expanded Header
                  if (detail != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SlideTransition(
                        position: _animation,
                        child: Container(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.of(context).size.height * 0.7,
                          ),
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            elevation: 0,
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                            clipBehavior: Clip.antiAlias,
                            child: SingleChildScrollView(
                              child: TopicDetailHeader(
                                detail: detail,
                                headerKey: null,
                                onVoteChanged: _handleVoteChanged,
                                onNotificationLevelChanged: (level) => _handleNotificationLevelChanged(notifier, level),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      );
  }

  Widget _buildPostListContent(
    BuildContext context,
    TopicDetail detail,
    dynamic notifier,
    bool isLoggedIn,
    List<TypingUser> typingUsers,
  ) {
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

    // 计算分割线位置（热门回复模式下不显示）
    int? dividerPostIndex;
    if (!notifier.isSummaryMode) {
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

    // 使用 ValueListenableBuilder 隔离高亮状态变化，避免整页重建
    Widget scrollView = ValueListenableBuilder<int?>(
      valueListenable: _highlightController.highlightNotifier,
      builder: (context, highlightPostNumber, _) {
        return TopicPostList(
          detail: detail,
          scrollController: _scrollController.scrollController,
          centerKey: _centerKey,
          headerKey: _headerKey,
          highlightPostNumber: highlightPostNumber,
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
          onEdit: _handleEdit,
          onRefreshPost: _handleRefreshPost,
          onVoteChanged: _handleVoteChanged,
          onNotificationLevelChanged: (level) => _handleNotificationLevelChanged(notifier, level),
          onSolutionChanged: _handleSolutionChanged,
          onScrollNotification: _scrollController.handleScrollNotification,
        );
      },
    );

    scrollView = RefreshIndicator(
      onRefresh: _handleRefresh,
      notificationPredicate: (notification) {
        if (!hasFirstPost) return false;
        if (notification.depth != 0) return false;
        return true;
      },
      child: scrollView,
    );

    // 使用 ValueListenableBuilder 隔离定位状态变化，避免整页重建
    // 使用 child 参数避免 scrollView 重建
    return ValueListenableBuilder<bool>(
      valueListenable: _scrollController.isPositionedNotifier,
      builder: (context, isPositioned, child) {
        return Opacity(
          opacity: isPositioned ? 1.0 : 0.0,
          child: child,
        );
      },
      child: scrollView,
    );

  }
}
