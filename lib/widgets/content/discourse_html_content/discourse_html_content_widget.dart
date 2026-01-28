import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../models/topic.dart';
import '../../../pages/user_profile_page.dart';
import '../../../pages/webview_page.dart';
import '../../../services/discourse_service.dart';
import '../../../services/emoji_handler.dart';
import '../../../utils/url_helper.dart';
import 'discourse_widget_factory.dart';
import 'builders/quote_card_builder.dart';
import 'builders/onebox_card_builder.dart';
import 'builders/blockquote_builder.dart';
import 'builders/code_block_builder.dart';
import 'builders/spoiler_builder.dart';
import 'builders/table_builder.dart';
import 'builders/details_builder.dart';
import 'builders/footnote_builder.dart';
import 'builders/poll_builder.dart';

/// Discourse HTML 内容渲染 Widget
/// 封装了所有自定义渲染逻辑
class DiscourseHtmlContent extends StatefulWidget {
  final String html;
  final TextStyle? textStyle;
  final bool compact; // 紧凑模式：移除段落边距
  /// 内部链接点击回调 (linux.do 话题链接)
  final void Function(int topicId, String? topicSlug)? onInternalLinkTap;
  /// 链接点击统计数据
  final List<LinkCount>? linkCounts;
  /// 外部传入的画廊图片列表（用于分块渲染时共享完整画廊）
  final List<String>? galleryImages;
  /// 是否启用选择区域（分块渲染时由外层统一控制）
  final bool enableSelectionArea;
  /// 被提及用户列表（含状态 emoji）
  final List<MentionedUser>? mentionedUsers;
  /// 完整 HTML（用于脚注匹配，分块渲染时传递）
  final String? fullHtml;
  /// Post 对象（用于投票数据）
  final Post? post;
  /// 话题 ID（用于链接点击追踪）
  final int? topicId;

  const DiscourseHtmlContent({
    super.key,
    required this.html,
    this.textStyle,
    this.compact = false,
    this.onInternalLinkTap,
    this.linkCounts,
    this.galleryImages,
    this.enableSelectionArea = true,
    this.mentionedUsers,
    this.fullHtml,
    this.post,
    this.topicId,
  });

  @override
  State<DiscourseHtmlContent> createState() => _DiscourseHtmlContentState();
}

class _DiscourseHtmlContentState extends State<DiscourseHtmlContent> {
  late final DiscourseWidgetFactory _widgetFactory;
  late final List<String> _galleryImages;
  int _rebuildKey = 0;

  @override
  void initState() {
    super.initState();
    // 优先使用外部传入的画廊图片列表，否则从自己的 html 提取
    _galleryImages = widget.galleryImages ?? _extractGalleryImages(widget.html);
    _widgetFactory = DiscourseWidgetFactory(
      context: context,
      galleryImages: _galleryImages,
    );
  }

  /// 提取画廊图片列表
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

  /// 预处理 HTML：在链接后注入点击次数，在 mention 链接后注入用户状态 emoji
  String _preprocessHtml(String html) {
    var processedHtml = html;
    
    // 1. 注入用户状态 emoji 到 mention 链接
    if (widget.mentionedUsers != null && widget.mentionedUsers!.isNotEmpty) {
      for (final user in widget.mentionedUsers!) {
        if (user.statusEmoji != null) {
          final emojiUrl = EmojiHandler().getEmojiUrl(user.statusEmoji!);
          if (emojiUrl != null) {
            // 查找该用户的 mention 链接，在 </a> 前注入 emoji 图片
            final escapedUsername = RegExp.escape(user.username);
            final pattern = RegExp(
              '(<a[^>]*class="[^"]*mention[^"]*"[^>]*href="[^"]*\\/u\\/$escapedUsername"[^>]*>)(@[^<]*)(</a>)',
              caseSensitive: false,
            );
            processedHtml = processedHtml.replaceAllMapped(pattern, (match) {
              final openTag = match.group(1)!;
              final content = match.group(2)!;
              final closeTag = match.group(3)!;
              return '$openTag$content<img src="$emojiUrl" class="emoji mention-status" style="width:14px;height:14px;vertical-align:middle;margin-left:2px">$closeTag';
            });
          }
        }
      }
    }
    
    // 2. 注入链接点击次数
    if (widget.linkCounts != null && widget.linkCounts!.isNotEmpty) {
      for (final lc in widget.linkCounts!) {
        if (lc.clicks > 0) {
          final clicksText = _formatClicks(lc.clicks);
          final escapedUrl = RegExp.escape(lc.url);
          final pattern = RegExp(
            '(<a[^>]*href=["\']$escapedUrl["\'][^>]*>)(.*?)(</a>)',
            caseSensitive: false,
          );
          processedHtml = processedHtml.replaceAllMapped(pattern, (match) {
            final openTag = match.group(1)!;
            final content = match.group(2)!;
            final closeTag = match.group(3)!;
            return '$openTag$content<span class="link-click-count" style="color:#888;font-size:11px"> $clicksText</span>$closeTag';
          });
        }
      }
    }
    
    return processedHtml;
  }

