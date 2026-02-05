import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../models/user.dart';
import '../models/user_action.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/time_utils.dart';
import '../utils/number_utils.dart';
import '../utils/pagination_helper.dart';
import '../services/emoji_handler.dart';
import '../constants.dart';
import '../utils/share_utils.dart';
import '../providers/preferences_provider.dart';
import '../widgets/common/flair_badge.dart';
import '../widgets/common/animated_gradient_background.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/content/discourse_html_content/discourse_html_content_widget.dart';
import '../widgets/content/collapsed_html_content.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/user/user_profile_skeleton.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import 'follow_list_page.dart';
import 'image_viewer_page.dart';

/// 用户个人页
class UserProfilePage extends ConsumerStatefulWidget {
  final String username;

  const UserProfilePage({super.key, required this.username});

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  User? _user;
  UserSummary? _summary;
  bool _isLoading = true;
  String? _error;

  // 关注状态
  bool _isFollowed = false;
  bool _isFollowLoading = false;

  // 各 tab 的数据
  final Map<int, List<UserAction>> _actionsCache = {};
  final Map<int, bool> _hasMoreCache = {};
  final Map<int, bool> _loadingCache = {};

  // 回应列表单独缓存
  List<UserReaction>? _reactionsCache;
  bool _reactionsHasMore = true;
  bool _reactionsLoading = false;

