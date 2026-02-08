import 'package:flutter/material.dart';
import '../../../constants.dart';
import '../../../pages/image_viewer_page.dart';
import '../../../services/discourse/discourse_service.dart';

/// 画廊信息类
/// 同时保存缩略图 URL（用于匹配）和原图 URL（用于显示）
class GalleryInfo {
  /// 原图 URL 列表（用于画廊显示）
  final List<String> originalUrls;
  
  /// 缩略图 URL 到索引的映射（用于快速查找）
  final Map<String, int> _thumbnailToIndex;

  GalleryInfo._({
    required this.originalUrls,
    required Map<String, int> thumbnailToIndex,
  }) : _thumbnailToIndex = thumbnailToIndex;

  /// 从 HTML 提取画廊信息
  static GalleryInfo fromHtml(String html) {
    final List<String> originalUrls = [];
    final Map<String, int> thumbnailToIndex = {};
    
    final imgTagRegExp = RegExp(r'<img[^>]+>', caseSensitive: false);
    final srcRegExp = RegExp(r'''src\s*=\s*["']?([^"'\s>]+)["']?''', caseSensitive: false);
    final excludeClassRegExp = RegExp(
      r'''class\s*=\s*["'][^"']*(emoji|avatar|site-icon|favicon)[^"']*["']''',
      caseSensitive: false,
    );

    final matches = imgTagRegExp.allMatches(html);
    for (final match in matches) {
      final imgTag = match.group(0) ?? "";
      if (excludeClassRegExp.hasMatch(imgTag)) continue;

      final srcMatch = srcRegExp.firstMatch(imgTag);
      var src = srcMatch?.group(1);
      if (src == null) continue;
      if (src.contains('/favicon') || src.contains('favicon.')) continue;
      if (src.startsWith('upload://')) continue;

      // 将相对路径转换为绝对路径
      if (src.startsWith('/') && !src.startsWith('//')) {
        src = '${AppConstants.baseUrl}$src';
      }

      final thumbnailUrl = src;
      final originalUrl = DiscourseImageUtils.getOriginalUrl(src);
      
      final index = originalUrls.length;
      originalUrls.add(originalUrl);
      thumbnailToIndex[thumbnailUrl] = index;
      // 也用原图 URL 作为 key，方便匹配
      thumbnailToIndex[originalUrl] = index;
    }
    
    return GalleryInfo._(
      originalUrls: originalUrls,
      thumbnailToIndex: thumbnailToIndex,
    );
  }

  /// 从外部传入的图片列表构建 GalleryInfo
  static GalleryInfo fromImages(List<String> images) {
    final Map<String, int> thumbnailToIndex = {};
    
    for (var i = 0; i < images.length; i++) {
      final url = images[i];
      thumbnailToIndex[url] = i;
      // 同时添加原图 URL 作为 key
      final originalUrl = DiscourseImageUtils.getOriginalUrl(url);
      if (originalUrl != url) {
        thumbnailToIndex[originalUrl] = i;
      }
    }
    
    return GalleryInfo._(
      originalUrls: images,
      thumbnailToIndex: thumbnailToIndex,
    );
  }

  /// 根据任意格式的图片 URL 查找索引
  /// 会尝试多种 URL 变体匹配
  int? findIndex(String imageUrl) {
    // 1. 直接查找
    if (_thumbnailToIndex.containsKey(imageUrl)) {
      return _thumbnailToIndex[imageUrl];
    }
    
    // 2. 尝试 resolveUrl 后查找（处理相对路径）
    final resolvedUrl = DiscourseImageUtils.resolveUrl(imageUrl);
    if (_thumbnailToIndex.containsKey(resolvedUrl)) {
      return _thumbnailToIndex[resolvedUrl];
    }
    
    // 3. 尝试转换为原图 URL 后查找
    final originalUrl = DiscourseImageUtils.getOriginalUrl(imageUrl);
    if (_thumbnailToIndex.containsKey(originalUrl)) {
      return _thumbnailToIndex[originalUrl];
    }
    
    // 4. resolvedUrl 转换为原图后查找
    final resolvedOriginalUrl = DiscourseImageUtils.getOriginalUrl(resolvedUrl);
    if (_thumbnailToIndex.containsKey(resolvedOriginalUrl)) {
      return _thumbnailToIndex[resolvedOriginalUrl];
    }
    
    return null;
  }

  /// 获取原图 URL 列表（用于传递给画廊查看器）
  List<String> get images => originalUrls;
  
  /// 生成画廊 Hero tags
  List<String> get heroTags => DiscourseImageUtils.generateGalleryHeroTags(originalUrls);
  
  /// 获取指定索引的原图 URL
  String? getOriginalUrl(int index) {
    if (index >= 0 && index < originalUrls.length) {
      return originalUrls[index];
    }
    return null;
  }
}

/// Discourse 图片工具类
/// 集中处理图片 URL 转换、原图查找、查看器打开等通用逻辑
class DiscourseImageUtils {
  DiscourseImageUtils._();

  /// upload:// 短链接解析缓存（全局共享）
  static final Map<String, String?> _uploadUrlCache = {};

  /// 检查是否是 upload:// 短链接
  static bool isUploadUrl(String url) => url.startsWith('upload://');

