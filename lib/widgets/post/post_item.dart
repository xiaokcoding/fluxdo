import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:share_plus/share_plus.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../constants.dart';
import '../../models/topic.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../pages/user_profile_page.dart';
import '../../providers/discourse_providers.dart';
import '../../services/discourse_service.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../utils/time_utils.dart';
import '../content/discourse_html_content/discourse_html_content.dart';
import '../common/flair_badge.dart';
import 'small_action_item.dart';
import 'moderator_action_item.dart';
import 'whisper_indicator.dart';

/// 获取 emoji 图片 URL
String _getEmojiUrl(String emojiName) {
  final url = EmojiHandler().getEmojiUrl(emojiName);
  if (url != null) return url;
  return '${AppConstants.baseUrl}/images/emoji/twitter/$emojiName.png?v=12';
}

class PostItem extends ConsumerStatefulWidget {
  final Post post;
  final int topicId;
  final VoidCallback? onReply;
  final VoidCallback? onLike;
  final VoidCallback? onEdit; // 编辑回调
  final void Function(int postNumber)? onJumpToPost;
  final void Function(bool isVisible)? onVisibilityChanged;
  final bool highlight;

  const PostItem({
    super.key,
    required this.post,
    required this.topicId,
    this.onReply,
    this.onLike,
    this.onEdit,
    this.onJumpToPost,
    this.onVisibilityChanged,
    this.highlight = false,
  });

  @override
  ConsumerState<PostItem> createState() => _PostItemState();
}

class _PostItemState extends ConsumerState<PostItem> {
  final DiscourseService _service = DiscourseService();
  final GlobalKey _likeButtonKey = GlobalKey();

  // 可见性状态
  bool _isVisible = false;

  // 点赞状态
  bool _isLiking = false;

  // 书签状态
  bool _isBookmarked = false;
  int? _bookmarkId; // 本地保存的书签 ID（用于当前会话添加的书签）
  bool _isBookmarking = false;

  // 回应状态
  late List<PostReaction> _reactions;
  PostReaction? _currentUserReaction;

  // 回复历史（被回复的帖子链）
  List<Post>? _replyHistory;
  bool _isLoadingReplyHistory = false;
  bool _showReplyHistory = false;

  // 回复列表（回复当前帖子的帖子）
  List<Post> _replies = [];
  bool _isLoadingReplies = false;
  bool _showReplies = false;

  // 缓存的头像 widget，避免重复创建
  Widget? _cachedAvatarWidget;
  int? _cachedPostId; // 记录缓存的 post ID

  bool get _canLoadMoreReplies => _replies.length < widget.post.replyCount;

  @override
  void initState() {
    super.initState();
    _initLikeState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 在这里初始化头像 widget，此时可以安全地访问 Theme.of(context)
    if (_cachedAvatarWidget == null || _cachedPostId != widget.post.id) {
      _initAvatarWidget();
    }
  }

