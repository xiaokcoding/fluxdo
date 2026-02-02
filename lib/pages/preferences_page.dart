import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/preferences_provider.dart';

class PreferencesPage extends ConsumerWidget {
  const PreferencesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final preferences = ref.watch(preferencesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('偏好设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _buildSectionHeader(theme, '基础'),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.2)),
            ),
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('长按预览'),
                  subtitle: const Text('长按话题卡片快速预览内容'),
                  secondary: Icon(
                    Icons.touch_app_rounded,
                    color: preferences.longPressPreview
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  value: preferences.longPressPreview,
                  onChanged: (value) {
                    ref.read(preferencesProvider.notifier).setLongPressPreview(value);
                  },
                ),
                Divider(height: 1, indent: 56, color: theme.colorScheme.outlineVariant.withOpacity(0.3)),
                SwitchListTile(
                  title: const Text('匿名分享'),
                  subtitle: const Text('分享链接时不附带个人用户标识'),
                  secondary: Icon(
                    Icons.visibility_off_rounded,
                    color: preferences.anonymousShare
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  value: preferences.anonymousShare,
                  onChanged: (value) {
                    ref.read(preferencesProvider.notifier).setAnonymousShare(value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(theme, '编辑器'),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: theme.colorScheme.outlineVariant.withOpacity(0.2)),
            ),
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              title: const Text('自动混排优化'),
              subtitle: const Text('输入时自动插入中英文混排空格'),
              secondary: Icon(
                Icons.auto_fix_high_rounded,
                color: preferences.autoPanguSpacing
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              value: preferences.autoPanguSpacing,
              onChanged: (value) {
                ref.read(preferencesProvider.notifier).setAutoPanguSpacing(value);
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Row(
      children: [
        Icon(Icons.tune, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
