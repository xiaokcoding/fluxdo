import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../providers/discourse_providers.dart';
import '../models/search_result.dart';
import '../models/category.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/font_awesome_helper.dart';
import '../utils/time_utils.dart';
import '../utils/number_utils.dart';
import '../constants.dart';
import 'topic_detail_page/topic_detail_page.dart';
import '../widgets/common/loading_spinner.dart';
import 'user_profile_page.dart';

/// 搜索排序方式
enum SearchSortOrder {
  relevance('相关性', null),
  latest('最新帖子', 'latest'),
  likes('最受欢迎', 'likes'),
  views('最多浏览', 'views'),
  latestTopic('最新话题', 'latest_topic');

  final String label;
  final String? value;
  const SearchSortOrder(this.label, this.value);
}

/// 搜索页面
class SearchPage extends ConsumerStatefulWidget {
  final String? initialQuery;

  const SearchPage({super.key, this.initialQuery});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  String _currentQuery = '';
  SearchSortOrder _sortOrder = SearchSortOrder.relevance;
  int _currentPage = 1;
  bool _isLoadingMore = false;
  List<SearchPost> _allPosts = [];
  List<SearchUser> _allUsers = [];
  bool _hasMorePosts = false;
  bool _hasMoreUsers = false;
  bool _hasError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _searchController.text = widget.initialQuery!;
      _currentQuery = widget.initialQuery!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _performSearch();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        _hasMorePosts) {
      _loadMore();
    }
  }

  void _onSearch(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    if (trimmed != _currentQuery || _allPosts.isEmpty) {
      setState(() {
        _currentQuery = trimmed;
        _currentPage = 1;
        _allPosts = [];
        _allUsers = [];
        _hasMorePosts = false;
        _hasMoreUsers = false;
        _hasError = false;
      });
      _performSearch();
    }
  }

  void _onSortChanged(SearchSortOrder? order) {
    if (order != null && order != _sortOrder) {
      setState(() {
        _sortOrder = order;
        _currentPage = 1;
        _allPosts = [];
        _allUsers = [];
      });
      _performSearch();
    }
  }

  Future<void> _performSearch() async {
    if (_currentQuery.isEmpty) return;

    setState(() {
      _hasError = false;
      if (_currentPage == 1) {
        _isLoadingMore = false;
      }
    });

    try {
      final service = ref.read(discourseServiceProvider);
      String searchQuery = _currentQuery;
      if (_sortOrder.value != null) {
        searchQuery = '$_currentQuery order:${_sortOrder.value}';
      }
      final result =
          await service.search(query: searchQuery, page: _currentPage);

      setState(() {
        if (_currentPage == 1) {
          _allPosts = result.posts;
          _allUsers = result.users;
        } else {
          _allPosts.addAll(result.posts);
        }
        _hasMorePosts = result.hasMorePosts;
        _hasMoreUsers = result.hasMoreUsers;
        _isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMorePosts) return;

    setState(() {
      _isLoadingMore = true;
      _currentPage++;
    });

    await _performSearch();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _currentQuery = '';
      _allPosts = [];
      _allUsers = [];
      _hasMorePosts = false;
      _hasMoreUsers = false;
      _currentPage = 1;
    });
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          onSubmitted: _onSearch,
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: '搜索话题、用户...',
            border: InputBorder.none,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _clearSearch,
                  )
                : null,
          ),
          onChanged: (value) {
            setState(() {});
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _onSearch(_searchController.text),
            tooltip: '搜索',
          ),
        ],
      ),
      body: _currentQuery.isEmpty
          ? _buildEmptyState(theme)
          : _buildSearchResults(theme),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '输入关键词搜索',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '支持 @用户名  #分类  tags:标签 等语法',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(ThemeData theme) {
    if (_hasError && _allPosts.isEmpty) {
      return _buildError(_errorMessage);
    }

    if (_allPosts.isEmpty && _allUsers.isEmpty && !_isLoadingMore) {
      if (_currentPage == 1) {
        return const Center(child: LoadingSpinner());
      }
      return _buildNoResults();
    }

    return Column(
      children: [
        // 排序选项
        if (_allPosts.isNotEmpty || _allUsers.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  '排序：',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<SearchSortOrder>(
                  value: _sortOrder,
                  isDense: true,
                  underline: const SizedBox(),
                  items: SearchSortOrder.values.map((order) {
                    return DropdownMenuItem(
                      value: order,
                      child: Text(order.label),
                    );
                  }).toList(),
                  onChanged: _onSortChanged,
                ),
                const Spacer(),
                Text(
                  '${_allPosts.length}${_hasMorePosts ? '+' : ''} 条结果',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _allPosts.length +
                (_allUsers.isNotEmpty ? _allUsers.length + 1 : 0) +
                (_isLoadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              // 帖子结果
              if (index < _allPosts.length) {
                return _SearchPostCard(
                  post: _allPosts[index],
                  onTap: () {
                    final topic = _allPosts[index].topic;
                    if (topic != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TopicDetailPage(
                            topicId: topic.id,
                            scrollToPostNumber: _allPosts[index].postNumber,
                          ),
                        ),
                      );
                    }
                  },
                );
              }

              // 用户标题
              final userStartIndex = _allPosts.length;
              if (_allUsers.isNotEmpty && index == userStartIndex) {
                return Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: _buildSectionHeader(
                      '用户', _allUsers.length, _hasMoreUsers),
                );
              }

              // 用户结果
              if (_allUsers.isNotEmpty && index > userStartIndex) {
                final userIndex = index - userStartIndex - 1;
                if (userIndex < _allUsers.length) {
                  return _SearchUserCard(
                    user: _allUsers[userIndex],
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserProfilePage(
                              username: _allUsers[userIndex].username),
                        ),
                      );
                    },
                  );
                }
              }

              // 加载更多指示器
              if (_isLoadingMore) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: LoadingSpinner()),
                );
              }

              return const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildError(String error) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            '搜索出错',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            error,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildNoResults() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '没有找到相关结果',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '请尝试其他关键词',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, bool hasMore) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          hasMore ? '$count+' : '$count',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