  /// 格式化点击次数 (如: 1234 -> 1.2k)
  String _formatClicks(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }

  /// 追踪链接点击
  /// 仅当有 topicId 和 post 时才追踪
  void _trackClick(String url) {
    if (widget.topicId == null || widget.post == null) return;

    // 不追踪以下类型的链接：
    // 1. 用户链接 (/u/username) - 相当于 mention
    if (RegExp(r'(?:linux\.do)?/u/[^/?#]+').hasMatch(url)) return;
    // 2. 附件/上传链接
    if (url.contains('/uploads/')) return;
    // 3. Email 链接
    if (url.startsWith('mailto:')) return;
    // 4. 锚点链接
    if (url.startsWith('#')) return;

    DiscourseService().trackClick(
      url: url,
      postId: widget.post!.id,
      topicId: widget.topicId!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkColor = theme.colorScheme.primary.toARGB32().toRadixString(16).substring(2);
    final processedHtml = _preprocessHtml(widget.html);

    final htmlWidget = HtmlWidget(
      key: ValueKey(_rebuildKey),
      processedHtml,
      textStyle: widget.textStyle,
      factoryBuilder: () => _widgetFactory,
      customWidgetBuilder: (element) => _buildCustomWidget(context, element),
      customStylesBuilder: (element) {
        // 修复 Emoji 垂直居中问题
        if (element.classes.contains('emoji')) {
           return {'vertical-align': 'middle'};
        }

        // 紧凑模式下移除段落边距
        if (widget.compact && element.localName == 'p') {
          return {'margin': '0'};
        }
        // 用户提及链接样式 (class="mention")
        if (element.localName == 'a' && element.classes.contains('mention')) {
          final isDark = theme.brightness == Brightness.dark;
          final bgColor = isDark ? '3a3d47' : 'e8ebef';
          return {
            'color': '#$linkColor',
            'text-decoration': 'none',
            'background-color': '#$bgColor',
            'padding': '0.2em 0.34em',
            'border-radius': '0.6em',
            'font-size': '0.93em',
            'font-weight': 'normal',
            'line-height': '1',
          };
        }
        // 优化链接样式
        if (element.localName == 'a') {
          return {
            'color': '#$linkColor',
            'text-decoration': 'none',
          };
        }
        // 内联代码样式
        if (element.localName == 'code' && element.parent?.localName != 'pre') {
          final isDark = theme.brightness == Brightness.dark;
          final bgColor = isDark ? '3a3a3a' : 'e8e8e8';
          final textColor = isDark ? 'b0b0b0' : '666666';
          return {
            'background-color': '#$bgColor',
            'color': '#$textColor',
            'padding': '2px 6px',
            'border-radius': '4px',
            'font-family': 'monospace',
            'font-size': '0.9em',
          };
        }
        return {};
      },
      onTapUrl: (url) async {
        // 追踪链接点击（fire-and-forget）
        _trackClick(url);

        // 1. 识别用户链接 /u/username 或 linux.do/u/username
        final userMatch = RegExp(r'(?:linux\.do)?/u/([^/?#]+)').firstMatch(url);
        if (userMatch != null) {
          final username = userMatch.group(1)!;
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => UserProfilePage(username: username)),
          );
          return true;
        }

        // 2. 解析 linux.do 内部话题链接
        // 支持格式: https://linux.do/t/topic/123, /t/topic/123 或 https://linux.do/t/some-slug/123
        final topicMatch = RegExp(r'(?:linux\.do)?/t/(?:[^/]+/)?(\d+)').firstMatch(url);
        if (topicMatch != null && widget.onInternalLinkTap != null) {
          final topicId = int.parse(topicMatch.group(1)!);
          // 尝试提取 slug (如果有的话)
          final slugMatch = RegExp(r'(?:linux\.do)?/t/([^/]+)/\d+').firstMatch(url);
          final slug = (slugMatch != null && slugMatch.group(1) != 'topic')
              ? slugMatch.group(1)
              : null;
          widget.onInternalLinkTap!(topicId, slug);
          return true;
        }

        // 3. 下载附件链接：识别 /uploads/ 路径
        if (url.contains('/uploads/')) {
          final fullUrl = UrlHelper.resolveUrl(url);
          final uri = Uri.tryParse(fullUrl);
          if (uri != null) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
          return true;
        }

        // 4. 其他 linux.do 内部链接：使用内置浏览器
        if (url.contains('linux.do') || url.startsWith('/')) {
          final fullUrl = UrlHelper.resolveUrl(url);
          WebViewPage.open(context, fullUrl);
          return true;
        }

        // 5. Email 链接：打开邮件客户端
        if (url.startsWith('mailto:')) {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
          return true;
        }

        // 6. 外部链接：在浏览器中打开
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        return true;
      },
    );

