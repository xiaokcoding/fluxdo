import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../pages/image_viewer_page.dart';
import '../../../services/discourse_cache_manager.dart';
import '../../../services/discourse_service.dart';
import 'lazy_image.dart';

/// 自定义 WidgetFactory，仅用于接管图片渲染
class DiscourseWidgetFactory extends WidgetFactory {
  final BuildContext context;
  final List<String> galleryImages;

  // 仅缓存 upload:// 短链接的解析结果
  static final Map<String, String?> _uploadUrlCache = {};

  DiscourseWidgetFactory({
    required this.context,
    this.galleryImages = const [],
  });

  @override
  Widget? buildImage(BuildTree tree, ImageMetadata data) {
    final url = data.sources.firstOrNull?.url;
    if (url == null) return super.buildImage(tree, data);

    // 尝试获取宽高信息
    final double? width = data.sources.firstOrNull?.width;
    final double? height = data.sources.firstOrNull?.height;

    // 检查是否是显式的 emoji class
    final bool isEmoji = tree.element.classes.contains('emoji');

    // 普通 URL：直接构建 widget，无需 FutureBuilder
    if (!url.startsWith('upload://')) {
      return _buildImageWidget(url, url, width, height, isEmoji);
    }

    // upload:// 短链接：检查缓存
    if (_uploadUrlCache.containsKey(url)) {
      final resolvedUrl = _uploadUrlCache[url];
      if (resolvedUrl != null) {
        return _buildImageWidget(resolvedUrl, url, width, height, isEmoji);
      }
      // 解析失败的 URL，显示错误图标
      return Icon(
        Icons.broken_image,
        color: Theme.of(context).colorScheme.outline,
        size: 24,
      );
    }

    // upload:// 短链接首次加载：使用 FutureBuilder 解析
    return FutureBuilder<String?>( 
      future: _resolveUploadUrl(url),
      builder: (context, snapshot) {
        // 缓存解析结果
        if (snapshot.connectionState == ConnectionState.done) {
          _uploadUrlCache[url] = snapshot.data;
        }

        // 解析失败
        if (snapshot.connectionState == ConnectionState.done && snapshot.data == null) {
          return Icon(
            Icons.broken_image,
            color: Theme.of(context).colorScheme.outline,
            size: 24,
          );
        }

        return _buildImageWidget(snapshot.data, url, width, height, isEmoji);
      },
    );
  }