  @override
  void didUpdateWidget(PostItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.id != widget.post.id) {
      _initLikeState();
      _initAvatarWidget();
    }
  }

  void _initLikeState() {
    _reactions = List.from(widget.post.reactions ?? []);
    _currentUserReaction = widget.post.currentUserReaction;
    _isBookmarked = widget.post.bookmarked;
    _bookmarkId = widget.post.bookmarkId; // 初始化书签 ID
  }

  void _initAvatarWidget() {
    final theme = Theme.of(context);
    _cachedAvatarWidget = _PostAvatar(
      key: ValueKey('avatar-${widget.post.id}'),
      post: widget.post,
      theme: theme,
    );
    _cachedPostId = widget.post.id;
  }

  /// 将点赞状态同步到 Provider
  void _syncReactionToProvider(List<PostReaction> reactions, PostReaction? currentUserReaction) {
    // 构造 params（使用传入的 topicId）
    final params = TopicDetailParams(widget.topicId);

    try {
      ref.read(topicDetailProvider(params).notifier)
         .updatePostReaction(widget.post.id, reactions, currentUserReaction);
    } catch (e) {
      // Provider 可能未初始化（例如从其他页面直接进入帖子详情）
      print('[PostItem] 同步点赞状态到 Provider 失败: $e');
    }
  }

  /// 点赞（使用 heart 回应）或取消当前回应
  Future<void> _toggleLike() async {
    if (_isLiking) return;
    
    // 震动反馈
    HapticFeedback.lightImpact();
    
    setState(() => _isLiking = true);

    // 如果已有回应，取消当前回应；否则添加 heart
    final reactionId = _currentUserReaction?.id ?? 'heart';
    final result = await _service.toggleReaction(widget.post.id, reactionId);
    if (mounted && result != null) {
      setState(() {
        _reactions = result['reactions'] as List<PostReaction>;
        _currentUserReaction = result['currentUserReaction'] as PostReaction?;
      });

      // 同步更新 Provider 状态
      _syncReactionToProvider(result['reactions'] as List<PostReaction>, result['currentUserReaction'] as PostReaction?);
    }
    if (mounted) setState(() => _isLiking = false);
  }

  /// 显示回应选择器
  void _showReactionPicker(BuildContext context, ThemeData theme) async {
    // 震动反馈
    HapticFeedback.mediumImpact();

    final reactions = await _service.getEnabledReactions();
    if (!mounted || reactions.isEmpty) return;

    final box = _likeButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    
    final buttonPos = box.localToGlobal(Offset.zero);
    final buttonSize = box.size;
    final screenWidth = MediaQuery.of(context).size.width;

    // 配置参数
    const double itemSize = 40.0; // 点击区域大小
    const double iconSize = 26.0; // 图标大小
    const double spacing = 1.0;
    const double padding = 4.0;
    const int crossAxisCount = 5; // 每行显示 5 个，更符合 10 个表情的布局
    
    // 计算尺寸
    final int count = reactions.length;
    final int cols = count < crossAxisCount ? count : crossAxisCount;
    final int rows = (count / crossAxisCount).ceil();
    
    final double pickerWidth = (itemSize * cols) + (spacing * (cols - 1)) + (padding * 2) + 4.0; // 增加 4.0 冗余防止换行
    final double pickerHeight = (itemSize * rows) + (spacing * (rows - 1)) + (padding * 2);

    // 计算左边位置：居中于按钮，但限制在屏幕内
    double left = (buttonPos.dx + buttonSize.width / 2) - (pickerWidth / 2);
    if (left < 16) left = 16;
    if (left + pickerWidth > screenWidth - 16) left = screenWidth - pickerWidth - 16;
    
    // 计算顶部位置：默认在按钮上方
    bool isAbove = true;
    double top = buttonPos.dy - pickerHeight - 12;
    // 简单判断边界，如果上方空间不足，则显示在下方 (这里假设 TopBar 高度等)
    if (top < 80) {
      top = buttonPos.dy + buttonSize.height + 12;
      isAbove = false;
    }

    // 计算动画原点 Alignment
    // 1. 按钮中心 X 坐标
    final buttonCenterX = buttonPos.dx + buttonSize.width / 2;
    // 2. Picker 左边缘 X 坐标是 left
    // 3. 按钮中心相对于 Picker 的归一化 X 坐标 (0.0 ~ 1.0)
    final relativeX = (buttonCenterX - left) / pickerWidth;
    // 4. 转换为 Alignment X (-1.0 ~ 1.0)
    final alignmentX = relativeX * 2 - 1;
    // 5. Y 轴 Alignment：在上方则底部对齐(1.0)，在下方则顶部对齐(-1.0)
    final alignmentY = isAbove ? 1.0 : -1.0;
    
    final transformAlignment = Alignment(alignmentX, alignmentY);

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.transparent, // 不使用背景遮罩，保持清爽
      transitionDuration: const Duration(milliseconds: 450), // 增加时长让挤出效果更明显
      pageBuilder: (_, __, ___) => const SizedBox(),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        // 弹簧动画曲线产生挤出效果
        final curvedValue = Curves.elasticOut.transform(animation.value);
        // 透明度动画优化：快速显现，避免幽灵感，配合挤出动画更真实
        final opacity = (animation.value / 0.15).clamp(0.0, 1.0);
        
        return Stack(
          children: [
            // 全屏透明点击层，用于点击外部关闭
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => Navigator.pop(context),
                child: Container(color: Colors.transparent),
              ),
            ),
            // 气泡主体
            Positioned(
              left: left,
              top: top,
              child: Transform.scale(
                scale: curvedValue,
                alignment: transformAlignment, // 动态计算的原点
                child: Opacity(
                  opacity: opacity,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: pickerWidth,
                      height: pickerHeight,
                      padding: const EdgeInsets.all(padding),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(30), // 药丸形状
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 16,
                            spreadRadius: 2,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                          width: 0.5,
                        ),
                      ),
                      child: Wrap(
                        spacing: spacing,
                        runSpacing: spacing,
                        alignment: WrapAlignment.center,
                        children: reactions.map((r) {
                          final isCurrent = _currentUserReaction?.id == r;
                          return GestureDetector(
                            onTap: () {
                              HapticFeedback.lightImpact(); // 选中震动
                              Navigator.pop(context);
                              _toggleReaction(r);
                            },
                            child: Container(
                              width: itemSize,
                              height: itemSize,
                              decoration: BoxDecoration(
                                color: isCurrent ? theme.colorScheme.primaryContainer : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Image(
                                  image: discourseImageProvider(_getEmojiUrl(r)),
                                  width: iconSize,
                                  height: iconSize,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.emoji_emotions_outlined, size: 24),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 切换回应
  Future<void> _toggleReaction(String reactionId) async {
    final result = await _service.toggleReaction(widget.post.id, reactionId);
    if (!mounted || result == null) return;

    setState(() {
      _reactions = result['reactions'] as List<PostReaction>;
      _currentUserReaction = result['currentUserReaction'] as PostReaction?;
    });

    // 同步更新 Provider 状态
    _syncReactionToProvider(result['reactions'] as List<PostReaction>, result['currentUserReaction'] as PostReaction?);
  }

  /// 切换回复历史显示（点击后先加载，加载完成再显示）
  Future<void> _toggleReplyHistory() async {
    if (_showReplyHistory) {
      setState(() => _showReplyHistory = false);
      return;
    }

    // 如果已有数据，直接显示
    if (_replyHistory != null) {
      setState(() => _showReplyHistory = true);
      return;
    }

    // 否则先加载（loading 状态在按钮上显示）
    if (_isLoadingReplyHistory) return;

    setState(() => _isLoadingReplyHistory = true);
    try {
      final history = await _service.getPostReplyHistory(widget.post.id);
      if (mounted) {
        setState(() {
          _replyHistory = history;
          _isLoadingReplyHistory = false;
          _showReplyHistory = true; // 加载完成后直接显示
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingReplyHistory = false);
      }
    }
  }

  /// 加载回复列表
  Future<void> _loadReplies() async {
    if (_isLoadingReplies) return;

    setState(() => _isLoadingReplies = true);
    try {
      final after = _replies.isNotEmpty ? _replies.last.postNumber : 1;
      final replies = await _service.getPostReplies(widget.post.id, after: after);
      if (mounted) {
        setState(() {
          _replies.addAll(replies);
          _isLoadingReplies = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingReplies = false);
      }
    }
  }

  /// 切换回复列表显示（点击后先加载，加载完成再显示）
  Future<void> _toggleReplies() async {
    if (_showReplies) {
      setState(() => _showReplies = false);
      return;
    }

    // 如果已有数据，直接显示
    if (_replies.isNotEmpty) {
      setState(() => _showReplies = true);
      return;
    }

    // 否则先加载（loading 状态在按钮上显示）
    if (_isLoadingReplies) return;

    setState(() => _isLoadingReplies = true);
    try {
      final replies = await _service.getPostReplies(widget.post.id, after: 1);
      if (mounted) {
        setState(() {
          _replies.addAll(replies);
          _isLoadingReplies = false;
          _showReplies = true; // 加载完成后直接显示
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingReplies = false);
      }
    }
  }

  /// 分享帖子
  Future<void> _sharePost() async {
    final post = widget.post;
    final url = '${AppConstants.baseUrl}/t/${widget.topicId}/${post.postNumber}';
    await Share.share(url);
  }

  /// 切换书签状态
  Future<void> _toggleBookmark() async {
    if (_isBookmarking) return;

    HapticFeedback.lightImpact();
    setState(() => _isBookmarking = true);

    try {
      if (_isBookmarked) {
        // 取消书签 - 优先使用本地保存的 ID，否则使用 Post 模型中的 ID
        final bookmarkId = _bookmarkId ?? widget.post.bookmarkId;
        if (bookmarkId != null) {
          final success = await _service.deleteBookmark(bookmarkId);
          if (mounted && success) {
            setState(() {
              _isBookmarked = false;
              _bookmarkId = null;
            });
            _showSnackBar('已取消书签');
          } else if (mounted) {
            _showSnackBar('取消书签失败');
          }
        } else {
          _showSnackBar('无法取消书签：缺少书签 ID');
        }
      } else {
        // 添加书签
        final bookmarkId = await _service.bookmarkPost(widget.post.id);
        if (mounted && bookmarkId != null) {
          setState(() {
            _isBookmarked = true;
            _bookmarkId = bookmarkId; // 保存书签 ID
          });
          _showSnackBar('已添加书签');
        } else if (mounted) {
          _showSnackBar('添加书签失败');
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('操作失败');
      }
    } finally {
      if (mounted) {
        setState(() => _isBookmarking = false);
      }
    }
  }

  /// 显示举报对话框
  void _showFlagDialog(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _FlagBottomSheet(
        postId: widget.post.id,
        postUsername: widget.post.username,
        service: _service,
        onSuccess: () {
          _showSnackBar('举报已提交');
        },
      ),
    );
  }

  /// 显示扩展菜单
  void _showMoreMenu(BuildContext context, ThemeData theme) {
    final isGuest = ref.read(currentUserProvider).value == null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 编辑（仅当有编辑权限时显示）
              if (widget.post.canEdit && widget.onEdit != null)
                ListTile(
                  leading: Icon(Icons.edit_outlined, color: theme.colorScheme.primary),
                  title: Text('编辑', style: TextStyle(color: theme.colorScheme.primary)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onEdit!();
                  },
                ),
              // 分享
              ListTile(
                leading: Icon(Icons.share_outlined, color: theme.colorScheme.onSurface),
                title: const Text('分享'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sharePost();
                },
              ),
              if (!isGuest) ...[
                // 书签
                ListTile(
                  leading: Icon(
                    _isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: _isBookmarked ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                  ),
                  title: Text(_isBookmarked ? '取消书签' : '添加书签'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleBookmark();
                  },
                ),
                // 举报
                ListTile(
                  leading: Icon(Icons.flag_outlined, color: theme.colorScheme.error),
                  title: Text('举报', style: TextStyle(color: theme.colorScheme.error)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showFlagDialog(context, theme);
                  },
                ),
              ],
              const SizedBox(height: 8),
              // 取消按钮
              ListTile(
                title: Text(
                  '取消',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final theme = Theme.of(context);

    // 根据帖子类型分发到不同组件
    // small_action (3): 系统操作帖子（置顶、关闭等）
    if (post.postType == PostTypes.smallAction) {
      return SmallActionItem(post: post);
    }
    
    // moderator_action (2): 版主操作帖子
    if (post.postType == PostTypes.moderatorAction) {
      return ModeratorActionItem(
        post: post,
        topicId: widget.topicId,
        onReply: widget.onReply,
      );
    }

    final bool isWhisper = post.postType == PostTypes.whisper;

    // 获取当前用户信息，判断是否是自己的帖子
    // 使用 read 而非 watch，避免用户状态变化时所有帖子重建
    final currentUser = ref.read(currentUserProvider).value;
    final isOwnPost = currentUser != null && currentUser.username == post.username;
    final isGuest = currentUser == null;

    final backgroundColor = theme.colorScheme.surface;
    // 增加高亮颜色的不透明度，使其更明显
    final highlightColor = theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5);
    final targetColor = widget.highlight
        ? Color.alphaBlend(highlightColor, backgroundColor)
        : backgroundColor;

    return VisibilityDetector(
      key: Key('post-visibility-${post.id}'),
      onVisibilityChanged: (info) {
        final isVisible = info.visibleFraction > 0;
        if (isVisible != _isVisible) {
          _isVisible = isVisible;
          widget.onVisibilityChanged?.call(isVisible);
        }
      },
      child: RepaintBoundary(
        child: Container(
          constraints: const BoxConstraints(minHeight: 80),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: targetColor,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Avatar, Name, Time
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _cachedAvatarWidget!,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            (post.name != null && post.name!.isNotEmpty) ? post.name! : post.username,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: theme.colorScheme.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        if (isWhisper) ...[
                          const SizedBox(width: 8),
                          const WhisperIndicator(),
                        ],
                      ],
                    ),
                    if (post.name != null && post.name!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          post.username,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                  ],
                ),
              ),
              // 右侧：回复指示 + 时间 + 楼层号
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (post.replyToUser != null) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _isLoadingReplyHistory ? null : _toggleReplyHistory,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.1)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isLoadingReplyHistory)
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              Icon(
                                Icons.reply,
                                size: 14,
                                color: theme.colorScheme.primary,
                              ),
                            const SizedBox(width: 6),
                            CircleAvatar(
                              radius: 10,
                              backgroundColor: theme.colorScheme.primaryContainer,
                              backgroundImage: post.replyToUser!.avatarTemplate.isNotEmpty
                                  ? discourseImageProvider(
                                      post.replyToUser!.avatarTemplate.startsWith('http')
                                          ? post.replyToUser!.avatarTemplate.replaceAll('{size}', '40')
                                          : '${AppConstants.baseUrl}${post.replyToUser!.avatarTemplate.replaceAll('{size}', '40')}',
                                    )
                                  : null,
                              child: post.replyToUser!.avatarTemplate.isEmpty
                                  ? Text(
                                      post.replyToUser!.username[0].toUpperCase(),
                                      style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Text(
                            TimeUtils.formatRelativeTime(post.createdAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                              fontSize: 11,
                            ),
                          ),
                          Positioned(
                            right: -6, // 右上角角标位置，稍微向右偏移但不回贴边
                            top: -2,  // 稍微向上偏移
                            child: Consumer(
                              builder: (context, ref, _) {
                                // 监听会话已读状态
                                final sessionState = ref.watch(topicSessionProvider(widget.topicId));
                                // 判断是否显示：服务器说是未读 + 本机没读过
                                final isNew = !widget.post.read;
                                final isReadInSession = sessionState.readPostNumbers.contains(widget.post.postNumber);
                                final show = isNew && !isReadInSession;

                                return AnimatedOpacity(
                                  opacity: show ? 1.0 : 0.0,
                                  duration: const Duration(milliseconds: 500),
                                  curve: Curves.easeOut,
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: theme.colorScheme.surface, // 添加描边，增加对比度
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '#${post.postNumber}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),

          // 被回复帖子预览（回复历史）
          if (_showReplyHistory)
            _buildReplyHistoryPreview(theme),
          
          const SizedBox(height: 12),

                    // Content (HTML)
                    ChunkedHtmlContent(
                      html: post.cooked,
                      textStyle: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.5,
                      ),
                      linkCounts: post.linkCounts,
                      mentionedUsers: post.mentionedUsers,
                      post: post,
                      topicId: widget.topicId,
                      onInternalLinkTap: (topicId, topicSlug) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TopicDetailPage(
                              topicId: topicId,
                              initialTitle: topicSlug,
                            ),
                          ),
                        );
                      },
                    ),
                    
                    const SizedBox(height: 12),

                    // Actions
                    Row(
                      children: [
                        // 回复数按钮
                        if (widget.post.replyCount > 0)
                          GestureDetector(
                            onTap: _isLoadingReplies ? null : _toggleReplies,
                            child: Container(
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: _showReplies 
                                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: _showReplies 
                                      ? theme.colorScheme.primary.withValues(alpha: 0.2)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isLoadingReplies && _replies.isEmpty)
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  else ...[
                                    Icon(
                                      Icons.chat_bubble_outline_rounded,
                                      size: 15,
                                      color: _showReplies 
                                          ? theme.colorScheme.primary 
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${widget.post.replyCount}',
                                      style: theme.textTheme.labelMedium?.copyWith(
                                        color: _showReplies 
                                            ? theme.colorScheme.primary 
                                            : theme.colorScheme.onSurfaceVariant,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      _showReplies ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                      size: 18,
                                      color: _showReplies 
                                          ? theme.colorScheme.primary 
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),

                        const Spacer(),
                        if (!isGuest) ...[
                          // 回应和赞（如果是自己的帖子且没有回应，则隐藏整个按钮）
                          if (!isOwnPost || _reactions.isNotEmpty)
                            GestureDetector(
                              key: _likeButtonKey,
                              // 如果是自己的帖子，禁用点击和长按功能
                              onTap: isOwnPost ? null : (_isLiking ? null : _toggleLike),
                              onLongPress: isOwnPost ? null : () => _showReactionPicker(context, theme),
                              child: Container(
                                height: 36,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: _currentUserReaction != null
                                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                                      : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: _currentUserReaction != null
                                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 回应表情预览
                                    if (_reactions.isNotEmpty && !(_reactions.length == 1 && _reactions.first.id == 'heart'))
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          ..._reactions.take(3).map((reaction) => Padding(
                                            padding: const EdgeInsets.only(right: 2),
                                            child: Image(
                                              image: discourseImageProvider(_getEmojiUrl(reaction.id)),
                                              width: 16,
                                              height: 16,
                                            ),
                                          )),
                                          const SizedBox(width: 6),
                                        ],
                                      ),

                                    // 赞数量
                                    if (_reactions.isNotEmpty)
                                      Text(
                                        '${_reactions.fold(0, (sum, r) => sum + r.count)}',
                                        style: theme.textTheme.labelMedium?.copyWith(
                                          color: _currentUserReaction != null
                                              ? theme.colorScheme.primary
                                              : theme.colorScheme.onSurfaceVariant,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    if (_reactions.isNotEmpty) const SizedBox(width: 6),

                                    // 点赞图标/回应图标
                                    if (_currentUserReaction != null)
                                      // 显示当前用户的回应
                                      Image(
                                        image: discourseImageProvider(_getEmojiUrl(_currentUserReaction!.id)),
                                        width: 20,
                                        height: 20,
                                      )
                                    else
                                      // 显示空心爱心（包括自己的帖子有回应时）
                                      Icon(
                                        Icons.favorite_border,
                                        size: 20,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                  ],
                                ),
                              ),
                            ),

                          const SizedBox(width: 8),

                          // 回复按钮
                          GestureDetector(
                            onTap: widget.onReply,
                            child: Container(
                              height: 36,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.reply,
                                    size: 18,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '回复',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(width: 8),

                        // 更多按钮
                        GestureDetector(
                          onTap: () => _showMoreMenu(context, theme),
                          child: Container(
                            height: 36,
                            width: 36,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.more_horiz,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
          
                    // 回复列表
                    if (_showReplies)
                      _buildRepliesList(theme),
                  ],
                ),
              ),
            ),
          );
        }

  Widget _buildReplyHistoryPreview(ThemeData theme) {
    // 如果没有数据就不显示（loading 时不会进入这里）
    if (_replyHistory == null || _replyHistory!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Area
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Icon(Icons.format_quote_rounded, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '回复给',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    setState(() => _showReplyHistory = false);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
          // Reply Items
          ..._replyHistory!.map((replyPost) {
            final avatarUrl = replyPost.getAvatarUrl(size: 60);
            return InkWell(
              onTap: () => widget.onJumpToPost?.call(replyPost.postNumber),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      backgroundImage: avatarUrl.isNotEmpty
                          ? discourseImageProvider(avatarUrl)
                          : null,
                      child: avatarUrl.isEmpty
                          ? Text(replyPost.username[0].toUpperCase(), style: const TextStyle(fontSize: 10))
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                (replyPost.name != null && replyPost.name!.isNotEmpty) ? replyPost.name! : replyPost.username,
                                style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '#${replyPost.postNumber}',
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                              const Spacer(),
                              Icon(Icons.arrow_outward, size: 12, color: theme.colorScheme.onSurfaceVariant),
                            ],
                          ),
                          const SizedBox(height: 4),
                          IgnorePointer(
                            child: ShaderMask(
                              shaderCallback: (rect) {
                                return const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.black, Colors.transparent],
                                  stops: [0.6, 1.0],
                                ).createShader(rect);
                              },
                              blendMode: BlendMode.dstIn,
                              child: Container(
                                constraints: const BoxConstraints(maxHeight: 60),
                                child: SingleChildScrollView(
                                  physics: const NeverScrollableScrollPhysics(),
                                  child: DiscourseHtmlContent(
                                    html: replyPost.cooked,
                                    textStyle: theme.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.4),
                                    compact: true,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRepliesList(ThemeData theme) {
    // 如果没有数据就不显示（loading 时不会进入这里）
    if (_replies.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部小标题
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.post.replyCount} 条回复',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          
          // 已加载的回复列表
          ..._replies.map((reply) {
            final avatarUrl = reply.getAvatarUrl(size: 60);
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => widget.onJumpToPost?.call(reply.postNumber),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          backgroundImage: avatarUrl.isNotEmpty
                              ? discourseImageProvider(avatarUrl)
                              : null,
                          child: avatarUrl.isEmpty
                              ? Text(reply.username[0].toUpperCase(), style: const TextStyle(fontSize: 10))
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      (reply.name != null && reply.name!.isNotEmpty) ? reply.name! : reply.username,
                                      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '#${reply.postNumber}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              IgnorePointer(
                                child: DiscourseHtmlContent(
                                  html: reply.cooked,
                                  textStyle: theme.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.4),
                                  compact: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),

          // 底部操作栏
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_canLoadMoreReplies) 
                TextButton.icon(
                  onPressed: _isLoadingReplies ? null : _loadReplies,
                  icon: _isLoadingReplies 
                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) 
                    : const Icon(Icons.refresh, size: 16),
                  label: const Text('加载更多回复'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
               const SizedBox(width: 8),
               TextButton.icon(
                  onPressed: () {
                    setState(() => _showReplies = false);
                  },
                  icon: Icon(Icons.expand_less, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  label: Text('收起回复', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 举报底部弹窗
class _FlagBottomSheet extends StatefulWidget {
  final int postId;
  final String postUsername; // 帖子作者用户名
  final DiscourseService service;
  final VoidCallback? onSuccess;

  const _FlagBottomSheet({
    required this.postId,
    required this.postUsername,
    required this.service,
    this.onSuccess,
  });

  @override
  State<_FlagBottomSheet> createState() => _FlagBottomSheetState();
}

class _FlagBottomSheetState extends State<_FlagBottomSheet> {
  FlagType? _selectedType;
  final _messageController = TextEditingController();
  bool _isSubmitting = false;
  List<FlagType> _flagTypes = [];
  bool _isLoading = true;

  // 分组：notify_user 类型单独一组
  List<FlagType> get _notifyUserTypes =>
      _flagTypes.where((f) => f.nameKey == 'notify_user').toList();
  List<FlagType> get _moderatorTypes =>
      _flagTypes.where((f) => f.nameKey != 'notify_user').toList();

  /// 替换描述中的占位符
  String _replaceDescription(String description) {
    return description
        .replaceAll('%{username}', widget.postUsername)
        .replaceAll('@%{username}', '@${widget.postUsername}');
  }

  @override
  void initState() {
    super.initState();
    _loadFlagTypes();
  }

  Future<void> _loadFlagTypes() async {
    final preloaded = PreloadedDataService();
    final types = await preloaded.getPostActionTypes();

    if (mounted) {
      setState(() {
        if (types != null && types.isNotEmpty) {
          _flagTypes = types
              .map((t) => FlagType.fromJson(t))
              .where((f) => f.isFlag && f.enabled && f.appliesToPost)
              .toList()
            ..sort((a, b) => a.position.compareTo(b.position));
        } else {
          _flagTypes = FlagType.defaultTypes;
        }
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submitFlag() async {
    if (_selectedType == null) return;
    if (_isSubmitting) return;

    setState(() => _isSubmitting = true);

    final success = await widget.service.flagPost(
      widget.postId,
      _selectedType!.id,
      message: _messageController.text.isNotEmpty ? _messageController.text : null,
    );

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (success) {
        Navigator.pop(context);
        widget.onSuccess?.call();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('举报失败，请稍后重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.all(16),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题（固定）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.flag_outlined, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Text(
                    '举报帖子',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            // 可滚动内容
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 加载状态
                    if (_isLoading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else ...[
                      // 向用户发送消息分组
                      if (_notifyUserTypes.isNotEmpty) ...[
                        _buildSectionHeader(
                          '向 @${widget.postUsername} 发送消息',
                          theme,
                        ),
                        ..._notifyUserTypes.map((type) => _buildFlagOption(type, theme)),
                        const SizedBox(height: 16),
                        Divider(color: theme.colorScheme.outlineVariant),
                        const SizedBox(height: 16),
                      ],
                      // 私下通知管理人员分组
                      if (_moderatorTypes.isNotEmpty) ...[
                        _buildSectionHeader('私下通知管理人员', theme),
                        ..._moderatorTypes.map((type) => _buildFlagOption(type, theme)),
                      ],
                    ],

                    // 补充说明输入框
                    if (_selectedType?.requireMessage == true) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _messageController,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: '请描述具体问题...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.all(12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 提交按钮（固定在底部）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selectedType == null || _isSubmitting || _isLoading ? null : _submitFlag,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('提交举报'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildFlagOption(FlagType type, ThemeData theme) {
    final isSelected = _selectedType?.id == type.id;
    final description = _replaceDescription(type.description);

    return InkWell(
      onTap: () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildDescriptionText(description, theme),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建描述文本，支持 HTML 链接
  Widget _buildDescriptionText(String description, ThemeData theme) {
    return HtmlWidget(
      description,
      textStyle: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      customStylesBuilder: (element) {
        if (element.localName == 'a') {
          return {'text-decoration': 'none'};
        }
        return null;
      },
      onTapUrl: (url) {
        final fullUrl = url.startsWith('http') ? url : '${AppConstants.baseUrl}$url';
        // TODO: 使用 url_launcher 打开链接
        debugPrint('Open URL: $fullUrl');
        return true;
      },
    );
  }
}

/// 帖子头像组件（独立widget避免不必要的重建）
class _PostAvatar extends StatefulWidget {
  final Post post;
  final ThemeData theme;

  const _PostAvatar({
    super.key,
    required this.post,
    required this.theme,
  });

  @override
  State<_PostAvatar> createState() => _PostAvatarState();
}

class _PostAvatarState extends State<_PostAvatar> {
  late String _avatarUrl;
  ImageProvider? _cachedImageProvider;

  @override
  void initState() {
    super.initState();
    _avatarUrl = widget.post.getAvatarUrl();
    if (_avatarUrl.isNotEmpty) {
      _cachedImageProvider = discourseImageProvider(_avatarUrl);
    }
  }

  @override
  void didUpdateWidget(_PostAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有当 URL 真的变化时才更新 ImageProvider
    final newUrl = widget.post.getAvatarUrl();
    if (newUrl != _avatarUrl) {
      _avatarUrl = newUrl;
      _cachedImageProvider = newUrl.isNotEmpty ? discourseImageProvider(newUrl) : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserProfilePage(username: widget.post.username)),
      ),
      child: AvatarWithFlair(
        flairSize: 17,
        flairRight: -4,
        flairBottom: -2,
        flairUrl: widget.post.flairUrl,
        flairName: widget.post.flairName,
        flairBgColor: widget.post.flairBgColor,
        flairColor: widget.post.flairColor,
        avatar: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.theme.colorScheme.outlineVariant,
              width: 1,
            ),
          ),
          child: CircleAvatar(
            radius: 20,
            backgroundColor: Colors.transparent,
            backgroundImage: _cachedImageProvider,
            child: _avatarUrl.isEmpty
                ? Text(
                    widget.post.username[0].toUpperCase(),
                    style: TextStyle(
                      color: widget.theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