  // tab 对应的 filter: null=全部, 4=话题, 5=回复, 1=点赞, -2=回应(特殊标记)
  static const List<int?> _tabFilters = [null, 4, 5, 1, -2];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
    // 预先为所有 tab 设置 loading 状态，避免切换时闪现空状态
    for (final filter in _tabFilters) {
      if (filter == -2) {
        _reactionsLoading = true;
      } else {
        _loadingCache[filter ?? -1] = true;
      }
    }
    _loadUser();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final filter = _tabFilters[_tabController.index];
      if (filter == -2) {
        // 回应列表
        if (_reactionsCache == null) {
          _loadReactions();
        }
      } else if (!_actionsCache.containsKey(filter)) {
        _loadActions(filter);
      }
    }
  }

  Future<void> _loadUser() async {
    try {
      final service = ref.read(discourseServiceProvider);
      // 并行加载用户基本信息和统计数据
      final results = await Future.wait([
        service.getUser(widget.username),
        service.getUserSummary(widget.username),
      ]);

      if (mounted) {
        final user = results[0] as User;
        setState(() {
          _user = user;
          _summary = results[1] as UserSummary;
          _isFollowed = user.isFollowed ?? false;
          _isLoading = false;
        });
        _loadActions(null); // 加载全部
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// 切换关注状态
  Future<void> _toggleFollow() async {
    if (_user == null || _isFollowLoading) return;

    setState(() => _isFollowLoading = true);

    try {
      final service = ref.read(discourseServiceProvider);
      if (_isFollowed) {
        await service.unfollowUser(_user!.username);
      } else {
        await service.followUser(_user!.username);
      }

      if (mounted) {
        setState(() {
          _isFollowed = !_isFollowed;
        });
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isFollowLoading = false);
      }
    }
  }

  /// 打开私信对话框
  void _openMessageDialog() {
    if (_user == null) return;

    showReplySheet(
      context: context,
      targetUsername: _user!.username,
    );
  }

  /// 打开用户内容搜索
  void _openUserSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(initialQuery: '@${widget.username}'),
      ),
    );
  }

  /// 分享用户
  void _shareUser() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/u/${widget.username}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
    SharePlus.instance.share(ShareParams(text: url));
  }

  /// 显示用户详细信息弹窗
  void _showUserInfo() {
    if (_user == null) return;

    final hasBio = _user!.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user!.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user!.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user!.createdAt != null;

    if (!hasBio && !hasLocation && !hasWebsite && !hasJoinedAt) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          final theme = Theme.of(context);
          return Container(
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha:0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                // 拖动指示器
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                
                // 标题栏
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: Row(
                    children: [
                      Text(
                        '关于',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      // 如果需要可以添加右上角操作按钮
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                
                // 内容
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                    children: [
                      // 个人简介
                      if (hasBio) ...[
                        Text(
                          '个人简介',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DiscourseHtmlContent(
                          html: _user!.bio!,
                          textStyle: theme.textTheme.bodyLarge?.copyWith(
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],

                      // 其他信息列表
                      if (hasLocation || hasWebsite || hasJoinedAt) ...[
                        Text(
                          '更多信息',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        if (hasLocation)
                          _buildInfoRow(
                            context,
                            Icons.location_on_outlined,
                            '位置',
                            _user!.location!,
                          ),
                        
                        if (hasWebsite)
                          _buildInfoRow(
                            context,
                            Icons.link_rounded,
                            '网站',
                            _user!.websiteName ?? _user!.website!,
                            url: _user!.website,
                            isLink: true,
                          ),
                        
                        if (hasJoinedAt)
                          _buildInfoRow(
                            context,
                            Icons.calendar_today_rounded,
                            '加入时间',
                            TimeUtils.formatFullDate(_user!.createdAt),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, IconData icon, String label, String value, {String? url, bool isLink = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: isLink && url != null ? () => launchUrl(Uri.parse(url)) : null,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isLink ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      decoration: isLink ? TextDecoration.underline : null,
                      decorationColor: theme.colorScheme.primary.withValues(alpha:0.3),
                    ),
                  ),
                ],
              ),
            ),
            if (isLink)
              Icon(
                Icons.open_in_new_rounded,
                size: 16,
                color: theme.colorScheme.outline.withValues(alpha:0.5),
              ),
          ],
        ),
      ),
    );
  }

  /// 用户动作分页助手
  static final _actionsPaginationHelper = PaginationHelpers.forList<UserAction>(
    keyExtractor: (a) => '${a.topicId}_${a.postNumber}_${a.actionType}',
    expectedPageSize: 30,
  );

  /// 用户回应分页助手（游标分页）
  static final _reactionsPaginationHelper = PaginationHelpers.forList<UserReaction>(
    keyExtractor: (r) => r.id,
    expectedPageSize: 20,
  );

  Future<void> _loadActions(int? filter, {bool loadMore = false}) async {
    final key = filter ?? -1;
    // 如果已有数据且正在加载，跳过（防止重复加载更多）
    if (_loadingCache[key] == true && _actionsCache.containsKey(key)) return;

    setState(() => _loadingCache[key] = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final offset = loadMore ? (_actionsCache[key]?.length ?? 0) : 0;
      final response = await service.getUserActions(
        widget.username,
        filter: filter,
        offset: offset,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserAction>(items: _actionsCache[key] ?? []);
            final result = _actionsPaginationHelper.processLoadMore(
              currentState,
              PaginationResult(items: response.actions, expectedPageSize: 30),
            );
            _actionsCache[key] = result.items;
            _hasMoreCache[key] = result.hasMore;
          } else {
            final result = _actionsPaginationHelper.processRefresh(
              PaginationResult(items: response.actions, expectedPageSize: 30),
            );
            _actionsCache[key] = result.items;
            _hasMoreCache[key] = result.hasMore;
          }
          _loadingCache[key] = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingCache[key] = false);
      }
    }
  }

  Future<void> _loadReactions({bool loadMore = false}) async {
    if (_reactionsLoading && _reactionsCache != null) return;

    setState(() => _reactionsLoading = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final beforeId = loadMore && _reactionsCache != null && _reactionsCache!.isNotEmpty
          ? _reactionsCache!.last.id
          : null;
      final response = await service.getUserReactions(widget.username, beforeReactionUserId: beforeId);

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserReaction>(items: _reactionsCache ?? []);
            final result = _reactionsPaginationHelper.processLoadMore(
              currentState,
              PaginationResult(items: response.reactions, expectedPageSize: 20),
            );
            _reactionsCache = result.items;
            _reactionsHasMore = result.hasMore;
          } else {
            final result = _reactionsPaginationHelper.processRefresh(
              PaginationResult(items: response.reactions, expectedPageSize: 20),
            );
            _reactionsCache = result.items;
            _reactionsHasMore = result.hasMore;
          }
          _reactionsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _reactionsLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_isLoading) {
      return const UserProfileSkeleton();
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.username)),
        body: Center(child: Text('加载失败: $_error')),
      );
    }

    // 计算 pinned header 高度
    final double pinnedHeaderHeight = kToolbarHeight + MediaQuery.of(context).padding.top + 48; // 48 是 TabBar 高度

    return Scaffold(
      body: ExtendedNestedScrollView(
        pinnedHeaderSliverHeightBuilder: () => pinnedHeaderHeight,
        onlyOneScrollInBody: true,
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          _buildSliverAppBar(context, theme, currentUser),
        ],
        body: TabBarView(
          controller: _tabController,
          children: _tabFilters.asMap().entries.map((entry) {
            final index = entry.key;
            final filter = entry.value;
            return ExtendedVisibilityDetector(
              uniqueKey: Key('tab_$index'),
              child: _buildActionList(filter),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildSliverAppBar(BuildContext context, ThemeData theme, User? currentUser) {
    final bgUrl = _user?.backgroundUrl;
    final hasBackground = bgUrl != null && bgUrl.isNotEmpty;
    // Standard toolbar height is usually 56.0 + status bar height
    final double pinnedHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    final double expandedHeight = 410.0;

    // Check if there is any info to show (for the "About" popup)
    final hasBio = _user?.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user?.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user?.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user?.createdAt != null;
    final hasInfo = hasBio || hasLocation || hasWebsite || hasJoinedAt;

    // 检查是否是自己
    final isOwnProfile = currentUser != null && _user != null && currentUser.username == _user!.username;

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      stretch: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent, // Transparent to show FlexibleSpaceBar background
      surfaceTintColor: Colors.transparent, // Prevent M3 tint
      iconTheme: const IconThemeData(color: Colors.white),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => _openUserSearch(),
        ),
        if (_user != null && _user!.canSendPrivateMessageToUser != false)
          IconButton(
            onPressed: _openMessageDialog,
            icon: const Icon(Icons.mail_outline_rounded),
            tooltip: '私信',
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'share') {
              _shareUser();
            }
          },
          itemBuilder: (context) {
            final theme = Theme.of(context);
            return [
              PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.share_outlined, size: 20, color: theme.colorScheme.onSurface),
                    const SizedBox(width: 12),
                    const Text('分享用户'),
                  ],
                ),
              ),
            ];
          },
        ),
      ],
      // Bottom 参数承载 TabBar，并应用圆角背景，这样它会“浮”在 FlexibleSpace 背景图之上
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: TabBar(
            controller: _tabController,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent, // 移除 TabBar 底部分割线
            tabs: const [
              Tab(text: '全部'),
              Tab(text: '话题'),
              Tab(text: '回复'),
              Tab(text: '赞'),
              Tab(text: '回应'),
            ],
          ),
        ),
      ),
      // Use a Stack to ensure a solid black background exists BEHIND the FlexibleSpaceBar
      flexibleSpace: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final currentHeight = constraints.biggest.height;
          final t = ((currentHeight - pinnedHeight) / (expandedHeight - pinnedHeight)).clamp(0.0, 1.0);
          
          // 标题透明度：收起时显示（当 t < 0.3 时完全显示，避免半透明）
          final titleOpacity = t < 0.3 ? 1.0 : (1.0 - ((t - 0.3) / 0.7)).clamp(0.0, 1.0);
          // 内容透明度：展开时显示
          final contentOpacity = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
          
          return Stack(
            fit: StackFit.expand,
            children: [
              // ===== 层 0: 背景 - 渐变动画打底 + 图片叠加 =====
              const AnimatedGradientBackground(),
              if (hasBackground)
                Image(
                  image: discourseImageProvider(
                    bgUrl.startsWith('http') ? bgUrl : '${AppConstants.baseUrl}$bgUrl',
                  ),
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded || frame != null) {
                      return AnimatedOpacity(
                        opacity: frame != null ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: child,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),

              // ===== 层 1: 统一压暗遮罩 - 随向上滑动变得更暗 =====
              Container(
                color: Color.lerp(
                  Colors.black.withValues(alpha:0.6), // 展开状态：默认更暗 (0.6)
                  Colors.black.withValues(alpha:0.85), // 收起状态：稍微透一点 (0.85)
                  Curves.easeOut.transform(1.0 - t), // 使用 easeOut 曲线优化滑动体验
                ),
              ),

              // ===== 层 2: 用户信息内容 - 展开时显示，收起时淡出 =====
              Positioned(
                left: 20,
                right: 20,
                bottom: 48 + 24, // TabBar 高度 + 间距
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像、姓名、操作按钮一行
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 1. 头像 radius=36，flair 大小 30，偏移 right=-7, bottom=-4
                          GestureDetector(
                            onTap: () {
                              if (_user?.getAvatarUrl() != null) {
                                final avatarUrl = _user!.getAvatarUrl(size: 360);
                                ImageViewerPage.open(
                                  context,
                                  avatarUrl,
                                  heroTag: 'user_avatar_${_user!.username}',
                                );
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              child: AvatarWithFlair(
                                flairSize: 30,
                                flairRight: -7,
                                flairBottom: -4,
                                flairUrl: _user?.flairUrl,
                                flairName: _user?.flairName,
                                flairBgColor: _user?.flairBgColor,
                                flairColor: _user?.flairColor,
                                avatar: Hero(
                                  tag: 'user_avatar_${_user?.username ?? ''}',
                                  child: SmartAvatar(
                                    imageUrl: _user?.getAvatarUrl() != null
                                        ? _user!.getAvatarUrl(size: 144)
                                        : null,
                                    radius: 36,
                                    fallbackText: _user?.username,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          
                          // 2. 姓名、身份信息
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Row 1: Name + Status
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        (_user?.name?.isNotEmpty == true) ? _user!.name! : (_user?.username ?? ''),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          shadows: [Shadow(color: Colors.black45, offset: Offset(0, 1), blurRadius: 2)],
                                        ),
                                      ),
                                    ),
                                    if (_user?.status != null) ...[
                                      const SizedBox(width: 8),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: _buildStatusEmoji(_user!.status!),
                                      ),
                                    ],
                                  ],
                                ),
                                
                                // Row 2: Username
                                if (_user?.username != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                                    child: Text(
                                       '@${_user?.username}',
                                       style: TextStyle(color: Colors.white.withValues(alpha:0.85), fontSize: 13),
                                    ),
                                  )
                                else
                                  const SizedBox(height: 6), // 占位

                                // Row 3: Level Badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha:0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _getTrustLevelLabel(_user?.trustLevel ?? 0),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // 3. 操作按钮 (关注)
                          if (_user != null && !isOwnProfile) ...[
                            const SizedBox(width: 12),
                            _buildFollowButton(isOwnProfile),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Status / Signature (始终显示，保持布局一致)
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: hasInfo ? _showUserInfo : null,
                        child: Container(
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha:0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: hasBio
                                    ? CollapsedHtmlContent(
                                        html: _user!.bio!,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textStyle: TextStyle(
                                          color: Colors.white.withValues(alpha:0.9),
                                          fontSize: 14,
                                          height: 1.3,
                                        ),
                                      )
                                    : Text(
                                        '这个人很懒，什么都没写',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha:0.5),
                                          fontSize: 14,
                                          height: 1.3,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                              ),
                              if (hasInfo) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: Colors.white.withValues(alpha:0.6),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // Stats
                      const SizedBox(height: 16),
                      if (_summary != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 第一行：关注、粉丝
                            if (_user?.totalFollowing != null || _user?.totalFollowers != null)
                              Wrap(
                                spacing: 16,
                                children: [
                                  if (_user?.totalFollowing != null)
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => FollowListPage(
                                            username: widget.username,
                                            isFollowing: true,
                                          ),
                                        ),
                                      ),
                                      child: _buildStatSlot(NumberUtils.formatCount(_user!.totalFollowing!), '关注', _user!.totalFollowing!),
                                    ),
                                  if (_user?.totalFollowers != null)
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => FollowListPage(
                                            username: widget.username,
                                            isFollowing: false,
                                          ),
                                        ),
                                      ),
                                      child: _buildStatSlot(NumberUtils.formatCount(_user!.totalFollowers!), '粉丝', _user!.totalFollowers!),
                                    ),
                                ],
                              ),
                            // 第二行：获赞、访问、话题、回复
                            if (_user?.totalFollowing != null || _user?.totalFollowers != null)
                              const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              children: [
                                _buildStatSlot(NumberUtils.formatCount(_summary!.likesReceived), '获赞', _summary!.likesReceived),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.daysVisited), '访问', _summary!.daysVisited),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.topicCount), '话题', _summary!.topicCount),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.postCount), '回复', _summary!.postCount),
                              ],
                            ),
                          ],
                        ),
                      
                      // 最近活动时间
                      if (_user?.lastPostedAt != null || _user?.lastSeenAt != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha:0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.flash_on_rounded, size: 12, color: Colors.white70),
                              const SizedBox(width: 4),
                              Text(
                                TimeUtils.formatRelativeTime(_user?.lastSeenAt ?? _user!.lastPostedAt!),
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ===== 层 3: 收起时的标题栏内容 - 收起时显示 =====
              Positioned(
                left: 60, // 增加间距，避免靠近返回按钮
                right: 48,
                bottom: 14 + 48, // 调整位置适应 TabBar (48是TabBar高度)
                child: Opacity(
                  opacity: titleOpacity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像 radius=16，flair 大小 14，偏移 right=-3, bottom=-1
                      AvatarWithFlair(
                        flairSize: 14,
                        flairRight: -3,
                        flairBottom: -1,
                        flairUrl: _user?.flairUrl,
                        flairName: _user?.flairName,
                        flairBgColor: _user?.flairBgColor,
                        flairColor: _user?.flairColor,
                        avatar: SmartAvatar(
                          imageUrl: _user?.getAvatarUrl() != null
                              ? _user!.getAvatarUrl(size: 64)
                              : null,
                          radius: 16,
                          fallbackText: _user?.username,
                          border: Border.all(color: Colors.white70, width: 1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          (_user?.name?.isNotEmpty == true) ? _user!.name! : (_user?.username ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 移除之前的所有伪装层
            ],
          );
        }
      ),
    );
  }

  Widget _buildStatSlot(String value, String label, int rawValue) {
    return Tooltip(
      message: '$rawValue',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha:0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowButton(bool isOwnProfile) {
    if (_user == null || _user!.canFollow != true || isOwnProfile) {
      return const SizedBox.shrink();
    }

    return _isFollowLoading
        ? Container(
            width: 32,
            height: 32,
            padding: const EdgeInsets.all(8),
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : TextButton.icon(
            onPressed: _toggleFollow,
            icon: Icon(
              _isFollowed ? Icons.check_rounded : Icons.add_rounded,
              size: 16,
            ),
            label: Text(_isFollowed ? '已关注' : '关注'),
            style: TextButton.styleFrom(
              backgroundColor: _isFollowed ? Colors.white.withValues(alpha:0.15) : Colors.white,
              foregroundColor: _isFollowed ? Colors.white : Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: _isFollowed ? const BorderSide(color: Colors.white38) : BorderSide.none,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          );
  }

  Widget _buildStatusEmoji(UserStatus status) {
    final emoji = status.emoji;
    if (emoji == null || emoji.isEmpty) return const SizedBox.shrink();

    final isEmojiName = emoji.contains(RegExp(r'[a-zA-Z0-9_]')) && !emoji.contains(RegExp(r'[^\x00-\x7F]'));

    if (isEmojiName) {
      final cleanName = emoji.replaceAll(':', '');
      final emojiUrl = _getEmojiUrl(cleanName);

      return Image(
        image: discourseImageProvider(emojiUrl),
        width: 18,
        height: 18,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }

    return Text(
      emoji,
      style: const TextStyle(fontSize: 16),
    );
  }

  Widget _buildActionList(int? filter) {
    // 回应列表使用单独的逻辑
    if (filter == -2) {
      return _buildReactionList();
    }

    final key = filter ?? -1;
    final actions = _actionsCache[key];
    final isLoading = _loadingCache[key] == true;
    final hasMore = _hasMoreCache[key] ?? true;

    // 优先检查 loading 状态
    if (isLoading && actions == null) {
      return const UserActionListSkeleton();
    }

    // 空状态
    if (actions == null || actions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text('暂无内容', style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200 &&
            hasMore &&
            !isLoading) {
          _loadActions(filter, loadMore: true);
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => _loadActions(filter),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: actions.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == actions.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _buildActionItem(actions[index]);
          },
        ),
      ),
    );
  }

  Widget _buildReactionList() {
    final reactions = _reactionsCache;
    final isLoading = _reactionsLoading;
    final hasMore = _reactionsHasMore;

    // 优先检查 loading 状态
    if (isLoading && reactions == null) {
      return const UserActionListSkeleton();
    }

    // 空状态
    if (reactions == null || reactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.emoji_emotions_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text('暂无回应', style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200 &&
            hasMore &&
            !isLoading) {
          _loadReactions(loadMore: true);
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => _loadReactions(),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: reactions.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == reactions.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _buildReactionItem(reactions[index]);
          },
        ),
      ),
    );
  }

  Widget _buildActionItem(UserAction action) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: action.topicId,
              scrollToPostNumber: action.postNumber,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：动作类型和时间
              Row(
                children: [
                  Icon(
                    _getActionIcon(action.actionType),
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getActionLabel(action.actionType),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (action.actingAt != null)
                    Text(
                      TimeUtils.formatRelativeTime(action.actingAt!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              
              // 标题
              Text(
                action.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              
              // 摘要
              if (action.excerpt != null && action.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  action.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 获取 emoji 图片 URL
  String _getEmojiUrl(String emojiName) {
    final url = EmojiHandler().getEmojiUrl(emojiName);
    if (url != null) return url;
    return '${AppConstants.baseUrl}/images/emoji/twitter/$emojiName.png?v=12';
  }

  Widget _buildReactionItem(UserReaction reaction) {
    final theme = Theme.of(context);
    final emojiUrl = reaction.reactionValue != null
        ? _getEmojiUrl(reaction.reactionValue!)
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: reaction.topicId,
              scrollToPostNumber: reaction.postNumber,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：回应 emoji 和时间
              Row(
                children: [
                  if (emojiUrl != null)
                    Image(
                      image: discourseImageProvider(emojiUrl),
                      width: 20,
                      height: 20,
                      errorBuilder: (_, _, _) => const Icon(Icons.emoji_emotions, size: 20),
                    )
                  else
                    const Icon(Icons.emoji_emotions, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '回应了',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (reaction.createdAt != null)
                    Text(
                      TimeUtils.formatRelativeTime(reaction.createdAt!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 话题标题
              if (reaction.topicTitle != null && reaction.topicTitle!.isNotEmpty)
                Text(
                  reaction.topicTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),

              // 帖子内容摘要
              if (reaction.excerpt != null && reaction.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reaction.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _getActionIcon(int? type) {
    switch (type) {
      case UserActionType.like:
        return Icons.favorite_rounded;
      case UserActionType.wasLiked:
        return Icons.favorite_border_rounded;
      case UserActionType.newTopic:
        return Icons.article_rounded;
      case UserActionType.reply:
        return Icons.chat_bubble_rounded;
      default:
        return Icons.history_rounded;
    }
  }

  String _getTrustLevelLabel(int level) {
    switch (level) {
      case 0:
        return 'L0 新用户';
      case 1:
        return 'L1 基本用户';
      case 2:
        return 'L2 成员';
      case 3:
        return 'L3 活跃用户';
      case 4:
        return 'L4 领袖';
      default:
        return '等级 $level';
    }
  }

  String _getActionLabel(int? type) {
    switch (type) {
      case UserActionType.like:
        return '点赞';
      case UserActionType.wasLiked:
        return '被赞';
      case UserActionType.newTopic:
        return '发布了话题';
      case UserActionType.reply:
        return '回复了';
      default:
        return '动态';
    }
  }
}