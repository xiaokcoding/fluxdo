import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/widgets/common/loading_spinner.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_toolbar.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/draft.dart';

import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo/services/emoji_handler.dart';
import 'package:fluxdo/services/draft_controller.dart';
import 'package:fluxdo/widgets/topic/topic_filter_sheet.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/widgets/mention/mention_autocomplete.dart';
import 'package:fluxdo/widgets/topic/topic_editor_helpers.dart';

class CreateTopicPage extends ConsumerStatefulWidget {
  const CreateTopicPage({super.key});

  @override
  ConsumerState<CreateTopicPage> createState() => _CreateTopicPageState();
}

class _CreateTopicPageState extends ConsumerState<CreateTopicPage> {
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
  String? _templateContent;
  // ignore: unused_field
  bool _isLoadingDraft = false;

  final PageController _pageController = PageController();
  int _contentLength = 0;

  // 草稿控制器
  late final DraftController _draftController;

  @override
  void initState() {
    super.initState();
    _contentController.addListener(_updateContentLength);
    _contentController.addListener(_handleContentTextChange);
    // 初始化 EmojiHandler 以支持预览
    EmojiHandler().init();

    // 初始化草稿控制器
    _draftController = DraftController(draftKey: Draft.newTopicKey);

    // 添加草稿自动保存监听
    _titleController.addListener(_onDraftContentChanged);
    _contentController.addListener(_onDraftContentChanged);

    // 加载现有草稿
    _loadExistingDraft();

    // 从当前筛选条件自动填入分类和标签
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyCurrentFilter());
  }

  /// 加载现有草稿
  Future<void> _loadExistingDraft() async {
    setState(() => _isLoadingDraft = true);
    try {
      final draft = await _draftController.loadDraft();
      if (!mounted) return;

      if (draft != null && draft.hasContent) {
        // 弹出恢复草稿对话框
        final restore = await _showRestoreDraftDialog();
        if (restore == true && mounted) {
          _restoreDraft(draft);
        } else if (restore == false && mounted) {
          // 用户选择丢弃，删除草稿
          await _draftController.deleteDraft();
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingDraft = false);
      }
    }
  }

  /// 显示恢复草稿对话框
  Future<bool?> _showRestoreDraftDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('恢复草稿'),
        content: const Text('检测到未发送的草稿，是否恢复？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('丢弃'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
  }

  /// 恢复草稿内容
  void _restoreDraft(Draft draft) {
    if (draft.data.title != null) {
      _titleController.text = draft.data.title!;
    }
    if (draft.data.reply != null) {
      _contentController.text = draft.data.reply!;
      _templateContent = null; // 恢复草稿后清除模板标记
    }
    if (draft.data.tags != null && draft.data.tags!.isNotEmpty) {
      setState(() => _selectedTags = List.from(draft.data.tags!));
    }
    // 分类需要在 categories 加载后设置，通过 _applyCurrentFilter 中处理
    if (draft.data.categoryId != null) {
      // 监听 categories 加载完成后设置分类
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreCategoryFromDraft(draft.data.categoryId!);
      });
    }
  }

  /// 从草稿恢复分类
  void _restoreCategoryFromDraft(int categoryId) {
    ref.listenManual(categoriesProvider, (previous, next) {
      next.whenData((categories) {
        if (!mounted) return;
        final category = categories.where((c) => c.id == categoryId).firstOrNull;
        if (category != null && category.canCreateTopic) {
          setState(() => _selectedCategory = category);
        }
      });
    }, fireImmediately: true);
  }

  /// 草稿内容变化时触发保存
  void _onDraftContentChanged() {
    final data = DraftData(
      title: _titleController.text,
      reply: _contentController.text,
      categoryId: _selectedCategory?.id,
      tags: _selectedTags.isNotEmpty ? _selectedTags : null,
      action: 'createTopic',
      archetypeId: 'regular',
    );
    _draftController.scheduleSave(data);
  }

  /// 舍弃草稿
  Future<void> _discardDraft() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃帖子'),
        content: const Text('你想放弃你的帖子吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('舍弃'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await _draftController.deleteDraft();
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _applyCurrentFilter() async {
    final filter = ref.read(topicFilterProvider);
    if (filter.tags.isNotEmpty) {
      setState(() => _selectedTags = List.from(filter.tags));
    }

    // 确定要选择的分类 ID：优先使用筛选条件中的，否则使用站点默认分类
    int? targetCategoryId = filter.categoryId;
    targetCategoryId ??= await PreloadedDataService().getDefaultComposerCategoryId();

    if (targetCategoryId != null && mounted) {
      // 监听 categories 加载完成
      ref.listenManual(categoriesProvider, (previous, next) {
        next.whenData((categories) {
          if (!mounted) return;
          final category = categories.where((c) => c.id == targetCategoryId).firstOrNull;
          if (category != null && category.canCreateTopic && _selectedCategory == null) {
            _onCategorySelected(category);
          }
        });
      }, fireImmediately: true);
    }
  }

  @override
  void dispose() {
    // 移除草稿监听器
    _titleController.removeListener(_onDraftContentChanged);
    _contentController.removeListener(_onDraftContentChanged);

    // 关闭时立即保存草稿（如果有内容）
    if (_titleController.text.trim().isNotEmpty || _contentController.text.trim().isNotEmpty) {
      final data = DraftData(
        title: _titleController.text,
        reply: _contentController.text,
        categoryId: _selectedCategory?.id,
        tags: _selectedTags.isNotEmpty ? _selectedTags : null,
        action: 'createTopic',
        archetypeId: 'regular',
      );
      _draftController.saveNow(data);
    }
    _draftController.dispose();

    _pageController.dispose();
    _contentController.removeListener(_updateContentLength);
    _contentController.removeListener(_handleContentTextChange);
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

    final currentContent = _contentController.text.trim();
    if (currentContent.isEmpty ||
        (_templateContent != null && currentContent == _templateContent!.trim())) {
      if (category.topicTemplate != null && category.topicTemplate!.isNotEmpty) {
        _contentController.text = category.topicTemplate!;
        _templateContent = category.topicTemplate;
      } else {
        _contentController.clear();
        _templateContent = null;
      }
    }

    // 触发草稿保存
    _onDraftContentChanged();
  }

  /// 标签变化时触发草稿保存
  void _onTagsChanged(List<String> newTags) {
    setState(() => _selectedTags = newTags);
    _onDraftContentChanged();
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

    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择分类')),
      );
      return;
    }

    if (_selectedCategory!.minimumRequiredTags > 0 &&
        _selectedTags.length < _selectedCategory!.minimumRequiredTags) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('此分类至少需要 ${_selectedCategory!.minimumRequiredTags} 个标签')),
      );
      return;
    }

    if (_templateContent != null &&
        _contentController.text.trim() == _templateContent!.trim()) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('提示'),
          content: const Text('您尚未修改分类模板内容，确定要发布吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定发布'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    setState(() => _isSubmitting = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final topicId = await service.createTopic(
        title: _titleController.text.trim(),
        raw: _contentController.text,
        categoryId: _selectedCategory!.id,
        tags: _selectedTags.isNotEmpty ? _selectedTags : null,
      );

      // 发送成功后删除草稿
      await _draftController.deleteDraft();

      if (!mounted) return;
      Navigator.of(context).pop(topicId);
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// 构建草稿保存状态指示器
  Widget _buildDraftStatusIndicator(DraftSaveStatus status, ThemeData theme) {
    switch (status) {
      case DraftSaveStatus.idle:
      case DraftSaveStatus.pending:
        return const SizedBox.shrink();
      case DraftSaveStatus.saving:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: theme.colorScheme.outline,
          ),
        );
      case DraftSaveStatus.saved:
        return Icon(
          Icons.cloud_done_outlined,
          size: 18,
          color: theme.colorScheme.outline,
        );
      case DraftSaveStatus.error:
        return Icon(
          Icons.cloud_off_outlined,
          size: 18,
          color: theme.colorScheme.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);
    final canTagTopics = ref.watch(canTagTopicsProvider).value ?? false;
    final theme = Theme.of(context);

    // 获取站点配置的最小长度
    final minTitleLength = ref.watch(minTopicTitleLengthProvider).value ?? 15;
    final minContentLength = ref.watch(minFirstPostLengthProvider).value ?? 20;

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
          title: const Text('创建话题'),
          scrolledUnderElevation: 0,
          actions: [
            // 草稿保存状态指示器
            ValueListenableBuilder<DraftSaveStatus>(
              valueListenable: _draftController.statusNotifier,
              builder: (context, status, _) {
                return _buildDraftStatusIndicator(status, theme);
              },
            ),
            // 舍弃按钮
            TextButton(
              onPressed: _isSubmitting ? null : _discardDraft,
              child: const Text('舍弃'),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton(
                onPressed: _isSubmitting ? null : _submit,
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
                    : const Text('发布'),
              ),
            ),
          ],
        ),
        body: categoriesAsync.when(
          data: (categories) {
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
                            // 标题输入
                            TextFormField(
                              controller: _titleController,
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
                              ),
                              maxLines: null,
                              maxLength: 200,
                              buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) return '请输入标题';
                                if (value.trim().length < minTitleLength) return '标题至少需要 $minTitleLength 个字符';
                                return null;
                              },
                              onTap: () {
                                _toolbarKey.currentState?.closeEmojiPanel();
                              },
                            ),

                            const SizedBox(height: 16),

                            // 元数据区域 (分类 + 标签)
                            Column(
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
                                      onTagsChanged: _onTagsChanged,
                                    ),
                                    loading: () => const SizedBox.shrink(),
                                    error: (e, s) => const SizedBox.shrink(),
                                  ),
                                ],
                              ],
                            ),

                            const SizedBox(height: 20),
                            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                            const SizedBox(height: 20),

                            // 内容区域
                            MentionAutocomplete(
                              controller: _contentController,
                              focusNode: _contentFocusNode,
                              dataSource: (term) => ref.read(discourseServiceProvider).searchUsers(
                                term: term,
                                categoryId: _selectedCategory?.id,
                                includeGroups: true,
                              ),
                              child: TextFormField(
                                controller: _contentController,
                                focusNode: _contentFocusNode,
                                maxLines: null,
                                minLines: 12,
                                decoration: InputDecoration(
                                  hintText: '正文内容 (支持 Markdown)...',
                                  border: InputBorder.none,
                                  helperText: _templateContent != null ? '已填充分类模板' : null,
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
          },
          loading: () => const Center(child: LoadingSpinner()),
          error: (err, stack) => Center(child: Text('加载分类失败: $err')),
        ),
      ),
    );
  }
}
