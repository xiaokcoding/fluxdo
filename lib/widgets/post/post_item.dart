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
import '../../providers/preferences_provider.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../utils/time_utils.dart';
import '../content/discourse_html_content/discourse_html_content.dart';
import '../common/flair_badge.dart';
import '../common/smart_avatar.dart';
import 'small_action_item.dart';
import 'moderator_action_item.dart';
import 'whisper_indicator.dart';
import 'post_links.dart';

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
  final void Function(int postId)? onRefreshPost; // 刷新帖子回调（用于删除/恢复后）
  final void Function(int postNumber)? onJumpToPost;
  final void Function(bool isVisible)? onVisibilityChanged;
  final void Function(int postId, bool accepted)? onSolutionChanged; // 解决方案状态变化回调
  final bool highlight;
  final bool isTopicOwner;
  final bool topicHasAcceptedAnswer; // 话题是否有解决方案
  final int? acceptedAnswerPostNumber; // 解决方案的帖子编号

  const PostItem({
    super.key,
    required this.post,
    required this.topicId,
    this.onReply,
    this.onLike,
    this.onEdit,
    this.onRefreshPost,
    this.onJumpToPost,
    this.onVisibilityChanged,
    this.onSolutionChanged,
    this.highlight = false,
    this.isTopicOwner = false,
    this.topicHasAcceptedAnswer = false,
    this.acceptedAnswerPostNumber,
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
  /// 回复历史加载状态 ValueNotifier（用于隔离 UI 更新）
  final ValueNotifier<bool> _isLoadingReplyHistoryNotifier = ValueNotifier<bool>(false);
  /// 回复历史显示状态 ValueNotifier（用于隔离 UI 更新）
  final ValueNotifier<bool> _showReplyHistoryNotifier = ValueNotifier<bool>(false);

  // 回复列表（回复当前帖子的帖子）
  final List<Post> _replies = [];
  /// 回复列表加载状态 ValueNotifier（用于隔离 UI 更新）
  final ValueNotifier<bool> _isLoadingRepliesNotifier = ValueNotifier<bool>(false);
  /// 回复列表显示状态 ValueNotifier（用于隔离 UI 更新）
  final ValueNotifier<bool> _showRepliesNotifier = ValueNotifier<bool>(false);

  // 缓存的头像 widget，避免重复创建
  Widget? _cachedAvatarWidget;
  int? _cachedPostId; // 记录缓存的 post ID

  // 解决方案状态
  bool _isAcceptedAnswer = false;
  bool _isTogglingAnswer = false;

  // 删除状态
  bool _isDeleting = false;

  bool get _canLoadMoreReplies => _replies.length < widget.post.replyCount;

  @override
  void initState() {
    super.initState();
    _initLikeState();
  }

  @override
  void dispose() {
    _isLoadingReplyHistoryNotifier.dispose();
    _showReplyHistoryNotifier.dispose();
    _isLoadingRepliesNotifier.dispose();
    _showRepliesNotifier.dispose();
    super.dispose();
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
    _isAcceptedAnswer = widget.post.acceptedAnswer; // 初始化解决方案状态
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
      debugPrint('[PostItem] 同步点赞状态到 Provider 失败: $e');
    }
  }

  /// 点赞（使用 heart 回应）或取消当前回应
  Future<void> _toggleLike() async {
    if (_isLiking) return;

    // 震动反馈
    HapticFeedback.lightImpact();

    setState(() => _isLiking = true);

    try {
      // 如果已有回应，取消当前回应；否则添加 heart
      final reactionId = _currentUserReaction?.id ?? 'heart';
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (mounted) {
        setState(() {
          _reactions = result['reactions'] as List<PostReaction>;
          _currentUserReaction = result['currentUserReaction'] as PostReaction?;
        });

        // 同步更新 Provider 状态
        _syncReactionToProvider(result['reactions'] as List<PostReaction>, result['currentUserReaction'] as PostReaction?);
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) setState(() => _isLiking = false);
    }
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
    // ignore: use_build_context_synchronously
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
      // ignore: use_build_context_synchronously
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.transparent, // 不使用背景遮罩，保持清爽
      transitionDuration: const Duration(milliseconds: 450), // 增加时长让挤出效果更明显
      pageBuilder: (_, _, _) => const SizedBox(),
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
                                  errorBuilder: (_, _, _) => const Icon(Icons.emoji_emotions_outlined, size: 24),
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
    try {
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (!mounted) return;

      setState(() {
        _reactions = result['reactions'] as List<PostReaction>;
        _currentUserReaction = result['currentUserReaction'] as PostReaction?;
      });

      // 同步更新 Provider 状态
      _syncReactionToProvider(result['reactions'] as List<PostReaction>, result['currentUserReaction'] as PostReaction?);
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    }
  }

  /// 切换回复历史显示（点击后先加载，加载完成再显示）
  Future<void> _toggleReplyHistory() async {
    if (_showReplyHistoryNotifier.value) {
      _showReplyHistoryNotifier.value = false;
      return;
    }

    // 如果已有数据，直接显示
    if (_replyHistory != null) {
      _showReplyHistoryNotifier.value = true;
      return;
    }

    // 否则先加载（loading 状态在按钮上显示）
    if (_isLoadingReplyHistoryNotifier.value) return;

    _isLoadingReplyHistoryNotifier.value = true;
    try {
      final history = await _service.getPostReplyHistory(widget.post.id);
      if (mounted) {
        _replyHistory = history;
        _isLoadingReplyHistoryNotifier.value = false;
        _showReplyHistoryNotifier.value = true; // 加载完成后直接显示
      }
    } catch (e) {
      if (mounted) {
        _isLoadingReplyHistoryNotifier.value = false;
      }
    }
  }

  /// 加载回复列表
  Future<void> _loadReplies() async {
    if (_isLoadingRepliesNotifier.value) return;

    _isLoadingRepliesNotifier.value = true;
    try {
      final after = _replies.isNotEmpty ? _replies.last.postNumber : 1;
      final replies = await _service.getPostReplies(widget.post.id, after: after);
      if (mounted) {
        _replies.addAll(replies);
        _isLoadingRepliesNotifier.value = false;
      }
    } catch (e) {
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    }
  }

  /// 切换回复列表显示（点击后先加载，加载完成再显示）
  Future<void> _toggleReplies() async {
    if (_showRepliesNotifier.value) {
      _showRepliesNotifier.value = false;
      return;
    }

    // 如果已有数据，直接显示
    if (_replies.isNotEmpty) {
      _showRepliesNotifier.value = true;
      return;
    }

    // 否则先加载（loading 状态在按钮上显示）
    if (_isLoadingRepliesNotifier.value) return;

    _isLoadingRepliesNotifier.value = true;
    try {
      final replies = await _service.getPostReplies(widget.post.id, after: 1);
      if (mounted) {
        _replies.addAll(replies);
        _isLoadingRepliesNotifier.value = false;
        _showRepliesNotifier.value = true; // 加载完成后直接显示
      }
    } catch (e) {
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    }
  }

  /// 分享帖子
  Future<void> _sharePost() async {
    final post = widget.post;
    final url = '${AppConstants.baseUrl}/t/${widget.topicId}/${post.postNumber}';
    await SharePlus.instance.share(ShareParams(text: url));
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
          await _service.deleteBookmark(bookmarkId);
          if (mounted) {
            setState(() {
              _isBookmarked = false;
              _bookmarkId = null;
            });
            _showSnackBar('已取消书签');
          }
        } else {
          _showSnackBar('无法取消书签：缺少书签 ID');
        }
      } else {
        // 添加书签
        final bookmarkId = await _service.bookmarkPost(widget.post.id);
        if (mounted) {
          setState(() {
            _isBookmarked = true;
            _bookmarkId = bookmarkId; // 保存书签 ID
          });
          _showSnackBar('已添加书签');
        }
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isBookmarking = false);
      }
    }
  }

  /// 切换解决方案状态
  Future<void> _toggleSolution() async {
    if (_isTogglingAnswer) return;

    HapticFeedback.lightImpact();
    setState(() => _isTogglingAnswer = true);

    try {
      if (_isAcceptedAnswer) {
        // 取消采纳
        await _service.unacceptAnswer(widget.post.id);
        if (mounted) {
          setState(() => _isAcceptedAnswer = false);
          widget.onSolutionChanged?.call(widget.post.id, false);
          _showSnackBar('已取消采纳');
        }
      } else {
        // 采纳答案
        await _service.acceptAnswer(widget.post.id);
        if (mounted) {
          setState(() => _isAcceptedAnswer = true);
          widget.onSolutionChanged?.call(widget.post.id, true);
          _showSnackBar('已采纳为解决方案');
        }
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isTogglingAnswer = false);
      }
    }
  }

  /// 显示删除确认对话框
  void _showDeleteConfirmDialog(BuildContext context, ThemeData theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除回复'),
        content: const Text('确定要删除这条回复吗？此操作可以撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deletePost();
            },
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 删除帖子
  Future<void> _deletePost() async {
    if (_isDeleting) return;

    HapticFeedback.lightImpact();
    setState(() => _isDeleting = true);

    try {
      await _service.deletePost(widget.post.id);
      if (mounted) {
        _showSnackBar('已删除');
        // 通知父组件刷新帖子状态
        _refreshPostInProvider();
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  /// 恢复已删除的帖子
  Future<void> _recoverPost() async {
    if (_isDeleting) return;

    HapticFeedback.lightImpact();
    setState(() => _isDeleting = true);

    try {
      await _service.recoverPost(widget.post.id);
      if (mounted) {
        _showSnackBar('已恢复');
        // 通知父组件刷新帖子状态
        _refreshPostInProvider();
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  /// 刷新帖子状态到 Provider
  void _refreshPostInProvider() {
    widget.onRefreshPost?.call(widget.post.id);
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
                // 标记解决方案（当可以接受或取消接受时显示）
                if (widget.post.canAcceptAnswer || widget.post.canUnacceptAnswer)
                  ListTile(
                    leading: Icon(
                      _isAcceptedAnswer ? Icons.check_box : Icons.check_box_outline_blank,
                      color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.onSurface,
                    ),
                    title: Text(
                      _isAcceptedAnswer ? '取消采纳' : '采纳为解决方案',
                      style: TextStyle(
                        color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.onSurface,
                      ),
                    ),
                    onTap: _isTogglingAnswer ? null : () {
                      Navigator.pop(ctx);
                      _toggleSolution();
                    },
                  ),
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
                // 恢复（仅当帖子已删除且有恢复权限时显示）
                if (widget.post.canRecover)
                  ListTile(
                    leading: Icon(Icons.restore, color: theme.colorScheme.primary),
                    title: Text('恢复', style: TextStyle(color: theme.colorScheme.primary)),
                    onTap: _isDeleting ? null : () {
                      Navigator.pop(ctx);
                      _recoverPost();
                    },
                  ),
                // 删除（仅当有删除权限且帖子未删除时显示）
                if (widget.post.canDelete && !widget.post.isDeleted)
                  ListTile(
                    leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                    title: Text('删除', style: TextStyle(color: theme.colorScheme.error)),
                    onTap: _isDeleting ? null : () {
                      Navigator.pop(ctx);
                      _showDeleteConfirmDialog(context, theme);
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

  Widget _buildCompactBadge(BuildContext context, String text, Color backgroundColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          height: 1.1,
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
        : post.isDeleted
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.15)
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
        child: Opacity(
          opacity: post.isDeleted ? 0.6 : 1.0,
          child: Container(
          constraints: const BoxConstraints(minHeight: 80),
          decoration: BoxDecoration(
            color: targetColor,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // 背景水印印章
              if (_isAcceptedAnswer || widget.post.canAcceptAnswer)
                Positioned(
                  right: 20,
                  top: 10,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: _isAcceptedAnswer ? 0.12 : 0.05,
                      child: Transform.rotate(
                        angle: -0.15,
                        child: CustomPaint(
                          painter: _StampPainter(
                            color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.outline,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isAcceptedAnswer ? Icons.verified : Icons.help_outline,
                                  color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.outline,
                                  size: 28,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _isAcceptedAnswer ? '已解决' : '待解决',
                                  style: TextStyle(
                                    color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.outline,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2,
                                    fontFamily: theme.textTheme.titleLarge?.fontFamily,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
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
                        if (widget.isTopicOwner && post.postNumber > 1) ...[
                          const SizedBox(width: 4),
                          _buildCompactBadge(context, '主', theme.colorScheme.primaryContainer, theme.colorScheme.onPrimaryContainer),
                        ],
                        if (isOwnPost) ...[
                          const SizedBox(width: 4),
                          _buildCompactBadge(context, '我', theme.colorScheme.tertiaryContainer, theme.colorScheme.onTertiaryContainer),
                        ],
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
                    ValueListenableBuilder<bool>(
                      valueListenable: _isLoadingReplyHistoryNotifier,
                      builder: (context, isLoading, _) {
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: isLoading ? null : _toggleReplyHistory,
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
                                if (isLoading)
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
                        );
                      },
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
          ValueListenableBuilder<bool>(
            valueListenable: _showReplyHistoryNotifier,
            builder: (context, showReplyHistory, _) {
              if (!showReplyHistory) return const SizedBox.shrink();
              return _buildReplyHistoryPreview(theme);
            },
          ),
          
          const SizedBox(height: 12),

                    // Content (HTML)
                    ChunkedHtmlContent(
                      html: post.cooked,
                      textStyle: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.5,
                        fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) *
                            ref.watch(preferencesProvider).contentFontScale,
                      ),
                      linkCounts: post.linkCounts,
                      mentionedUsers: post.mentionedUsers,
                      post: post,
                      topicId: widget.topicId,
                      onInternalLinkTap: (topicId, topicSlug, postNumber) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TopicDetailPage(
                              topicId: topicId,
                              initialTitle: topicSlug,
                              scrollToPostNumber: postNumber,
                            ),
                          ),
                        );
                      },
                    ),

                    // 相关链接（其他帖子引用了此帖子的入站链接）
                    PostLinks(linkCounts: post.linkCounts),

                    // 主贴显示解决方案跳转提示
                    if (post.postNumber == 1 && widget.topicHasAcceptedAnswer && widget.acceptedAnswerPostNumber != null)
                      _buildSolutionBanner(theme),

                    const SizedBox(height: 12),

                    // Actions
                    Row(
                      children: [
                        // 回复数按钮
                        if (widget.post.replyCount > 0)
                          ValueListenableBuilder<bool>(
                            valueListenable: _isLoadingRepliesNotifier,
                            builder: (context, isLoadingReplies, _) {
                              return ValueListenableBuilder<bool>(
                                valueListenable: _showRepliesNotifier,
                                builder: (context, showReplies, _) {
                                  return GestureDetector(
                                    onTap: isLoadingReplies ? null : _toggleReplies,
                                    child: Container(
                                      height: 36,
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: showReplies
                                            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                                            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: showReplies
                                              ? theme.colorScheme.primary.withValues(alpha: 0.2)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isLoadingReplies && _replies.isEmpty)
                                            const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          else ...[
                                            Icon(
                                              Icons.chat_bubble_outline_rounded,
                                              size: 15,
                                              color: showReplies
                                                  ? theme.colorScheme.primary
                                                  : theme.colorScheme.onSurfaceVariant,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '${widget.post.replyCount}',
                                              style: theme.textTheme.labelMedium?.copyWith(
                                                color: showReplies
                                                    ? theme.colorScheme.primary
                                                    : theme.colorScheme.onSurfaceVariant,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              showReplies ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                              size: 18,
                                              color: showReplies
                                                  ? theme.colorScheme.primary
                                                  : theme.colorScheme.onSurfaceVariant,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
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
                    ValueListenableBuilder<bool>(
                      valueListenable: _showRepliesNotifier,
                      builder: (context, showReplies, _) {
                        if (!showReplies) return const SizedBox.shrink();
                        return _buildRepliesList(theme);
                      },
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
  }

  /// 构建解决方案跳转横幅（仅在主贴显示）
  Widget _buildSolutionBanner(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [
              Colors.green.withValues(alpha: 0.12),
              Colors.green.withValues(alpha: 0.04),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: Colors.green.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: () {
              if (widget.acceptedAnswerPostNumber != null) {
                widget.onJumpToPost?.call(widget.acceptedAnswerPostNumber!);
              }
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  // 左侧图标区域
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.brightness == Brightness.dark 
                          ? Colors.black.withValues(alpha: 0.2) 
                          : Colors.white.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.green.withValues(alpha: 0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.verified, // 统一使用 verified 图标
                      color: Colors.green,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  
                  // 中间文字区域
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '此话题已解决', // 文案微调，更专业
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.green.shade800,
                            fontWeight: FontWeight.w800, // 加粗
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '查看最佳答案',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.green.shade700,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '#${widget.acceptedAnswerPostNumber}',
                                style: TextStyle(
                                  color: Colors.green.shade800,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace', // 等宽字体显示楼层号更像代码/引用
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  // 右侧箭头
                  Icon(
                    Icons.arrow_forward_rounded, // 圆润箭头
                    size: 20,
                    color: Colors.green.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
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
                    _showReplyHistoryNotifier.value = false;
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
          ValueListenableBuilder<bool>(
            valueListenable: _isLoadingRepliesNotifier,
            builder: (context, isLoadingReplies, _) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_canLoadMoreReplies)
                    TextButton.icon(
                      onPressed: isLoadingReplies ? null : _loadReplies,
                      icon: isLoadingReplies
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
                      _showRepliesNotifier.value = false;
                    },
                    icon: Icon(Icons.expand_less, size: 16, color: theme.colorScheme.onSurfaceVariant),
                    label: Text('收起回复', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              );
            },
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

    try {
      await widget.service.flagPost(
        widget.postId,
        _selectedType!.id,
        message: _messageController.text.isNotEmpty ? _messageController.text : null,
      );

      if (mounted) {
        Navigator.pop(context);
        widget.onSuccess?.call();
      }
    } catch (e) {
      if (mounted) {
        final message = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '举报失败，请稍后重试';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
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
  @override
  Widget build(BuildContext context) {
    final avatarUrl = widget.post.getAvatarUrl();

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
        avatar: SmartAvatar(
          imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
          radius: 20,
          fallbackText: widget.post.username,
          border: Border.all(
            color: widget.theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
    );
  }
}

/// 模拟印章残缺边框的绘制器
class _StampPainter extends CustomPainter {
  final Color color;
  _StampPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final path = Path();
    const double radius = 8;
    
    // 绘制残缺的矩形边框
    // 顶部边（部分）
    path.moveTo(size.width * 0.1, 0);
    path.lineTo(size.width - radius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, radius);
    
    // 右侧边（部分）
    path.lineTo(size.width, size.height * 0.7);
    
    // 底部边（从右向左，部分）
    path.moveTo(size.width * 0.8, size.height);
    path.lineTo(radius, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - radius);
    
    // 左侧边（部分）
    path.lineTo(0, size.height * 0.3);
    path.moveTo(0, size.height * 0.15);
    path.lineTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
