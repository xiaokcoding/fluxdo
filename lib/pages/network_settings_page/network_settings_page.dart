import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/network/doh/network_settings_service.dart';
import '../../services/network/proxy/proxy_settings_service.dart';
import 'widgets/http_proxy_card.dart';
import 'widgets/doh_settings_card.dart';
import 'widgets/advanced_settings_card.dart';
import 'widgets/debug_tools_card.dart';

/// 网络设置页面
class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  final NetworkSettingsService _service = NetworkSettingsService.instance;
  final ProxySettingsService _proxyService = ProxySettingsService.instance;
  bool _isDeveloperMode = false;

  @override
  void initState() {
    super.initState();
    _loadDeveloperMode();
  }

  Future<void> _loadDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDeveloperMode = prefs.getBool('developer_mode') ?? false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: Listenable.merge([_service.notifier, _service.isApplying, _proxyService.notifier]),
      builder: (context, _) {
        final settings = _service.notifier.value;
        final proxySettings = _proxyService.notifier.value;
        final isApplying = _service.isApplying.value;

        return Scaffold(
          appBar: AppBar(
            title: const Text('网络设置'),
            actions: [
              if (isApplying)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // HTTP 代理设置（与 DOH 互斥）
              HttpProxyCard(
                proxySettings: proxySettings,
                dohEnabled: settings.dohEnabled,
              ),
              const SizedBox(height: 24),

              // DOH 开关与服务器列表
              DohSettingsCard(
                settings: settings,
                isApplying: isApplying,
              ),
              const SizedBox(height: 24),

              // 高级设置
              _buildSectionHeader(theme, '高级'),
              const SizedBox(height: 12),
              const AdvancedSettingsCard(),
              const SizedBox(height: 24),

              // 调试工具
              _buildSectionHeader(theme, '调试'),
              const SizedBox(height: 12),
              DebugToolsCard(isDeveloperMode: _isDeveloperMode),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