/// 搜索结果帖子卡片 - 复用 TopicCard 风格
class _SearchPostCard extends ConsumerWidget {
  final SearchPost post;
  final VoidCallback? onTap;

  const _SearchPostCard({required this.post, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final topic = post.topic;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = topic?.categoryId;
    Category? category;
    if (categoryId != null && categoryMap != null) {
      category = categoryMap[categoryId];
    }

    // 图标逻辑：本级 FA Icon -> 本级 Logo -> 父级 FA Icon -> 父级 Logo
    IconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 标题行
              if (topic != null)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildTopicTitle(post, topic, theme),
                    ),
                    // 楼层号
                    if (post.postNumber > 1)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '#${post.postNumber}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),

              const SizedBox(height: 10),

              // 2. 分类与标签行
              if (topic != null && (category != null || topic.tags.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 分类 Badge
                      if (category != null)
                        _buildCategoryBadge(
                            context, category, faIcon, logoUrl, theme),

                      // 标签 Badges
                      ...topic.tags.take(3).map((tag) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withOpacity(0.5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '# ${tag.name}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )),
                    ],
                  ),
                ),

              // 3. 帖子摘要
              if (post.blurb.isNotEmpty) ...[
                _buildBlurb(post.blurb, theme),
                const SizedBox(height: 12),
              ],

              // 4. 底部信息栏
              Row(
                children: [
                  // 用户头像
                  CircleAvatar(
                    radius: 12,
                    backgroundImage: post.getAvatarUrl().isNotEmpty
                        ? discourseImageProvider(post.getAvatarUrl(size: 48))
                        : null,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    child: post.getAvatarUrl().isEmpty
                        ? Text(
                            post.username.isNotEmpty
                                ? post.username[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    post.username,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const Spacer(),

                  // 点赞数
                  if (post.likeCount > 0) ...[
                    Icon(Icons.favorite_border_rounded,
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      NumberUtils.formatCount(post.likeCount),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],

                  // 时间
                  Text(
                    TimeUtils.formatRelativeTime(post.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopicTitle(
      SearchPost post, SearchTopic topic, ThemeData theme) {
    // 如果有高亮标题，使用高亮版本
    if (post.topicTitleHeadline != null &&
        post.topicTitleHeadline!.isNotEmpty) {
      return _buildHighlightedText(
        post.topicTitleHeadline!,
        theme,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (topic.closed)
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 2),
            child: Icon(
              Icons.lock,
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ),
        if (topic.archived)
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 2),
            child: Icon(
              Icons.archive,
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ),
        Expanded(
          child: Text(
            topic.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryBadge(BuildContext context, Category category,
      IconData? faIcon, String? logoUrl, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _parseColor(category.color).withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _parseColor(category.color).withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (faIcon != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FaIcon(
                faIcon,
                size: 10,
                color: _parseColor(category.color),
              ),
            )
          else if (logoUrl != null && logoUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Image(
                image: discourseImageProvider(
                  logoUrl.startsWith('http')
                      ? logoUrl
                      : '${AppConstants.baseUrl}$logoUrl',
                ),
                width: 10,
                height: 10,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return _buildCategoryDot(category);
                },
              ),
            )
          else if (category.readRestricted)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.lock,
                size: 10,
                color: _parseColor(category.color),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _buildCategoryDot(category),
            ),
          Text(
            category.name,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _buildBlurb(String blurb, ThemeData theme) {
    return _buildHighlightedText(
      blurb,
      theme,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.4,
      ),
    );
  }

  Widget _buildHighlightedText(String text, ThemeData theme,
      {TextStyle? style}) {
    // Discourse 使用 <span class="search-highlight">...</span> 来高亮
    final regex = RegExp(r'<span class="search-highlight">(.*?)</span>');
    final matches = regex.allMatches(text);

    if (matches.isEmpty) {
      // 没有高亮，直接显示纯文本（移除其他 HTML 标签）
      final cleanText = text.replaceAll(RegExp(r'<[^>]*>'), '');
      return Text(
        cleanText,
        style: style,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      // 添加高亮前的文本
      if (match.start > lastEnd) {
        final beforeText = text
            .substring(lastEnd, match.start)
            .replaceAll(RegExp(r'<[^>]*>'), '');
        spans.add(TextSpan(text: beforeText));
      }

      // 添加高亮文本
      final highlightedText = match.group(1) ?? '';
      spans.add(TextSpan(
        text: highlightedText,
        style: TextStyle(
          backgroundColor: theme.colorScheme.primaryContainer,
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ));

      lastEnd = match.end;
    }

    // 添加剩余文本
    if (lastEnd < text.length) {
      final afterText =
          text.substring(lastEnd).replaceAll(RegExp(r'<[^>]*>'), '');
      spans.add(TextSpan(text: afterText));
    }

    return RichText(
      text: TextSpan(
        style: style,
        children: spans,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}

/// 搜索结果用户卡片 - 复用 TopicCard 风格
class _SearchUserCard extends StatelessWidget {
  final SearchUser user;
  final VoidCallback? onTap;

  const _SearchUserCard({required this.user, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundImage: user.getAvatarUrl().isNotEmpty
                    ? discourseImageProvider(user.getAvatarUrl(size: 80))
                    : null,
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: user.getAvatarUrl().isEmpty
                    ? Text(
                        user.username.isNotEmpty
                            ? user.username[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          fontSize: 16,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.username,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (user.name != null && user.name!.isNotEmpty)
                      Text(
                        user.name!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