  /// 构建图片 widget（从缓存或 FutureBuilder 调用）
  Widget _buildImageWidget(String? resolvedUrl, String originalUrl, double? width, double? height, bool isEmoji) {
    // 检查是否是 SVG（处理带查询参数的 URL）
    final isSvg = _isSvgUrl(resolvedUrl) || _isSvgUrl(originalUrl);

    if (isSvg && resolvedUrl != null) {
      return _buildSvgWidget(resolvedUrl, width, height, isEmoji);
    }

    // 使用自定义的鉴权 ImageProvider（即使在 waiting 状态也可以构建）
    final imageProvider = resolvedUrl != null
        ? discourseImageProvider(resolvedUrl)
        : null;

    // 检查是否在画廊列表中
    final int galleryIndex = resolvedUrl != null ? galleryImages.indexOf(resolvedUrl) : -1;
    final bool isGalleryImage = galleryIndex != -1;

    // 生成唯一 Tag
    // 画廊图片使用确定性 tag（基于画廊内容和索引），以便切换图片后 Hero 动画能正确返回
    // 非画廊图片使用 UniqueKey 避免冲突
    final String heroTag;
    if (isGalleryImage) {
      final int galleryHash = Object.hashAll(galleryImages);
      heroTag = "gallery_${galleryHash}_$galleryIndex";
    } else {
      heroTag = "${resolvedUrl ?? originalUrl}_${UniqueKey().toString()}";
    }

    return Builder(
      builder: (context) {
        // 计算合适的 Emoji 尺寸
        final double emojiSize = DefaultTextStyle.of(context).style.fontSize ?? 16.0;
        final double displaySize = emojiSize * 1.2;

        // 如果不是画廊图片（通常是 Emoji）
        if (!isGalleryImage || isEmoji) {
           Widget emojiWidget = imageProvider != null
               ? Image(
                   image: imageProvider,
                   fit: BoxFit.contain,
                   width: isEmoji ? displaySize : width,
                   height: isEmoji ? displaySize : height,
                   loadingBuilder: (context, child, loadingProgress) {
                     if (loadingProgress == null) return child;
                     return SizedBox(
                       width: isEmoji ? displaySize : width ?? 24,
                       height: isEmoji ? displaySize : height ?? 24,
                       child: Center(
                         child: SizedBox(
                           width: 12,
                           height: 12,
                           child: CircularProgressIndicator(
                             strokeWidth: 1.5,
                             value: loadingProgress.expectedTotalBytes != null
                                 ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                                 : null,
                           ),
                         ),
                       ),
                     );
                   },
                   errorBuilder: (context, error, stackTrace) {
                     return Icon(
                       Icons.broken_image,
                       color: Theme.of(context).colorScheme.outline,
                       size: isEmoji ? displaySize : 24,
                     );
                   },
                 )
               : SizedBox(
                   width: isEmoji ? displaySize : width ?? 24,
                   height: isEmoji ? displaySize : height ?? 24,
                   child: const Center(
                     child: SizedBox(
                       width: 12,
                       height: 12,
                       child: CircularProgressIndicator(strokeWidth: 1.5),
                     ),
                   ),
                 );

           if (isEmoji) {
             return Container(
               margin: const EdgeInsets.symmetric(horizontal: 2.0),
               child: emojiWidget,
             );
           }
           return emojiWidget;
        }

        // 画廊图片处理
        Widget buildGalleryImage() {
          if (imageProvider == null) {
            // URL 解析中，显示占位符
            final screenWidth = MediaQuery.of(context).size.width;
            final double displayWidth = screenWidth - 32;
            final double displayHeight = width != null && height != null && height > 0
                ? displayWidth * (height / width)
                : 200.0;

            return Container(
              width: displayWidth,
              height: displayHeight,
              alignment: Alignment.center,
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.2),
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }

          // 使用 LazyImage 懒加载
          return LazyImage(
            imageProvider: imageProvider,
            width: width,
            height: height,
            heroTag: heroTag,
            cacheKey: resolvedUrl, // 使用稳定的 URL 作为缓存 key
            onTap: () {
              final originalUrl = _getOriginalUrl(resolvedUrl!);
              final List<String> originalGalleryImages = galleryImages
                  .map((e) => _getOriginalUrl(e))
                  .toList();
              // 为所有画廊图片生成确定性 hero tags
              final int galleryHash = Object.hashAll(galleryImages);
              final List<String> heroTags = List.generate(
                galleryImages.length,
                (i) => "gallery_${galleryHash}_$i",
              );

              ImageViewerPage.open(
                context,
                originalUrl,
                heroTag: heroTag,
                galleryImages: originalGalleryImages,
                heroTags: heroTags,
                initialIndex: galleryIndex,
                enableShare: true,
                thumbnailUrl: resolvedUrl,
                thumbnailUrls: galleryImages,
              );
            },
          );
        }

        return buildGalleryImage();
      }
    );
  }

  Future<String?> _resolveUploadUrl(String url) async {
     try {
       return await DiscourseService().resolveShortUrl(url);
     } catch (e) {
       debugPrint('Failed to resolve upload url: $url, error: $e');
       return null;
     }
  }

  /// 尝试根据缩略图/优化图 URL 推导原图 URL
  String _getOriginalUrl(String optimizedUrl) {
    // 示例 optimized: .../uploads/default/optimized/4X/7/5/c/75c...dc_2_690x270.png
    // 示例 original:  .../uploads/default/original/4X/7/5/c/75c...dc.png

    if (!optimizedUrl.contains('/optimized/')) {
      return optimizedUrl;
    }

    try {
      // 1. 替换路径段
      var original = optimizedUrl.replaceFirst('/optimized/', '/original/');

      // 2. 移除分辨率后缀 (e.g. _2_690x270)
      // 正则匹配： _\d+_\d+x\d+
      // 通常是 _2_WidthxHeight 或者 _1_...
      // 这里的 \d+x\d+ 匹配尺寸
      final regex = RegExp(r'_\d+_\d+x\d+(?=\.[a-zA-Z0-9]+$)');

      if (regex.hasMatch(original)) {
        original = original.replaceAll(regex, '');
      }

      return original;
    } catch (e) {
      debugPrint('Error converting to original url: $e');
      return optimizedUrl;
    }
  }

