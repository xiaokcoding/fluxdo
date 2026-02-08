import 'package:flutter/material.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../image_utils.dart';

/// 构建 Discourse 图片网格 (d-image-grid)
Widget? buildImageGrid({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required GalleryInfo galleryInfo,
}) {
  // 解析列数，默认 2 列
  final dataColumns = element.attributes['data-columns'] as String?;
  final columns = int.tryParse(dataColumns ?? '') ?? 2;

  // 提取所有图片
  final images = _extractImages(element);
  if (images.isEmpty) return null;

  // 使用全局画廊信息
  final galleryImages = galleryInfo.images;
  final heroTags = galleryInfo.heroTags;

  // 计算间距（与 Discourse 一致）
  const double spacing = 6.0;

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        // 计算每列宽度
        final columnWidth = (availableWidth - (columns - 1) * spacing) / columns;

        // 使用 Wrap 布局实现网格
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: images.map((imageData) {
            // 使用 GalleryInfo.findIndex 查找全局索引
            final globalIndex = galleryInfo.findIndex(imageData.src) 
                ?? galleryInfo.findIndex(imageData.fullSrc)
                ?? -1;
            
            // 生成 heroTag
            final heroTag = globalIndex >= 0 && globalIndex < heroTags.length
                ? heroTags[globalIndex]
                : 'grid_${imageData.src.hashCode}';

            return _GridImageTile(
              theme: theme,
              imageData: imageData,
              columnWidth: columnWidth,
              heroTag: heroTag,
              gridOriginalImages: galleryImages,
              gridThumbnailImages: galleryImages,  // 原图列表
              heroTags: heroTags,
              index: globalIndex >= 0 ? globalIndex : 0,
            );
          }).toList(),
        );
      },
    ),
  );
}

/// 提取图片数据
List<_ImageData> _extractImages(dynamic element) {
  final images = <_ImageData>[];
  final imgElements = element.getElementsByTagName('img');

  for (final img in imgElements) {
    // 排除 emoji、头像等
    final classes = (img.classes as Iterable<String>?)?.toList() ?? [];
    if (classes.contains('emoji') ||
        classes.contains('avatar') ||
        classes.contains('thumbnail') ||
        classes.contains('ytp-thumbnail-image')) {
      continue;
    }

    var src = img.attributes['src'] as String?;
    if (src == null || src.isEmpty) continue;

    // 处理相对路径（但保留 upload:// 协议）
    if (!DiscourseImageUtils.isUploadUrl(src)) {
      src = DiscourseImageUtils.resolveUrl(src);
    }

    // 尝试获取原图链接
    String? fullSrc = DiscourseImageUtils.findOriginalImageUrl(img);
    if (fullSrc != null && !DiscourseImageUtils.isUploadUrl(fullSrc)) {
      fullSrc = DiscourseImageUtils.resolveUrl(fullSrc);
    }

    // 尝试获取宽高
    final widthStr = img.attributes['width'] as String?;
    final heightStr = img.attributes['height'] as String?;
    final width = double.tryParse(widthStr ?? '');
    final height = double.tryParse(heightStr ?? '');

    images.add(_ImageData(
      src: src,
      fullSrc: fullSrc ?? (DiscourseImageUtils.isUploadUrl(src) ? src : DiscourseImageUtils.getOriginalUrl(src)),
      width: width,
      height: height,
    ));
  }

  return images;
}

/// 网格图片瓦片
class _GridImageTile extends StatelessWidget {
  final ThemeData theme;
  final _ImageData imageData;
  final double columnWidth;
  final String heroTag;
  final List<String> gridOriginalImages;
  final List<String> gridThumbnailImages;
  final List<String> heroTags;
  final int index;

