import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ldc_oauth_service.dart';
import '../services/toast_service.dart';
import '../providers/ldc_providers.dart';
import '../widgets/ldc_balance_card.dart';

class MetaversePage extends ConsumerStatefulWidget {
  const MetaversePage({super.key});

  @override
  ConsumerState<MetaversePage> createState() => _MetaversePageState();
}

class _MetaversePageState extends ConsumerState<MetaversePage> {
  static const String _ldcEnabledKey = 'ldc_enabled';
  bool _ldcEnabled = false;
  bool _isLoading = true;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ldcEnabled = prefs.getBool(_ldcEnabledKey) ?? false;
      _isLoading = false;
    });
  }

  Future<void> _toggleLdc(bool value) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      if (value) {
        await _enableLdc();
      } else {
        await _disableLdc();
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _enableLdc() async {
    try {
      final service = LdcOAuthService();
      final result = await service.authorize(context);

      if (result && mounted) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_ldcEnabledKey, true);
        setState(() => _ldcEnabled = true);
        ref.read(ldcUserInfoProvider.notifier).refresh();
        if (mounted) {
          ToastService.showSuccess('LDC 授权成功');
        }
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError('授权失败: $e');
      }
    }
  }

  Future<void> _disableLdc() async {
    try {
      final service = LdcOAuthService();
      await service.logout();
    } catch (e) {
      // 忽略登出错误
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ldcEnabledKey, false);
    setState(() => _ldcEnabled = false);
    ref.read(ldcUserInfoProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                const SliverAppBar.large(
                  title: Text('元宇宙'),
                  centerTitle: false,
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(
                      [
                        // 服务列表标题
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16, top: 8),
                          child: Text(
                            '我的服务',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                        // LDC 服务卡片
                        _buildLdcServiceItem(theme),
                        const SizedBox(height: 16),
                        // 更多服务占位符
                        _buildComingSoonItem(theme),
                        const SizedBox(height: 100), // 底部留白
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildLdcServiceItem(ThemeData theme) {
    if (_ldcEnabled) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LdcBalanceCard(),
          const SizedBox(height: 12),
           // 简单的设置入口，不再占据大面积
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            ),
            child: ListTile(
              onTap: _isProcessing ? null : () => _toggleLdc(false),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.settings_suggest_rounded,
                  color: theme.colorScheme.onSecondaryContainer,
                  size: 20,
                ),
              ),
              title: const Text('LDC 服务已开启'),
              subtitle: const Text('点击关闭服务'),
              trailing: _isProcessing
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                    )
                  : Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary),
            ),
          ),
        ],
      );
    }

    // 未开启状态：展示连接卡片
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        onTap: _isProcessing ? null : () => _toggleLdc(true),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.storefront_rounded,
                  size: 32,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LDC 积分服务',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '连接账户，开启积分权益',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_isProcessing)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton(
                  onPressed: () => _toggleLdc(true),
                   style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('开启'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComingSoonItem(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
          style: BorderStyle.solid
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.hub_rounded,
                size: 32,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 8),
              Text(
                '更多服务接入中...',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