  /// 检查 URL 是否为 SVG（处理带查询参数的情况）
  bool _isSvgUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.path.toLowerCase().endsWith('.svg');
  }

  /// 构建 SVG 图片 widget
  Widget _buildSvgWidget(String url, double? width, double? height, bool isEmoji) {
    return FutureBuilder<File>(
      future: DiscourseCacheManager().getSingleFile(url),
      builder: (context, snapshot) {
        final emojiSize = (DefaultTextStyle.of(context).style.fontSize ?? 16.0) * 1.2;

        if (snapshot.hasError || !snapshot.hasData) {
          final size = isEmoji ? emojiSize : (width ?? 24.0);
          if (snapshot.connectionState == ConnectionState.waiting) {
            return SizedBox(width: size, height: isEmoji ? emojiSize : (height ?? 24.0));
          }
          return Icon(Icons.broken_image, size: size, color: Theme.of(context).colorScheme.outline);
        }

        if (isEmoji) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 2.0),
            child: SizedBox(
              width: emojiSize,
              height: emojiSize,
              child: SvgPicture.file(snapshot.data!, fit: BoxFit.contain),
            ),
          );
        }

        // 读取 SVG 文件获取声明的尺寸
        return FutureBuilder<String>(
          future: snapshot.data!.readAsString(),
          builder: (context, svgSnapshot) {
            if (!svgSnapshot.hasData) return const SizedBox.shrink();

            var svgContent = svgSnapshot.data!;
            final svgWidth = _parseSvgDimension(svgContent, 'width');
            final svgHeight = _parseSvgDimension(svgContent, 'height');

            // 修复 transform="scale(.1)" 问题：将 font-size 和 scale 合并
            svgContent = _fixSvgTextScale(svgContent);

            return SvgPicture.string(
              svgContent,
              width: svgWidth ?? width,
              height: svgHeight ?? height,
              fit: BoxFit.contain,
            );
          },
        );
      },
    );
  }

  /// 修复 SVG 中 text 元素的 scale 变换问题
  String _fixSvgTextScale(String svg) {
    // 匹配 font-size="110" 这样的大字体
    final fontSizeMatch = RegExp(r'font-size="(\d+)"').firstMatch(svg);
    if (fontSizeMatch == null) return svg;

    final fontSize = int.tryParse(fontSizeMatch.group(1)!) ?? 0;
    if (fontSize <= 20) return svg; // 正常字体大小，不需要修复

    // 查找 scale 变换
    final scaleMatch = RegExp(r'transform="scale\(\.(\d+)\)"').firstMatch(svg);
    if (scaleMatch == null) return svg;

    final scaleValue = double.tryParse('0.${scaleMatch.group(1)}') ?? 1.0;
    final newFontSize = (fontSize * scaleValue).round();

    // 替换字体大小并移除 scale 变换
    svg = svg.replaceAll('font-size="$fontSize"', 'font-size="$newFontSize"');
    svg = svg.replaceAll(RegExp(r' transform="scale\(\.\d+\)"'), '');

    // 修复 text 元素的坐标（也需要缩放）
    svg = svg.replaceAllMapped(RegExp(r'<text([^>]*) x="(\d+)"([^>]*) y="(\d+)"'), (m) {
      final x = ((int.tryParse(m.group(2)!) ?? 0) * scaleValue).round();
      final y = ((int.tryParse(m.group(4)!) ?? 0) * scaleValue).round();
      return '<text${m.group(1)} x="$x"${m.group(3)} y="$y"';
    });

    return svg;
  }

  /// 从 SVG 内容解析尺寸属性
  double? _parseSvgDimension(String svg, String attr) {
    final match = RegExp('$attr="(\d+(?:\.\d+)?)"').firstMatch(svg);
    if (match != null) return double.tryParse(match.group(1)!);
    return null;
  }
}