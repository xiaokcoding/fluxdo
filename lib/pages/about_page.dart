import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/apk_download_service.dart';
import '../services/cf_challenge_logger.dart';
import '../services/toast_service.dart';
import '../services/update_service.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/update_dialog.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final UpdateService _updateService = UpdateService();
  String _version = '0.1.0';
  int _versionTapCount = 0;
  DateTime? _lastVersionTapTime;
  bool _developerMode = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadDeveloperMode();
  }

  void _onVersionTap() {
    final now = DateTime.now();
    if (_lastVersionTapTime != null &&
        now.difference(_lastVersionTapTime!) > const Duration(seconds: 2)) {
      _versionTapCount = 0; // 超时重置
    }
    _lastVersionTapTime = now;
    _versionTapCount++;

    if (_versionTapCount == 7) {
      _versionTapCount = 0;
      _enableDeveloperMode();
    }
  }

  Future<void> _enableDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyEnabled = prefs.getBool('developer_mode') ?? false;
    if (alreadyEnabled) {
      setState(() => _developerMode = true);
      if (!mounted) return;
      ToastService.showInfo('开发者模式已启用');
      return;
    }
    await _setDeveloperMode(true);
  }

  Future<void> _setDeveloperMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('developer_mode', enabled);
    if (!enabled) {
      await CfChallengeLogger.clear();
    }
    await CfChallengeLogger.setEnabled(enabled);
    if (mounted) {
      setState(() => _developerMode = enabled);
    }
    if (!mounted) return;
    ToastService.showSuccess(enabled ? '已启用开发者模式' : '已关闭开发者模式');
  }

  Future<void> _loadVersion() async {
    final version = await _updateService.getCurrentVersion();
    setState(() {
      _version = version;
    });
  }

  Future<void> _loadDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('developer_mode') ?? false;
    if (mounted) {
      setState(() => _developerMode = enabled);
    }
  }

  Future<void> _checkForUpdate() async {
    if (!mounted) return;

    // 显示加载提示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: CircularProgressIndicator(),
          ),
        ),
      ),
    );

    try {
      final updateInfo = await _updateService.checkForUpdate();

      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭加载对话框

      if (updateInfo.hasUpdate) {
        showDialog(
          context: context,
          builder: (context) => UpdateDialog(
            updateInfo: updateInfo,
            onUpdate: () {
              Navigator.of(context).pop();
              _handleUpdate(updateInfo);
            },
            onCancel: () => Navigator.of(context).pop(),
            onOpenReleasePage: () {
              Navigator.of(context).pop();
              _openInBrowser(updateInfo.releaseUrl);
            },
          ),
        );
      } else {
        _showNoUpdateDialog(updateInfo.currentVersion);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭加载对话框
      _showErrorDialog(e.toString());
    }
  }

  /// 处理更新逻辑
  Future<void> _handleUpdate(UpdateInfo updateInfo) async {
    if (Platform.isAndroid) {
      await _startInAppDownload(updateInfo);
    } else {
      _openInBrowser(updateInfo.releaseUrl);
    }
  }

  /// 启动应用内下载
  Future<void> _startInAppDownload(UpdateInfo updateInfo) async {
    final apkAsset = await _updateService.getMatchingApkAsset(updateInfo);

    if (apkAsset == null) {
      // 无法匹配架构，回退到浏览器
      _openInBrowser(updateInfo.releaseUrl);
      return;
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DownloadProgressDialog(
        asset: apkAsset,
        downloadService: ApkDownloadService(),
      ),
    );
  }

  /// 在浏览器中打开
  void _openInBrowser(String url) {
    launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }

  void _showNoUpdateDialog(String currentVersion) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
        title: const Text('已是最新版本'),
        content: Text('当前版本: $currentVersion\n您正在使用最新版本的 FluxDO，无需更新。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.error_outline, size: 48, color: Colors.red),
        title: const Text('检查更新失败'),
        content: Text('无法检查更新，请稍后重试。\n错误信息: $error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('关于'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 40),
          // Logo Header
          Center(
            child: SvgPicture.asset(
              'assets/logo.svg',
              width: 100,
              height: 100,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                Text(
                  'FluxDO',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _onVersionTap,
                  child: Text(
                    'Version $_version',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 48),

          // Action List
          _buildSectionTitle(context, '信息'),
          _buildListTile(
            context,
            icon: Icons.update_rounded,
            title: '检查更新',
            onTap: _checkForUpdate,
          ),
          _buildListTile(
            context,
            icon: Icons.description_outlined,
            title: '开源许可',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'FluxDO',
              applicationVersion: _version,
              applicationLegalese: '非官方 Linux.do 客户端\n基于 Flutter & Material 3',
            ),
          ),

          const Divider(height: 32, indent: 16, endIndent: 16),

          _buildSectionTitle(context, '开发'),
          if (_developerMode)
            SwitchListTile(
              title: const Text('开发者模式'),
              subtitle: const Text('点击关闭开发者模式'),
              value: true,
              onChanged: (value) {
                if (!value) {
                  _setDeveloperMode(false);
                }
              },
            ),
          _buildListTile(
            context,
            icon: Icons.code,
            title: '项目源码',
            subtitle: 'GitHub',
            onTap: () => launchUrl(
              Uri.parse('https://github.com/Lingyan000/fluxdo'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          _buildListTile(
            context,
            icon: Icons.bug_report_outlined,
            title: '反馈问题',
            onTap: () => launchUrl(
              Uri.parse('https://github.com/Lingyan000/fluxdo/issues'),
              mode: LaunchMode.externalApplication,
            ),
          ),

          const SizedBox(height: 40),
          Center(
            child: Text(
              'Made with Flutter & \u2764\uFE0F',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildListTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
      onTap: onTap,
    );
  }
}
