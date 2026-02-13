import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../services/toast_service.dart';
import 'image_editor_i18n_zh.dart';

/// 图片上传确认弹框结果
class ImageUploadResult {
  /// 处理后的图片路径
  final String path;

  /// 原始文件名
  final String originalName;

  ImageUploadResult({required this.path, required this.originalName});
}

/// 图片上传确认弹框
class ImageUploadDialog extends StatefulWidget {
  final String imagePath;
  final String? imageName;

  const ImageUploadDialog({
    super.key,
    required this.imagePath,
    this.imageName,
  });

  @override
  State<ImageUploadDialog> createState() => _ImageUploadDialogState();
}

class _ImageUploadDialogState extends State<ImageUploadDialog> {
  late String _currentImagePath;
  int _quality = 85;
  int? _originalSize;
  int? _estimatedSize;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _currentImagePath = widget.imagePath;
    _loadImageInfo();
  }

  Future<void> _loadImageInfo() async {
    final file = File(_currentImagePath);
    if (await file.exists()) {
      final size = await file.length();
      setState(() {
        _originalSize = size;
        _estimatedSize = _estimateCompressedSize(size, _quality);
      });
    }
  }

  int _estimateCompressedSize(int originalSize, int quality) {
    // 简单估算：基于质量百分比的非线性压缩
    // 实际压缩效果取决于图片内容
    final ratio = quality / 100.0;
    // 使用平方根使估算更接近实际
    return (originalSize * ratio * ratio).round();
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _editImage() async {
    final result = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (context) => ProImageEditor.file(
          File(_currentImagePath),
          callbacks: ProImageEditorCallbacks(
            onImageEditingComplete: (Uint8List bytes) async {
              Navigator.of(context).pop(bytes);
            },
          ),
          configs: ProImageEditorConfigs(
            i18n: kImageEditorI18nZh,
            imageGeneration: const ImageGenerationConfigs(
              outputFormat: OutputFormat.jpg,
              maxOutputSize: Size(1920, 1920),
            ),
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      // 保存编辑后的图片到临时文件
      final tempDir = await getTemporaryDirectory();
      final editedPath = p.join(
        tempDir.path,
        'edited_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await File(editedPath).writeAsBytes(result);

      setState(() {
        _currentImagePath = editedPath;
      });
      await _loadImageInfo();
    }
  }

  Future<String> _compressImage() async {
    // 如果质量为 100，不压缩
    if (_quality == 100) {
      return _currentImagePath;
    }

    final tempDir = await getTemporaryDirectory();
    final targetPath = p.join(
      tempDir.path,
      'compressed_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    final result = await FlutterImageCompress.compressAndGetFile(
      _currentImagePath,
      targetPath,
      quality: _quality,
      minWidth: 1920,
      minHeight: 1920,
    );

    return result?.path ?? _currentImagePath;
  }

  Future<void> _submit() async {
    setState(() => _isProcessing = true);

    try {
      final compressedPath = await _compressImage();

      if (!mounted) return;

      Navigator.of(context).pop(ImageUploadResult(
        path: compressedPath,
        originalName: widget.imageName ?? p.basename(widget.imagePath),
      ));
    } catch (e) {
      if (!mounted) return;
      ToastService.showError('处理图片失败: $e');
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('上传图片确认'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 图片预览
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(
                File(_currentImagePath),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // 压缩质量滑块
            Row(
              children: [
                Text('压缩质量：', style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Slider(
                    value: _quality.toDouble(),
                    min: 10,
                    max: 100,
                    divisions: 18,
                    label: '$_quality%',
                    onChanged: _isProcessing
                        ? null
                        : (value) {
                            setState(() {
                              _quality = value.round();
                              if (_originalSize != null) {
                                _estimatedSize = _estimateCompressedSize(
                                  _originalSize!,
                                  _quality,
                                );
                              }
                            });
                          },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '$_quality%',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),

            // 文件大小信息
            if (_originalSize != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.photo_size_select_large,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '原始大小：${_formatFileSize(_originalSize!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    if (_quality < 100 && _estimatedSize != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '约 ${_formatFileSize(_estimatedSize!)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            const SizedBox(height: 8),

            // 编辑图片按钮
            OutlinedButton.icon(
              onPressed: _isProcessing ? null : _editImage,
              icon: const Icon(Icons.edit),
              label: const Text('编辑图片'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isProcessing ? null : _submit,
          child: _isProcessing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('上传'),
        ),
      ],
    );
  }
}

/// 显示图片上传确认弹框
Future<ImageUploadResult?> showImageUploadDialog(
  BuildContext context, {
  required String imagePath,
  String? imageName,
}) {
  return showDialog<ImageUploadResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ImageUploadDialog(
      imagePath: imagePath,
      imageName: imageName,
    ),
  );
}
