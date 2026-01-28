import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../../pages/image_viewer_page.dart';
import '../../../../services/highlighter_service.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../lazy_load_scope.dart';

/// 构建代码块
Widget buildCodeBlock({
  required BuildContext context,
  required ThemeData theme,
  required dynamic codeElement,
}) {
  final className = codeElement.className as String;
  // 检测 mermaid 代码块
  if (className.contains('lang-mermaid')) {
    return _MermaidWidget(codeElement: codeElement);
  }
  return _CodeBlockWidget(codeElement: codeElement);
}

class _CodeBlockWidget extends StatefulWidget {
  final dynamic codeElement;
  const _CodeBlockWidget({required this.codeElement});

  @override
  State<_CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<_CodeBlockWidget> {
  final _vController = ScrollController();
  final _hController = ScrollController();
  final _lineNumberVController = ScrollController();
  List<HighlightToken>? _tokens;

  @override
  void initState() {
    super.initState();
    _loadHighlight();
    // 同步行号和代码的垂直滚动
    _vController.addListener(_syncLineNumberScroll);
  }

  @override
  void dispose() {
    _vController.removeListener(_syncLineNumberScroll);
    _vController.dispose();
    _hController.dispose();
    _lineNumberVController.dispose();
    super.dispose();
  }

  void _syncLineNumberScroll() {
    if (_lineNumberVController.hasClients) {
      _lineNumberVController.jumpTo(_vController.offset);
    }
  }

  Future<void> _loadHighlight() async {
    final text = widget.codeElement.text as String;
    final className = widget.codeElement.className as String;
    String? language;
    if (className.isNotEmpty) {
      final match = RegExp(r'lang-(\w+)').firstMatch(className);
      if (match != null) {
        language = match.group(1);
      }
    }
    try {
      final tokens = await HighlighterService.instance.highlightAsync(
        text,
        language: language,
      );
      if (mounted) setState(() => _tokens = tokens);
    } catch (e) {
      // 高亮失败
    }
  }

  @override
  Widget build(BuildContext context) {
    try {
      final text = widget.codeElement.text as String;
      final className = widget.codeElement.className as String;
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;

      String displayLanguage = 'TEXT';
      if (className.isNotEmpty) {
        final match = RegExp(r'lang-(\w+)').firstMatch(className);
        if (match != null) {
          displayLanguage = match.group(1)!.toUpperCase();
        }
      }

      final bgColor = isDark ? const Color(0xff282a36) : const Color(0xfff6f8fa);
      final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.3);
      final thumbColor = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.15);
      final lineNumberColor = isDark
          ? Colors.white.withValues(alpha: 0.35)
          : Colors.black.withValues(alpha: 0.35);

      // 使用预加载的字体样式，避免字体加载导致高度跳动
      final baseStyle = HighlighterService.instance.firaCodeStyle;
      final lines = text.split('\n');
      final lineCount = lines.length;
      final padWidth = lineCount.toString().length;
      final lineNumberWidth = padWidth * 9.0 + 24;

      // 预估代码区域高度：行高(13*1.5=19.5) * 行数 + padding(24)
      const lineHeight = 13.0 * 1.5;
      const verticalPadding = 24.0; // 12 + 12
      final estimatedHeight = (lineCount * lineHeight + verticalPadding).clamp(0.0, 400.0);

      // 构建代码 TextSpan
      final codeSpan = _tokens != null
          ? HighlighterService.instance.tokensToSpan(
              _tokens!,
              isDark: isDark,
              baseStyle: baseStyle,
            )
          : TextSpan(text: text, style: baseStyle);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: bgColor,
          border: Border.all(color: borderColor),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 头部工具栏
              Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.03),
                  border: Border(bottom: BorderSide(color: borderColor)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      displayLanguage,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制代码'), duration: Duration(seconds: 1)),
                        );
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.copy_rounded,
                              size: 14,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '复制',
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 代码区域 - 使用预估高度避免加载时跳动
              SizedBox(
                height: estimatedHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 固定的行号列
                    Container(
                      width: lineNumberWidth,
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(color: borderColor),
                        ),
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.02)
                            : Colors.black.withValues(alpha: 0.02),
                      ),
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                        child: SingleChildScrollView(
                          controller: _lineNumberVController,
                          physics: const NeverScrollableScrollPhysics(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                            child: Text(
                              List.generate(lineCount, (i) => (i + 1).toString().padLeft(padWidth)).join('\n'),
                              style: baseStyle.copyWith(color: lineNumberColor),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 可滚动的代码内容
                    Expanded(
                      child: RawScrollbar(
                        controller: _vController,
                        thumbVisibility: true,
                        thickness: 4,
                        radius: const Radius.circular(2),
                        padding: const EdgeInsets.only(right: 2, top: 2, bottom: 2),
                        thumbColor: thumbColor,
                        child: SingleChildScrollView(
                          controller: _vController,
                          scrollDirection: Axis.vertical,
                          child: RawScrollbar(
                            controller: _hController,
                            thumbVisibility: true,
                            thickness: 4,
                            padding: const EdgeInsets.only(left: 2, right: 2, bottom: 4),
                            radius: const Radius.circular(2),
                            thumbColor: thumbColor,
                            child: SingleChildScrollView(
                              controller: _hController,
                              scrollDirection: Axis.horizontal,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText.rich(codeSpan),
                              ),
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
    } catch (e, stackTrace) {
      debugPrint('=== Code Block Error ===\nError: $e\nStackTrace: $stackTrace');
      final theme = Theme.of(context);
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('代码块渲染失败: $e', style: TextStyle(color: theme.colorScheme.onErrorContainer)),
      );
    }
  }
}

/// Mermaid 图表组件 - 使用 mermaid.ink 服务端渲染
class _MermaidWidget extends StatefulWidget {
  final dynamic codeElement;
  const _MermaidWidget({required this.codeElement});

  @override
  State<_MermaidWidget> createState() => _MermaidWidgetState();
}

class _MermaidWidgetState extends State<_MermaidWidget> with SingleTickerProviderStateMixin {
  bool _showCode = false;
  bool _shouldLoad = false;
  bool _initialized = false;
  int _retryCount = 0;
  final _vController = ScrollController();
  final _hController = ScrollController();
  AnimationController? _shimmerController;

  String get _cacheKey {
    final text = widget.codeElement.text as String;
    return 'mermaid-${text.hashCode}';
  }

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      if (LazyLoadScope.isLoaded(context, _cacheKey)) {
        _shouldLoad = true;
        _shimmerController?.stop();
      }
    }
  }

  @override
  void dispose() {
    _vController.dispose();
    _hController.dispose();
    _shimmerController?.dispose();
    super.dispose();
  }

  void _triggerLoad() {
    if (!_shouldLoad) {
      LazyLoadScope.markLoaded(context, _cacheKey);
      setState(() => _shouldLoad = true);
    }
  }

  String _buildMermaidInkUrl(String code, bool isDark, {int? width}) {
    final encoded = base64Url.encode(utf8.encode(code));
    final theme = isDark ? 'dark' : 'default';
    final bgColor = isDark ? '282a36' : 'f6f8fa';
    var url = 'https://mermaid.ink/img/$encoded?theme=$theme&bgColor=$bgColor';
    if (width != null) url += '&width=$width';
    return url;
  }

  void _retry() {
    setState(() => _retryCount++);
  }

  Widget _buildShimmerPlaceholder(ThemeData theme, {bool withMargin = true}) {
    final controller = _shimmerController;
    if (controller == null) return const SizedBox(height: 100);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Container(
          height: 100,
          margin: withMargin ? const EdgeInsets.all(12) : null,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * controller.value, 0),
              end: Alignment(-0.5 + 2.0 * controller.value, 0),
              colors: [
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.codeElement.text as String;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xff282a36) : const Color(0xfff6f8fa);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.3);
    final thumbColor = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.15);
    final imageUrl = _buildMermaidInkUrl(text, isDark);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: bgColor,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 工具栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: borderColor))),
            child: Row(
              children: [
                InkWell(
                  onTap: () => setState(() => _showCode = !_showCode),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_showCode ? Icons.auto_graph : Icons.code, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                        const SizedBox(width: 4),
                        Text(_showCode ? '图表' : '代码', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制代码'), duration: Duration(seconds: 1)));
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.copy, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                  ),
                ),
              ],
            ),
          ),
          // 内容区域
          ClipRRect(
            borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
            child: _showCode
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: RawScrollbar(
                      controller: _vController,
                      thumbVisibility: true,
                      thickness: 4,
                      radius: const Radius.circular(2),
                      thumbColor: thumbColor,
                      child: SingleChildScrollView(
                        controller: _vController,
                        child: RawScrollbar(
                          controller: _hController,
                          thumbVisibility: true,
                          thickness: 4,
                          thumbColor: thumbColor,
                          child: SingleChildScrollView(
                            controller: _hController,
                            scrollDirection: Axis.horizontal,
                            child: HighlighterService.instance.buildHighlightView(
                              text,
                              language: 'mermaid',
                              isDark: isDark,
                              backgroundColor: Colors.transparent,
                              padding: const EdgeInsets.all(12),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : _shouldLoad
                    ? GestureDetector(
                        onTap: () {
                          final hdUrl = _buildMermaidInkUrl(text, isDark, width: 2000);
                          ImageViewerPage.open(context, hdUrl);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: CachedNetworkImage(
                            key: ValueKey('$imageUrl-$_retryCount'),
                            imageUrl: imageUrl,
                            cacheManager: ExternalImageCacheManager(),
                            fit: BoxFit.contain,
                            placeholder: (context, url) => _buildShimmerPlaceholder(theme, withMargin: false),
                            errorWidget: (context, url, error) => Container(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                                  const SizedBox(height: 8),
                                  Text('图表加载失败', style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    onPressed: _retry,
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('重试'),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : VisibilityDetector(
                        key: Key('mermaid-$_cacheKey'),
                        onVisibilityChanged: (info) {
                          if (!_shouldLoad && info.visibleFraction > 0.01) {
                            _triggerLoad();
                          }
                        },
                        child: _buildShimmerPlaceholder(theme),
                      ),
          ),
        ],
      ),
    );
  }
}
