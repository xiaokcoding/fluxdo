import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import 'webview_login_page.dart';
import 'appearance_page.dart';
import 'browsing_history_page.dart';
import 'bookmarks_page.dart';
import 'my_topics_page.dart';
import 'my_badges_page.dart';
import 'user_profile_page.dart';
import 'trust_level_requirements_page.dart';
import 'about_page.dart';
import 'network_settings_page.dart';
import '../widgets/common/loading_spinner.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/common/flair_badge.dart';
import '../providers/app_state_refresher.dart';
import 'metaverse_page.dart';
import '../widgets/ldc_balance_card.dart';
import '../providers/ldc_providers.dart';
import '../utils/number_utils.dart';

/// 个人页面
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  // 缓存头像 widget，避免重复创建导致闪烁
  Widget? _cachedAvatarWidget;
  int? _cachedUserId;

  @override
  void initState() {
    super.initState();
    // 进入页面后静默刷新用户数据（不触发 loading 状态）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final current = ref.read(currentUserProvider).value;
        if (current != null) {
          // 使用 refresh 在后台更新数据，不会触发 loading 状态，避免 UI 闪烁
          // 忽略返回值，因为我们只是触发后台刷新
          ref.refresh(currentUserProvider.future).ignore();
          ref.refresh(userSummaryProvider.future).ignore();
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 在这里初始化头像 widget，此时可以安全地访问 Theme.of(context)
    final user = ref.read(currentUserProvider).value;
    if (_cachedAvatarWidget == null || _cachedUserId != user?.id) {
      _initAvatarWidget(user);
    }
  }

  void _initAvatarWidget(User? user) {
    _cachedAvatarWidget = _ProfileAvatar(
      key: ValueKey('profile-avatar-${user?.id}'),
      user: user,
    );
    _cachedUserId = user?.id;
  }

  Future<void> _goToLogin() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebViewLoginPage()),
    );
    if (result == true && mounted) {
      AppStateRefresher.refreshAll(ref);
    }
  }
  
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认退出'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await ref.read(discourseServiceProvider).logout(callApi: true);
      if (mounted) {
        await AppStateRefresher.resetForLogout(ref);
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final userAsync = ref.watch(currentUserProvider);
    final summaryAsync = ref.watch(userSummaryProvider);

    final user = userAsync.value;
    final summary = summaryAsync.value;
    
    final isLoadingInitial = userAsync.isLoading && !userAsync.hasValue;
    final hasError = userAsync.hasError && !userAsync.hasValue;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        centerTitle: true,
        actions: user != null ? const [Padding(
          padding: EdgeInsets.only(right: 8.0),
          child: NotificationIconButton(),
        )] : null,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final current = ref.read(currentUserProvider).value;
          if (current == null) return;
          ref.invalidate(currentUserProvider);
          ref.invalidate(userSummaryProvider);
          final service = ref.read(discourseServiceProvider);
          final user = await ref.read(currentUserProvider.future);
          if (user != null) {
            await service.getUserSummary(user.username, forceRefresh: true);
          }
        },
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            _buildUserHeader(theme, user, isLoadingInitial, userAsync.error.toString()),
            const SizedBox(height: 24),
            
            if (isLoadingInitial)
              const Center(child: Padding(
                padding: EdgeInsets.all(64),
                child: LoadingSpinner(),
              ))
            else if (hasError)
              _buildError(theme, userAsync.error.toString())
            else if (user != null && summary != null) ...[
              _buildStatsRow(theme, summary),
              const SizedBox(height: 24),
            ],

            Consumer(
              builder: (context, ref, _) {
                final ldcUserInfo = ref.watch(ldcUserInfoProvider).value;
                if (ldcUserInfo == null) return const SizedBox.shrink();
                return Column(
                  children: const [
                    LdcBalanceCard(compact: true),
                    SizedBox(height: 24),
                  ],
                );
              },
            ),

            if (user != null) ...[
              _buildOptionsCard(theme),
              const SizedBox(height: 20),
            ],
            _buildAboutCard(theme),
            const SizedBox(height: 32),
            _buildAuthButton(theme, user != null),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
  
  Widget _buildUserHeader(ThemeData theme, User? user, bool isLoading, String? error) {
    return GestureDetector(
      onTap: user != null ? () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => UserProfilePage(username: user.username)),
        );
      } : null,
      child: Container(
        color: Colors.transparent,
        child: Row(
          children: [
            // 使用缓存的头像 widget
            _cachedAvatarWidget ?? const SizedBox(width: 72, height: 72),
            const SizedBox(width: 20),
            // 用户信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.name ?? user?.username ?? (user == null ? '未登录' : '加载中...'),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (user != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '@${user.username}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 等级标签和状态
                    Wrap(
                      spacing: 8,
                      runSpacing: 4, 
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                         // 回归标准 Chip 风格，保持质感但不过分
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _getTrustLevelLabel(user.trustLevel),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // 状态外显
                        if (user.status != null)
                          _buildStatusChip(user.status!, theme),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 4),
                    Text(
                      '登录后体验更多功能',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
             if (user != null)
              CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: Icon(Icons.arrow_forward_ios_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  String _getTrustLevelLabel(int level) {
    switch (level) {
      case 0: return 'L0 新 user';
      case 1: return 'L1 基本用户';
      case 2: return 'L2 成员';
      case 3: return 'L3 活跃用户';
      case 4: return 'L4 领袖';
      default: return 'L$level';
    }
  }

  Widget _buildStatusEmoji(UserStatus status) {
    final emoji = status.emoji;
    if (emoji == null || emoji.isEmpty) return const SizedBox.shrink();

    final isEmojiName = emoji.contains(RegExp(r'[a-zA-Z0-9_]')) && !emoji.contains(RegExp(r'[^\x00-\x7F]'));

    if (isEmojiName) {
      final cleanName = emoji.replaceAll(':', '');
      final emojiUrl = 'https://linux.do/images/emoji/twitter/$cleanName.png?v=12';
      
      return Image(
        image: discourseImageProvider(emojiUrl),
        width: 14,
        height: 14,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }

    return Text(
      emoji,
      style: const TextStyle(fontSize: 12, height: 1.2),
    );
  }

  Widget _buildStatusChip(UserStatus status, ThemeData theme) {
    final emoji = status.emoji;
    final description = status.description;

    if ((emoji == null || emoji.isEmpty) && (description == null || description.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (emoji != null && emoji.isNotEmpty) ...[
            _buildStatusEmoji(status),
            if (description != null && description.isNotEmpty)
              const SizedBox(width: 4),
          ],
          if (description != null && description.isNotEmpty)
            Flexible(
              child: Text(
                description,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
  
  Widget _buildError(ThemeData theme, String error) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.errorContainer.withOpacity(0.3),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.error.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text('加载失败: $error', style: theme.textTheme.bodySmall)),
            TextButton(
              onPressed: () => ref.invalidate(currentUserProvider), 
              child: const Text('重试')
            ),
          ],
        ),
      ),
    );
  }
  
  /// 社区表现 - 使用 Card 保持一致性
  Widget _buildStatsRow(ThemeData theme, UserSummary summary) {
    return Card(
      elevation: 0,
       // 使用 surfaceContainerLow 与其他列表卡片区分或一致，这里选择稍微突出一点
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.2)),
      ),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.daysVisited), '访问天数', summary.daysVisited),
            _buildVerticalDivider(theme),
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.postsReadCount), '阅读帖子', summary.postsReadCount),
            _buildVerticalDivider(theme),
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.likesReceived), '获得点赞', summary.likesReceived),
            _buildVerticalDivider(theme),
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.postCount), '发表回复', summary.postCount),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalDivider(ThemeData theme) {
    return Container(
      height: 20,
      width: 1,
      color: theme.colorScheme.outlineVariant.withOpacity(0.5),
    );
  }

  Widget _buildCompactStatItem(ThemeData theme, String value, String label, int rawValue) {
    return Tooltip(
      message: '$rawValue',
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            )
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            )
          ),
        ],
      ),
    );
  }
  
  Widget _buildOptionsCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.2)),
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildOptionTile(
            icon: Icons.bookmark_rounded, 
            iconColor: Colors.orange,
            title: '我的书签', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BookmarksPage()))
          ),
          _buildOptionTile(
            icon: Icons.article_rounded, 
            iconColor: Colors.blue,
            title: '我的话题', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyTopicsPage()))
          ),
          _buildOptionTile(
            icon: Icons.military_tech_rounded, 
            iconColor: Colors.amber[700]!,
            title: '我的徽章', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBadgesPage()))
          ),
          _buildOptionTile(
            icon: Icons.verified_user_rounded, 
            iconColor: Colors.green,
            title: '信任要求', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrustLevelRequirementsPage()))
          ),
          _buildOptionTile(
            icon: Icons.history_rounded,
            iconColor: Colors.purple,
            title: '浏览历史',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowsingHistoryPage()))
          ),
          _buildOptionTile(
            icon: Icons.explore_rounded,
            iconColor: Colors.deepOrange,
            title: '元宇宙',
            showDivider: false,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MetaversePage()))
          ),
        ],
      ),
    );
  }
  
  Widget _buildAboutCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.2)),
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildOptionTile(
            icon: Icons.color_lens_rounded, 
            iconColor: Colors.teal,
            title: '外观设置', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearancePage()))
          ),
          _buildOptionTile(
            icon: Icons.network_check_rounded,
            iconColor: Colors.blueGrey,
            title: '网络设置',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NetworkSettingsPage())),
          ),
          _buildOptionTile(
            icon: Icons.info_rounded,
            iconColor: Colors.indigo,
            title: '关于 FluxDO',
            showDivider: false,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage())),
          ),
        ],
      ),
    );
  }
  
  Widget _buildOptionTile({
    required IconData icon, 
    Color? iconColor,
    required String title, 
    required VoidCallback onTap,
    bool showDivider = true,
  }) {
    final theme = Theme.of(context);
    final finalIconColor = iconColor ?? theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  // iOS 风格的图标容器保留，因为这不违和且好看
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: finalIconColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: finalIconColor, size: 20),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      title, 
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w500
                      )
                    )
                  ),
                  Icon(
                    Icons.chevron_right_rounded, 
                    color: theme.colorScheme.outline.withOpacity(0.4), 
                    size: 20
                  ),
                ],
              ),
            ),
            if (showDivider)
              Padding(
                padding: const EdgeInsets.only(left: 60), // 对齐文字
                child: Divider(
                  height: 1, 
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withOpacity(0.2)
                ),
              ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildAuthButton(ThemeData theme, bool isLoggedIn) {
    if (isLoggedIn) {
      return Center(
        child: TextButton.icon(
          onPressed: _logout,
          icon: Icon(Icons.logout_rounded, size: 18, color: theme.colorScheme.error.withOpacity(0.8)),
          label: Text('退出当前账号', style: TextStyle(color: theme.colorScheme.error.withOpacity(0.8), fontWeight: FontWeight.w600)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            backgroundColor: theme.colorScheme.errorContainer.withOpacity(0.1),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
      );
    } else {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FilledButton.icon(
          onPressed: _goToLogin,
          icon: const Icon(Icons.login_rounded, size: 20),
          label: const Text('登录 Linux.do', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );
    }
  }
}

/// 独立的头像组件，使用 AutomaticKeepAliveClientMixin 避免重建
class _ProfileAvatar extends StatefulWidget {
  final User? user;

  const _ProfileAvatar({super.key, required this.user});

  @override
  State<_ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<_ProfileAvatar> with AutomaticKeepAliveClientMixin {
  late String _avatarUrl;
  ImageProvider? _cachedImageProvider;
  Widget? _cachedAvatarWithFlair;
  String? _cachedFlairUrl;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _avatarUrl = widget.user?.getAvatarUrl() ?? '';
    _cachedFlairUrl = widget.user?.flairUrl;
    if (_avatarUrl.isNotEmpty) {
      _cachedImageProvider = discourseImageProvider(_avatarUrl);
    }
  }

  @override
  void didUpdateWidget(_ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有当 URL 真的变化时才更新 ImageProvider
    final newUrl = widget.user?.getAvatarUrl() ?? '';
    final newFlairUrl = widget.user?.flairUrl;

    if (newUrl != _avatarUrl) {
      _avatarUrl = newUrl;
      _cachedImageProvider = newUrl.isNotEmpty ? discourseImageProvider(newUrl) : null;
      _cachedAvatarWithFlair = null; // 头像变化，清除缓存
    }

    if (newFlairUrl != _cachedFlairUrl) {
      _cachedFlairUrl = newFlairUrl;
      _cachedAvatarWithFlair = null; // flair 变化，清除缓存
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须调用以支持 AutomaticKeepAliveClientMixin

    // 如果已经缓存了 AvatarWithFlair widget，直接返回
    if (_cachedAvatarWithFlair != null) {
      return _cachedAvatarWithFlair!;
    }

    final theme = Theme.of(context);
    final user = widget.user;

    _cachedAvatarWithFlair = AvatarWithFlair(
      key: ValueKey('profile-avatar-flair-${user?.id}-${user?.flairUrl}'),
      flairSize: 24,
      flairRight: -2,
      flairBottom: -2,
      flairUrl: user?.flairUrl,
      flairName: user?.flairName,
      flairBgColor: user?.flairBgColor,
      flairColor: user?.flairColor,
      avatar: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.colorScheme.surfaceContainerHighest,
            width: 1,
          ),
        ),
        child: CircleAvatar(
          radius: 36,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          backgroundImage: _cachedImageProvider,
          child: _avatarUrl.isEmpty
              ? Icon(
                  user != null ? Icons.person : Icons.person_outline,
                  size: 36,
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : null,
        ),
      ),
    );

    return _cachedAvatarWithFlair!;
  }
}