  /// 从缓存中获取已解析的 URL
  /// 返回 null 表示未缓存，需要异步解析
  static String? getCachedUploadUrl(String shortUrl) {
    if (!isUploadUrl(shortUrl)) return shortUrl;
    if (_uploadUrlCache.containsKey(shortUrl)) {
      return _uploadUrlCache[shortUrl];
    }
    return null;
  }

  /// 检查 upload:// URL 是否已缓存
  static bool isUploadUrlCached(String shortUrl) {
    return _uploadUrlCache.containsKey(shortUrl);
  }

  /// 异步解析 upload:// 短链接并缓存结果
  static Future<String?> resolveUploadUrl(String shortUrl) async {
    if (!isUploadUrl(shortUrl)) return shortUrl;

    // 已缓存
    if (_uploadUrlCache.containsKey(shortUrl)) {
      return _uploadUrlCache[shortUrl];
    }

    // 调用 API 解析
    try {
      final resolved = await DiscourseService().resolveShortUrl(shortUrl);
      _uploadUrlCache[shortUrl] = resolved;
      return resolved;
    } catch (e) {
      debugPrint('[DiscourseImageUtils] Failed to resolve upload url: $shortUrl, error: $e');
      _uploadUrlCache[shortUrl] = null; // 缓存失败结果，避免重复请求
      return null;
    }
  }

  /// 将优化图 URL 转换为原图 URL
  ///
  /// Discourse 优化图路径: .../uploads/default/optimized/4X/7/5/c/75c...dc_2_690x270.png
  /// 原图路径:            .../uploads/default/original/4X/7/5/c/75c...dc.png
  static String getOriginalUrl(String optimizedUrl) {
    if (!optimizedUrl.contains('/optimized/')) {
      return optimizedUrl;
    }

    try {
      // 1. 替换路径段
      var original = optimizedUrl.replaceFirst('/optimized/', '/original/');

      // 2. 移除分辨率后缀 (e.g. _2_690x270)
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

  /// 从 DOM 元素中查找原图 URL
  /// 向上遍历 DOM 树，查找 lightbox 链接
  static String? findOriginalImageUrl(dynamic img) {
    dynamic current = img;

    // 向上遍历最多 5 层
    for (int i = 0; i < 5 && current != null; i++) {
      // 检查当前元素是否是 a 标签
      if (current.localName == 'a') {
        final href = current.attributes['href'] as String?;
        if (href != null && href.isNotEmpty) {
          // 检查是否是 lightbox 链接（通常指向原图）
          final classes = (current.classes as Iterable<String>?)?.toList() ?? [];
          if (classes.contains('lightbox') || href.contains('/original/')) {
            return href;
          }
          // 如果 href 指向图片文件，也返回
          if (isImageUrl(href)) {
            return href;
          }
        }
      }

      // 检查是否在 lightbox-wrapper 内
      if (current.localName == 'div' || current.localName == 'span') {
        final classes = (current.classes as Iterable<String>?)?.toList() ?? [];
        if (classes.contains('lightbox-wrapper')) {
          // 在 lightbox-wrapper 内查找 a.lightbox
          final anchors = current.getElementsByTagName('a');
          for (final a in anchors) {
            final aClasses = (a.classes as Iterable<String>?)?.toList() ?? [];
            if (aClasses.contains('lightbox')) {
              final href = a.attributes['href'] as String?;
              if (href != null && href.isNotEmpty) {
                return href;
              }
            }
          }
        }
      }

      current = current.parent;
    }

    return null;
  }

  /// 检查 URL 是否指向图片
  static bool isImageUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.endsWith('.jpg') ||
        lowerUrl.endsWith('.jpeg') ||
        lowerUrl.endsWith('.png') ||
        lowerUrl.endsWith('.gif') ||
        lowerUrl.endsWith('.webp') ||
        lowerUrl.contains('/uploads/') ||
        lowerUrl.contains('/original/');
  }

  /// 将相对路径转换为绝对路径
  static String resolveUrl(String url) {
    if (url.startsWith('/') && !url.startsWith('//')) {
      return '${AppConstants.baseUrl}$url';
    }
    return url;
  }

  /// 打开图片查看器
  static void openViewer({
    required BuildContext context,
    required String imageUrl,
    required String heroTag,
    String? thumbnailUrl,
    List<String>? galleryImages,
    List<String>? thumbnailUrls,
    List<String>? heroTags,
    int initialIndex = 0,
    bool enableShare = true,
  }) {
    ImageViewerPage.open(
      context,
      imageUrl,
      heroTag: heroTag,
      galleryImages: galleryImages,
      heroTags: heroTags,
      initialIndex: initialIndex,
      enableShare: enableShare,
      thumbnailUrl: thumbnailUrl,
      thumbnailUrls: thumbnailUrls,
    );
  }

  /// 生成画廊 Hero Tag
  static String generateGalleryHeroTag(List<String> galleryImages, int index) {
    final galleryHash = Object.hashAll(galleryImages);
    return "gallery_${galleryHash}_$index";
  }

  /// 生成画廊所有 Hero Tags
  static List<String> generateGalleryHeroTags(List<String> galleryImages) {
    final galleryHash = Object.hashAll(galleryImages);
    return List.generate(
      galleryImages.length,
      (i) => "gallery_${galleryHash}_$i",
    );
  }
}