    // 根据参数决定是否包裹 SelectionArea
    if (widget.enableSelectionArea) {
      return SelectionArea(child: htmlWidget);
    }
    return htmlWidget;
  }

  Widget? _buildCustomWidget(BuildContext context, dynamic element) {
    final theme = Theme.of(context);

    // 屏蔽 Discourse Lightbox 的元数据区域和图标
    if (element.classes.contains('meta') ||
        element.classes.contains('d-icon') ||
        element.localName == 'svg') {
      return const SizedBox.shrink();
    }

    // HTML 构建器：用于嵌套渲染
    Widget htmlBuilder(String html, TextStyle? textStyle) {
      return DiscourseHtmlContent(
        html: html,
        compact: true,
        textStyle: textStyle,
        galleryImages: _galleryImages,
        onInternalLinkTap: widget.onInternalLinkTap,
        post: widget.post,
        topicId: widget.topicId,
        linkCounts: widget.linkCounts,
        mentionedUsers: widget.mentionedUsers,
        enableSelectionArea: widget.enableSelectionArea,
      );
    }

    // 处理投票块 (div.poll)
    if (element.localName == 'div' && element.classes.contains('poll')) {
      if (widget.post != null) {
        return buildPoll(
          context: context,
          theme: theme,
          element: element,
          post: widget.post!,
        );
      }
      return const SizedBox.shrink();
    }

    // 处理 table：自定义渲染避免布局问题
    if (element.localName == 'table') {
      return buildTable(
        context: context,
        theme: theme,
        element: element,
        galleryImages: _galleryImages,
      );
    }

    // 处理 Discourse 回复引用块 (aside.quote)
    if (element.localName == 'aside' && element.classes.contains('quote')) {
      return buildQuoteCard(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理 Discourse 链接卡片 (aside.onebox)
    if (element.localName == 'aside' && element.classes.contains('onebox')) {
      return buildOneboxCard(
        context: context,
        theme: theme,
        element: element,
        linkCounts: widget.linkCounts,
      );
    }

    // 处理普通引用块 (可能是 Obsidian Callout)
    if (element.localName == 'blockquote') {
      return buildBlockquote(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理代码块
    if (element.localName == 'pre') {
      final codeElements = element.getElementsByTagName('code');
      if (codeElements.isNotEmpty) {
        return buildCodeBlock(
          context: context,
          theme: theme,
          codeElement: codeElements.first,
        );
      }
    }

    // 处理 Spoiler 隐藏内容 (class="spoiler" 或 class="spoiled")
    if (element.classes.contains('spoiler') || element.classes.contains('spoiled')) {
      final spoilerWidget = buildSpoiler(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
        textStyle: widget.textStyle,
        onStateChanged: () => setState(() => _rebuildKey++),
      );
      if (spoilerWidget != null) {
        return InlineCustomWidget(child: spoilerWidget);
      }
      // 返回 null 让默认渲染器处理（已显示状态，可选中）
    }

    // 处理 details 折叠块
    if (element.localName == 'details') {
      return buildDetails(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理脚注引用 (sup.footnote-ref)
    if (element.localName == 'sup' && element.classes.contains('footnote-ref')) {
      final footnoteRef = buildFootnoteRef(
        context: context,
        theme: theme,
        element: element,
        fullHtml: widget.fullHtml ?? widget.html,
        galleryImages: _galleryImages,
      );
      return InlineCustomWidget(child: footnoteRef);
    }

    // 处理脚注分隔线 (.footnotes-sep) - 隐藏
    if (element.localName == 'hr' && element.classes.contains('footnotes-sep')) {
      return buildFootnotesSep();
    }

    // 处理脚注列表 (section.footnotes / ol.footnotes-list)
    if (element.localName == 'section' && element.classes.contains('footnotes')) {
      return buildFootnotesList(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }
    if (element.localName == 'ol' && element.classes.contains('footnotes-list')) {
      return buildFootnotesList(
        context: context,
        theme: theme,
        element: element,
        htmlBuilder: htmlBuilder,
      );
    }

    // 处理分割线
    if (element.localName == 'hr') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Container(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      );
    }

    return null;
  }
}