  const _GridImageTile({
    required this.theme,
    required this.imageData,
    required this.columnWidth,
    required this.heroTag,
    required this.gridOriginalImages,
    required this.gridThumbnailImages,
    required this.heroTags,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    // 计算显示高度，保持宽高比，限制最大高度
    double displayHeight;
    if (imageData.width != null && imageData.height != null && imageData.width! > 0) {
      final aspectRatio = imageData.height! / imageData.width!;
      displayHeight = columnWidth * aspectRatio;
      displayHeight = displayHeight.clamp(80.0, 300.0);
    } else {
      displayHeight = columnWidth * 0.75;
    }

    // 检查是否是 upload:// 短链接
    if (!DiscourseImageUtils.isUploadUrl(imageData.src)) {
      // 普通 URL，直接渲染
      return _buildImageWidget(context, imageData.src, imageData.fullSrc, displayHeight);
    }

    // upload:// 短链接：检查缓存
    if (DiscourseImageUtils.isUploadUrlCached(imageData.src)) {
      final resolvedUrl = DiscourseImageUtils.getCachedUploadUrl(imageData.src);
      if (resolvedUrl != null) {
        return _buildImageWidget(context, resolvedUrl, resolvedUrl, displayHeight);
      }
      // 解析失败
      return _buildErrorWidget(displayHeight);
    }

    // 首次加载：使用 FutureBuilder 解析
    return FutureBuilder<String?>(
      future: DiscourseImageUtils.resolveUploadUrl(imageData.src),
      builder: (context, snapshot) {
        // 加载中
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoadingWidget(displayHeight);
        }

        // 解析失败
        if (snapshot.data == null) {
          return _buildErrorWidget(displayHeight);
        }

        // 解析成功
        final resolvedUrl = snapshot.data!;
        return _buildImageWidget(context, resolvedUrl, resolvedUrl, displayHeight);
      },
    );
  }

  Widget _buildImageWidget(BuildContext context, String displayUrl, String fullUrl, double displayHeight) {
    return SizedBox(
      width: columnWidth,
      height: displayHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onTap: () => _openViewer(context, fullUrl),
          child: Hero(
            tag: heroTag,
            child: Image(
              image: discourseImageProvider(displayUrl),
              fit: BoxFit.cover,
              width: columnWidth,
              height: displayHeight,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: loadingProgress.expectedTotalBytes != null
                            ? loadingProgress.cumulativeBytesLoaded /
                                loadingProgress.expectedTotalBytes!
                            : null,
                      ),
                    ),
                  ),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image,
                    color: theme.colorScheme.outline,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _openViewer(BuildContext context, String resolvedFullUrl) {
    // 确保所有画廊图片都使用原图 URL
    final resolvedGalleryImages = gridOriginalImages
        .map((url) => DiscourseImageUtils.getOriginalUrl(url))
        .toList();
    // 当前点击的图片使用解析后的 URL
    if (index >= 0 && index < resolvedGalleryImages.length) {
      resolvedGalleryImages[index] = DiscourseImageUtils.getOriginalUrl(resolvedFullUrl);
    }

    DiscourseImageUtils.openViewer(
      context: context,
      imageUrl: DiscourseImageUtils.getOriginalUrl(resolvedFullUrl),
      heroTag: heroTag,
      thumbnailUrl: resolvedFullUrl,
      galleryImages: resolvedGalleryImages,
      thumbnailUrls: gridThumbnailImages,
      heroTags: heroTags,
      initialIndex: index >= 0 ? index : 0,
    );
  }

  Widget _buildLoadingWidget(double displayHeight) {
    return SizedBox(
      width: columnWidth,
      height: displayHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          color: theme.colorScheme.surfaceContainerHighest,
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorWidget(double displayHeight) {
    return SizedBox(
      width: columnWidth,
      height: displayHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.broken_image,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

/// 图片数据
class _ImageData {
  final String src;
  final String fullSrc;
  final double? width;
  final double? height;

  _ImageData({
    required this.src,
    required this.fullSrc,
    this.width,
    this.height,
  });
}


