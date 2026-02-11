import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/emoji.dart';
import '../../providers/discourse_providers.dart';
import '../../services/discourse/discourse_service.dart';
import '../content/discourse_image.dart';
import '../common/loading_spinner.dart';

/// 常用表情的 Key
const String _recentEmojisKey = 'recent_emojis';

/// 最多保存的常用表情数量
const int _maxRecentEmojis = 30;

class EmojiPicker extends ConsumerStatefulWidget {
  final Function(Emoji) onEmojiSelected;

  const EmojiPicker({super.key, required this.onEmojiSelected});

  @override
  ConsumerState<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends ConsumerState<EmojiPicker>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  TabController? _tabController;
  
  /// 常用表情名称列表（按使用顺序，最近使用的在前）
  List<String> _recentEmojiNames = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadRecentEmojis();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController?.dispose();
    super.dispose();
  }
  
  /// 加载常用表情
  Future<void> _loadRecentEmojis() async {
    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList(_recentEmojisKey) ?? [];
    if (mounted) {
      setState(() => _recentEmojiNames = names);
    }
  }
  
  /// 保存常用表情
  Future<void> _saveRecentEmoji(String emojiName) async {
    // 移除已存在的（如果有），然后添加到开头
    _recentEmojiNames.remove(emojiName);
    _recentEmojiNames.insert(0, emojiName);
    
    // 限制数量
    if (_recentEmojiNames.length > _maxRecentEmojis) {
      _recentEmojiNames = _recentEmojiNames.sublist(0, _maxRecentEmojis);
    }
    
    // 保存到本地
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentEmojisKey, _recentEmojiNames);
    
    if (mounted) setState(() {});
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase().trim();
    if (_searchQuery != query) {
      setState(() {
        _searchQuery = query;
      });
    }
  }

  void _initTabController(int length) {
    if (_tabController == null) {
      _tabController = TabController(length: length, vsync: this);
    } else if (_tabController!.length != length) {
      final oldController = _tabController;
      final oldIndex = oldController!.index;
      // 新增了"常用"tab 在最前面时，原来的索引需要 +1
      final addedTabs = length - oldController.length;
      final newIndex = (oldIndex + addedTabs).clamp(0, length - 1);
      _tabController = TabController(
        length: length,
        vsync: this,
        initialIndex: newIndex,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
  }
  
  /// 显示表情搜索对话框
  Future<void> _showSearchDialog(BuildContext context, Map<String, List<Emoji>>? emojiGroups) async {
    if (emojiGroups == null || emojiGroups.isEmpty) return;

    final allEmojis = emojiGroups.values.expand((e) => e).toList();
    // 保存回调：弹窗打开后表情面板可能被卸载，需要提前捕获
    final onSelected = widget.onEmojiSelected;

    final selectedEmoji = await showModalBottomSheet<Emoji>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _EmojiSearchSheet(allEmojis: allEmojis),
    );

    if (selectedEmoji != null) {
      // 保存常用表情（不依赖 mounted 状态）
      _recentEmojiNames.remove(selectedEmoji.name);
      _recentEmojiNames.insert(0, selectedEmoji.name);
      if (_recentEmojiNames.length > _maxRecentEmojis) {
        _recentEmojiNames = _recentEmojiNames.sublist(0, _maxRecentEmojis);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentEmojisKey, _recentEmojiNames);
      if (mounted) setState(() {});
      // 使用捕获的回调插入表情
      onSelected(selectedEmoji);
    }
  }
  
  void _onEmojiTap(Emoji emoji) {
    _saveRecentEmoji(emoji.name);
    widget.onEmojiSelected(emoji);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final emojisAsync = ref.watch(emojiGroupsProvider);

    return ClipRect(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: (() {
          final emojis = emojisAsync.value;
          // 优先使用缓存数据，避免不必要的 loading 状态
          if (emojis != null) {
            return _buildContent(emojis);
          }
          return emojisAsync.when(
            data: (groups) => _buildContent(groups),
            loading: () => const Center(child: LoadingSpinner()),
            error: (err, stack) => Center(child: Text('加载表情失败: $err')),
          );
        })(),
      ),
    );
  }

  Widget _buildContent(Map<String, List<Emoji>> emojiGroups) {
    if (emojiGroups.isEmpty) {
      return const Center(child: Text('没有找到表情'));
    }

    if (_searchQuery.isNotEmpty) {
      final allEmojis = emojiGroups.values.expand((element) => element);
      final searchResults = allEmojis.where((emoji) {
        return emoji.name.toLowerCase().contains(_searchQuery) ||
            emoji.searchAliases.any((alias) => alias.toLowerCase().contains(_searchQuery));
      }).toList();

       if (searchResults.isEmpty) {
        return const Center(child: Text('未找到相关表情'));
      }
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 40,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: searchResults.length,
        itemBuilder: (context, index) {
          return _buildEmojiItem(searchResults[index]);
        },
      );
    }
    
    // 构建常用表情列表
    final List<Emoji> recentEmojis = [];
    if (_recentEmojiNames.isNotEmpty) {
      final allEmojisMap = <String, Emoji>{};
      for (final group in emojiGroups.values) {
        for (final emoji in group) {
          allEmojisMap[emoji.name] = emoji;
        }
      }
      for (final name in _recentEmojiNames) {
        final emoji = allEmojisMap[name];
        if (emoji != null) {
          recentEmojis.add(emoji);
        }
      }
    }
    
    // 构建 Tab 列表：常用（如果有）+ 其他分组
    final hasRecent = recentEmojis.isNotEmpty;
    final groupKeys = emojiGroups.keys.toList();
    final totalTabs = (hasRecent ? 1 : 0) + groupKeys.length;
    
    _initTabController(totalTabs);

    if (_tabController == null) {
      return const Center(child: LoadingSpinner());
    }

    // 构建 Tab 标签
    final tabs = <Widget>[];
    if (hasRecent) {
      tabs.add(const Tab(text: '常用'));
    }
    tabs.addAll(groupKeys.map((group) => Tab(text: _formatGroupName(group))));
    
    // 构建 TabBarView 内容
    final tabViews = <Widget>[];
    if (hasRecent) {
      tabViews.add(GridView.builder(
        key: const PageStorageKey('recent'),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 40,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: recentEmojis.length,
        itemBuilder: (context, index) {
          return _buildEmojiItem(recentEmojis[index]);
        },
      ));
    }
    tabViews.addAll(groupKeys.map((group) {
      final emojis = emojiGroups[group]!;
      return GridView.builder(
        key: PageStorageKey(group),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 40,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: emojis.length,
        itemBuilder: (context, index) {
          return _buildEmojiItem(emojis[index]);
        },
      );
    }));

    return Column(
      children: [
        // TabBar + 搜索按钮
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
             // 搜索按钮 (左侧显示，更协调)
            IconButton(
              icon: Icon(Icons.search, size: 20, color: Theme.of(context).colorScheme.primary),
              onPressed: () => _showSearchDialog(context, emojiGroups),
              tooltip: '搜索表情',
            ),
            Container(
              height: 20,
              width: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: tabs,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                dividerColor: Colors.transparent, // 移除 TabBar 底部的默认分割线
              ),
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: tabViews,
          ),
        ),
      ],
    );
  }

  Widget _buildEmojiItem(Emoji emoji) {
    return InkWell(
      onTap: () => _onEmojiTap(emoji),
      borderRadius: BorderRadius.circular(4),
      child: Tooltip(
        message: ':${emoji.name}:',
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: DiscourseImage(
             url: DiscourseService.baseUrl + emoji.url,
             fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  String _formatGroupName(String name) {
    if (name == 'smileys_&_emotion') return '表情';
    if (name == 'people_&_body') return '人物';
    if (name == 'animals_&_nature') return '动物';
    if (name == 'food_&_drink') return '食物';
    if (name == 'activities') return '活动';
    if (name == 'travel_&_places') return '旅行';
    if (name == 'objects') return '物体';
    if (name == 'symbols') return '符号';
    if (name == 'flags') return '旗帜';
    return name.replaceAll('_&_', ' & ').replaceAll('_', ' ').capitalize();
  }
}

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}

/// 表情搜索面板 (Bottom Sheet)
class _EmojiSearchSheet extends StatefulWidget {
  final List<Emoji> allEmojis;

  const _EmojiSearchSheet({
    required this.allEmojis,
  });

  @override
  State<_EmojiSearchSheet> createState() => _EmojiSearchSheetState();
}

class _EmojiSearchSheetState extends State<_EmojiSearchSheet> {
  final _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.toLowerCase().trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    
    // 过滤结果
    final results = _query.isEmpty ? [] : widget.allEmojis.where((emoji) {
      return emoji.name.toLowerCase().contains(_query) ||
          emoji.searchAliases.any((alias) => alias.toLowerCase().contains(_query));
    }).toList();

    return Container(
      height: mediaQuery.size.height * 0.8, // 占用 80% 高度
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 顶部拖拽条和搜索栏区域
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
            ),
            child: Column(
              children: [
                // 拖拽条
                Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 搜索栏
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          textAlignVertical: TextAlignVertical.center,
                          style: const TextStyle(fontSize: 16),
                          decoration: InputDecoration(
                            hintText: '搜索表情...',
                            hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.only(left: 0, right: 12),
                            prefixIcon: Icon(Icons.search, size: 20, color: theme.colorScheme.onSurface),
                            suffixIcon: _query.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.cancel, size: 18),
                                    color: theme.colorScheme.onSurfaceVariant,
                                    onPressed: () => _searchController.clear(),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        Navigator.pop(context);
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // 内容区域
          Expanded(
            child: _query.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.emoji_emotions_outlined, size: 48, color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                        const SizedBox(height: 16),
                        Text(
                          '输入关键词搜索表情',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                : results.isEmpty
                    ? Center(
                        child: Text(
                          '未找到相关表情',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      )
                    : GridView.builder(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, mediaQuery.viewInsets.bottom + 16),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 48,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final emoji = results[index];
                          return InkWell(
                            onTap: () {
                              FocusScope.of(context).unfocus();
                              Navigator.pop(context, emoji);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Tooltip(
                              message: ':${emoji.name}:',
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: DiscourseImage(
                                  url: DiscourseService.baseUrl + emoji.url,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
