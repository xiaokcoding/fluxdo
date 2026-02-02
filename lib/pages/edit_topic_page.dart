import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/widgets/common/loading_spinner.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_toolbar.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';

import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo/services/emoji_handler.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/widgets/mention/mention_autocomplete.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';

/// 编辑话题结果
class EditTopicResult {
  final String? title;
  final int? categoryId;
  final List<String>? tags;
  final Post? updatedFirstPost;

  const EditTopicResult({
    this.title,
    this.categoryId,
    this.tags,
    this.updatedFirstPost,
  });
}

class EditTopicPage extends ConsumerStatefulWidget {
  final TopicDetail topicDetail;
  /// 首贴，可选。如果为 null 会尝试通过 firstPostId 加载
  final Post? firstPost;
  /// 首贴 ID，用于在 firstPost 为 null 时加载首贴
  final int? firstPostId;

  const EditTopicPage({
    super.key,
    required this.topicDetail,
    this.firstPost,
    this.firstPostId,
  });

  @override
  ConsumerState<EditTopicPage> createState() => _EditTopicPageState();
}

class _EditTopicPageState extends ConsumerState<EditTopicPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocusNode = FocusNode();
  final _toolbarKey = GlobalKey<MarkdownToolbarState>();

  // 文本处理器
  final _smartListHandler = SmartListHandler();
  final _panguHandler = PanguSpacingHandler();

  Category? _selectedCategory;
  List<String> _selectedTags = [];
  bool _isSubmitting = false;
  bool _showPreview = false;
  bool _isLoadingContent = true;

  final PageController _pageController = PageController();
  int _contentLength = 0;

  // 首贴（可能从 widget 传入，也可能异步加载）
  Post? _firstPost;

  // 原始值，用于检测变化
  String? _originalTitle;
  int? _originalCategoryId;
  List<String>? _originalTags;
  String? _originalContent;

  /// 是否为私信编辑
  bool get _isPrivateMessage => widget.topicDetail.isPrivateMessage;

  /// 是否可以编辑话题元数据（标题、分类、标签）
  bool get _canEditMetadata => widget.topicDetail.canEdit;

  /// 是否可以编辑首贴内容（需要有首贴且有编辑权限）
  bool get _canEditContent => _firstPost?.canEdit ?? false;

  @override
  void initState() {
    super.initState();
    // 初始化 EmojiHandler 以支持预览
    EmojiHandler().init();

    // 预填充数据
    _titleController.text = widget.topicDetail.title;
    _originalTitle = widget.topicDetail.title;
    _originalCategoryId = widget.topicDetail.categoryId;
    _originalTags = widget.topicDetail.tags?.map((tag) => tag.name).toList() ?? [];
    _selectedTags = List.from(_originalTags!);

    // 初始化首贴
    _firstPost = widget.firstPost;

    // 加载首贴和内容
    _loadFirstPostAndContent();

    // 非私信时加载分类数据
    if (!_isPrivateMessage) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSelectedCategory());
    }
  }

  void _loadSelectedCategory() {
    ref.listenManual(categoriesProvider, (previous, next) {
      next.whenData((categories) {
        if (!mounted) return;
        final category = categories.where((c) => c.id == widget.topicDetail.categoryId).firstOrNull;
        if (category != null && _selectedCategory == null) {
          setState(() => _selectedCategory = category);
        }
      });
    }, fireImmediately: true);
  }

  Future<void> _loadFirstPostAndContent() async {
    final service = ref.read(discourseServiceProvider);

    try {
      // 如果没有首贴但有首贴 ID，先加载首贴
      if (_firstPost == null && widget.firstPostId != null) {
        final postStream = await service.getPosts(widget.topicDetail.id, [widget.firstPostId!]);
        if (mounted && postStream.posts.isNotEmpty) {
          setState(() => _firstPost = postStream.posts.first);
        }
      }

      // 加载首贴原始内容（无论是否可编辑都加载，用于显示）
      if (_firstPost != null) {
        final raw = await service.getPostRaw(_firstPost!.id);
        if (mounted && raw != null) {
          _contentController.text = raw;
          _originalContent = raw;
          _contentLength = raw.length;

          // 可编辑时添加监听器
          if (_canEditContent) {
            _contentController.addListener(_updateContentLength);
            _contentController.addListener(_handleContentTextChange);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载内容失败: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingContent = false);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _updateContentLength() {
    setState(() => _contentLength = _contentController.text.length);
  }

  void _handleContentTextChange() {
    // 智能列表续行
    if (_smartListHandler.handleTextChange(_contentController)) {
      return;
    }

    // 自动 Pangu 空格
    if (ref.read(preferencesProvider).autoPanguSpacing) {
      if (_panguHandler.autoApply(_contentController, _smartListHandler.updatePreviousText)) {
        return;
      }
    }

    _smartListHandler.updatePreviousText(_contentController.text);
  }

  void _applyPanguSpacing() {
    _panguHandler.manualApply(_contentController, _smartListHandler.updatePreviousText);
  }

  void _onCategorySelected(Category category) {
    setState(() => _selectedCategory = category);
  }

  void _togglePreview() {
    if (_showPreview) {
      _pageController.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      _pageController.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // 只有在有权限编辑元数据且不是私信时才验证分类
    if (_canEditMetadata && !_isPrivateMessage && _selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择分类')),
      );
      return;
    }

    // 只有在有权限编辑元数据时才验证标签数量
    if (_canEditMetadata &&
        !_isPrivateMessage &&
        _selectedCategory != null &&
        _selectedCategory!.minimumRequiredTags > 0 &&
        _selectedTags.length < _selectedCategory!.minimumRequiredTags) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('此分类至少需要 ${_selectedCategory!.minimumRequiredTags} 个标签')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final newTitle = _titleController.text.trim();
      final newContent = _contentController.text;

      // 检测话题元数据变化（仅当有权限编辑元数据时）
      final titleChanged = _canEditMetadata && newTitle != _originalTitle;
      // 私信不支持分类和标签
      final categoryChanged = _canEditMetadata &&
          !_isPrivateMessage &&
          _selectedCategory != null &&
          _selectedCategory!.id != _originalCategoryId;
      final tagsChanged = _canEditMetadata &&
          !_isPrivateMessage &&
          !_listEquals(_selectedTags, _originalTags ?? []);
      // 检测内容变化（仅当有权限编辑内容时）
      final contentChanged = _canEditContent && newContent != _originalContent;

      // 更新话题元数据（如果有变化且有权限）
      if (titleChanged || categoryChanged || tagsChanged) {
        await service.updateTopic(
          topicId: widget.topicDetail.id,
          title: titleChanged ? newTitle : null,
          categoryId: categoryChanged ? _selectedCategory!.id : null,
          tags: tagsChanged ? _selectedTags : null,
        );
      }

      // 更新首贴内容（如果有变化且有权限）
      Post? updatedPost;
      if (contentChanged && _firstPost != null) {
        updatedPost = await service.updatePost(
          postId: _firstPost!.id,
          raw: newContent,
        );
      }

      if (!mounted) return;

      // 返回编辑结果
      Navigator.of(context).pop(EditTopicResult(
        title: titleChanged ? newTitle : null,
        categoryId: categoryChanged ? _selectedCategory!.id : null,
        tags: tagsChanged ? _selectedTags : null,
        updatedFirstPost: updatedPost,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sortedA = List<String>.from(a)..sort();
    final sortedB = List<String>.from(b)..sort();
    for (int i = 0; i < sortedA.length; i++) {
      if (sortedA[i] != sortedB[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);
    final canTagTopics = ref.watch(canTagTopicsProvider).value ?? false;
    final theme = Theme.of(context);

    // 获取站点配置的最小长度
    final minTitleLength = _isPrivateMessage
        ? (ref.watch(minPmTitleLengthProvider).value ?? 2)
        : (ref.watch(minTopicTitleLengthProvider).value ?? 15);
    final minContentLength = _isPrivateMessage
        ? (ref.watch(minPmPostLengthProvider).value ?? 10)
        : (ref.watch(minFirstPostLengthProvider).value ?? 20);

    final showEmojiPanel = _toolbarKey.currentState?.showEmojiPanel ?? false;

    return PopScope(
      canPop: !showEmojiPanel,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        _toolbarKey.currentState?.closeEmojiPanel();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(_isPrivateMessage ? '编辑私信' : '编辑话题'),
          scrolledUnderElevation: 0,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton(
                onPressed: (_isSubmitting || _isLoadingContent) ? null : _submit,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('保存'),
              ),
            ),
          ],
        ),
        body: _isPrivateMessage
            ? _buildBody(theme, [], canTagTopics, tagsAsync, minTitleLength, minContentLength)
            : categoriesAsync.when(
                data: (categories) => _buildBody(theme, categories, canTagTopics, tagsAsync, minTitleLength, minContentLength),
                loading: () => const Center(child: LoadingSpinner()),
                error: (err, stack) => Center(child: Text('加载分类失败: $err')),
              ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, List<Category> categories, bool canTagTopics, AsyncValue<List<String>> tagsAsync, int minTitleLength, int minContentLength) {
    if (_isLoadingContent) {
      return const Center(child: LoadingSpinner());
    }

    // 构建元数据编辑区域（标题、分类、标签）
    Widget buildMetadataSection() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题输入
          TextFormField(
            controller: _titleController,
            enabled: _canEditMetadata,
            decoration: InputDecoration(
              hintText: '键入一个吸引人的标题...',
              hintStyle: TextStyle(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                fontWeight: FontWeight.normal,
              ),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              color: _canEditMetadata ? null : theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: null,
            maxLength: 200,
            buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
            validator: _canEditMetadata ? (value) {
              if (value == null || value.trim().isEmpty) return '请输入标题';
              if (value.trim().length < minTitleLength) return '标题至少需要 $minTitleLength 个字符';
              return null;
            } : null,
            onTap: () {
              _toolbarKey.currentState?.closeEmojiPanel();
            },
          ),

          const SizedBox(height: 16),

          // 元数据区域 (分类 + 标签) - 私信不显示
          if (!_isPrivateMessage)
            IgnorePointer(
              ignoring: !_canEditMetadata,
              child: Opacity(
                opacity: _canEditMetadata ? 1.0 : 0.6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CategoryTrigger(
                      category: _selectedCategory,
                      categories: categories,
                      onSelected: _onCategorySelected,
                    ),
                    if (canTagTopics) ...[
                      const SizedBox(height: 12),
                      tagsAsync.when(
                        data: (tags) => TagsArea(
                          selectedCategory: _selectedCategory,
                          selectedTags: _selectedTags,
                          allTags: tags,
                          onTagsChanged: (newTags) => setState(() => _selectedTags = newTags),
                        ),
                        loading: () => const SizedBox.shrink(),
                        error: (e, s) => const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          const SizedBox(height: 20),
          Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
          const SizedBox(height: 20),
        ],
      );
    }

    // 如果没有内容编辑权限，不需要 PageView，直接显示表单 + 渲染后的内容
    if (!_canEditContent) {
      return Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          children: [
            buildMetadataSection(),
            // 直接显示渲染后的内容
            MarkdownBody(data: _contentController.text),
          ],
        ),
      );
    }

    // 有内容编辑权限时，使用 PageView 支持编辑/预览切换
    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _showPreview = index == 1;
              });
              if (_showPreview) {
                FocusScope.of(context).unfocus();
                _toolbarKey.currentState?.closeEmojiPanel();
              }
            },
            children: [
              // Page 0: 编辑模式
              Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  children: [
                    buildMetadataSection(),
                    // 内容编辑器
                    MentionAutocomplete(
                      controller: _contentController,
                      focusNode: _contentFocusNode,
                      dataSource: (term) => ref.read(discourseServiceProvider).searchUsers(
                        term: term,
                        categoryId: _selectedCategory?.id,
                        includeGroups: !_isPrivateMessage, // 私信不允许提及群组
                      ),
                      child: TextFormField(
                        controller: _contentController,
                        focusNode: _contentFocusNode,
                        maxLines: null,
                        minLines: 12,
                        decoration: InputDecoration(
                          hintText: '正文内容 (支持 Markdown)...',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.6,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) return '请输入内容';
                          if (value.trim().length < minContentLength) return '内容至少需要 $minContentLength 个字符';
                          return null;
                        },
                        onTap: () {
                          _toolbarKey.currentState?.closeEmojiPanel();
                        },
                      ),
                    ),
                    const SizedBox(height: 40),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '$_contentLength 字符',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Page 1: 预览模式
              SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleController.text.isEmpty ? '（无标题）' : _titleController.text,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!_isPrivateMessage)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_selectedCategory != null)
                            CategoryTrigger(
                              category: _selectedCategory,
                              categories: categories,
                              onSelected: _onCategorySelected,
                            ),
                          PreviewTagsList(tags: _selectedTags),
                        ],
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Divider(height: 1),
                    ),
                    if (_contentController.text.isEmpty)
                      Text(
                        '（无内容）',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      )
                    else
                      MarkdownBody(data: _contentController.text),
                  ],
                ),
              ),
            ],
          ),
        ),

        // 底部工具栏区域
        Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: MarkdownToolbar(
            key: _toolbarKey,
            controller: _contentController,
            focusNode: _contentFocusNode,
            isPreview: _showPreview,
            onTogglePreview: _togglePreview,
            onApplyPangu: _applyPanguSpacing,
            showPanguButton: true,
            emojiPanelHeight: 350,
          ),
        ),
      ],
    );
  }
}
