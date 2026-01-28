import 'package:flutter/material.dart';
import '../discourse_html_content_widget.dart';
import '../../../../models/topic.dart';
import 'html_chunk.dart';
import 'html_chunk_cache.dart';

/// 分块 HTML 内容组件
///
/// 将长 HTML 内容分割为多个块，支持懒加载渲染
/// 当 HTML 长度超过阈值时自动启用分块模式
class ChunkedHtmlContent extends StatefulWidget {
  final String html;
  final TextStyle? textStyle;

  /// 内部链接点击回调 (linux.do 话题链接)
  final void Function(int topicId, String? topicSlug)? onInternalLinkTap;

  /// 链接点击统计数据
  final List<LinkCount>? linkCounts;

  /// 是否启用分块渲染（默认根据内容长度自动判断）
  final bool? enableChunking;

  /// 分块阈值（HTML 长度超过此值时启用分块）
  static const int chunkThreshold = 5000;

  /// 被提及用户列表（含状态 emoji）
  final List<MentionedUser>? mentionedUsers;

  /// Post 对象（用于投票数据和链接追踪）
  final Post? post;

  /// 话题 ID（用于链接点击追踪）
  final int? topicId;

  /// 预加载 HTML 分块（在获取帖子数据后调用）
  static void preload(String html) {
    if (html.length > chunkThreshold) {
      HtmlChunkCache.instance.preload(html);
    }
  }

  /// 批量预加载
  static void preloadAll(List<String> htmlList) {
    for (final html in htmlList) {
      preload(html);
    }
  }

  const ChunkedHtmlContent({
    super.key,
    required this.html,
    this.textStyle,
    this.onInternalLinkTap,
    this.linkCounts,
    this.enableChunking,
    this.mentionedUsers,
    this.post,
    this.topicId,
  });

  @override
  State<ChunkedHtmlContent> createState() => _ChunkedHtmlContentState();
}

class _ChunkedHtmlContentState extends State<ChunkedHtmlContent> {
  List<HtmlChunk>? _chunks;
  late bool _useChunking;
  late List<String> _galleryImages;

  @override
  void initState() {
    super.initState();
    _initChunks();
  }

  @override
  void didUpdateWidget(ChunkedHtmlContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.enableChunking != widget.enableChunking) {
      _initChunks();
    }
  }

  void _initChunks() {
    // 先从完整 HTML 提取所有画廊图片
    _galleryImages = _extractGalleryImages(widget.html);

    _useChunking = widget.enableChunking ??
        (widget.html.length > ChunkedHtmlContent.chunkThreshold);

    if (_useChunking) {
      // 优先从缓存获取
      final cached = HtmlChunkCache.instance.get(widget.html);
      if (cached != null) {
        _chunks = cached;
        if (_chunks!.length <= 1) {
          _useChunking = false;
        }
      } else {
        // 缓存未命中，同步解析（短内容）或异步解析（长内容）
        _chunks = HtmlChunkCache.instance.parseSync(widget.html);
        if (_chunks!.length <= 1) {
          _useChunking = false;
        }
      }
    } else {
      _chunks = null;
    }
  }

  /// 提取画廊图片列表（与 DiscourseHtmlContent 保持一致）
  List<String> _extractGalleryImages(String html) {
    final List<String> galleryImages = [];
    final imgTagRegExp = RegExp(r'<img[^>]+>', caseSensitive: false);
    final srcRegExp = RegExp(r'''src\s*=\s*["']?([^"'\s>]+)["']?''', caseSensitive: false);
    // 排除规则：emoji、头像、网站图标、favicon 等
    final excludeClassRegExp = RegExp(
      r'''class\s*=\s*["'][^"']*(emoji|avatar|site-icon|favicon)[^"']*["']''',
      caseSensitive: false,
    );

    final matches = imgTagRegExp.allMatches(html);
    for (final match in matches) {
      final imgTag = match.group(0) ?? "";

      // 排除特定 class 的图片
      if (excludeClassRegExp.hasMatch(imgTag)) continue;

      final srcMatch = srcRegExp.firstMatch(imgTag);
      final src = srcMatch?.group(1);
      if (src == null) continue;

      // 排除 favicon 路径
      if (src.contains('/favicon') || src.contains('favicon.')) continue;

      galleryImages.add(src);
    }
    return galleryImages;
  }

  @override
  Widget build(BuildContext context) {
    // 不启用分块时，使用原有组件
    if (!_useChunking || _chunks == null) {
      return DiscourseHtmlContent(
        html: widget.html,
        textStyle: widget.textStyle,
        onInternalLinkTap: widget.onInternalLinkTap,
        linkCounts: widget.linkCounts,
        mentionedUsers: widget.mentionedUsers,
        post: widget.post,
        topicId: widget.topicId,
      );
    }

    // 分块渲染，块之间添加间距
    final children = <Widget>[];
    for (int i = 0; i < _chunks!.length; i++) {
      final chunk = _chunks![i];
      children.add(_ChunkWidget(
        key: ValueKey('chunk-${chunk.index}'),
        chunk: chunk,
        textStyle: widget.textStyle,
        onInternalLinkTap: widget.onInternalLinkTap,
        linkCounts: widget.linkCounts,
        galleryImages: _galleryImages,
        mentionedUsers: widget.mentionedUsers,
        fullHtml: widget.html,
        post: widget.post,
        topicId: widget.topicId,
      ));
      // 块之间添加间距（最后一个块除外）
      if (i < _chunks!.length - 1) {
        children.add(const SizedBox(height: 12));
      }
    }

    // 使用 SelectionArea 支持跨块选择
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// 单个块的渲染 Widget
class _ChunkWidget extends StatelessWidget {
  final HtmlChunk chunk;
  final TextStyle? textStyle;
  final void Function(int topicId, String? topicSlug)? onInternalLinkTap;
  final List<LinkCount>? linkCounts;
  final List<String> galleryImages;
  final List<MentionedUser>? mentionedUsers;
  final String fullHtml;
  final Post? post;
  final int? topicId;

  const _ChunkWidget({
    super.key,
    required this.chunk,
    this.textStyle,
    this.onInternalLinkTap,
    this.linkCounts,
    required this.galleryImages,
    this.mentionedUsers,
    required this.fullHtml,
    this.post,
    this.topicId,
  });

  @override
  Widget build(BuildContext context) {
    // 使用 RepaintBoundary 隔离重绘
    return RepaintBoundary(
      child: DiscourseHtmlContent(
        html: chunk.html,
        textStyle: textStyle,
        onInternalLinkTap: onInternalLinkTap,
        linkCounts: linkCounts,
        galleryImages: galleryImages,
        enableSelectionArea: false, // 由外层 SelectionArea 统一控制
        mentionedUsers: mentionedUsers,
        fullHtml: fullHtml,
        post: post,
        topicId: topicId,
      ),
    );
  }
}
