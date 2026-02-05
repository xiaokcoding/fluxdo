import 'dart:io';

import 'package:flutter/material.dart';

import '../../network_adapter_settings_page.dart';
import '../../../services/cf_challenge_service.dart';

/// 高级设置卡片
class AdvancedSettingsCard extends StatelessWidget {
  const AdvancedSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          if (!Platform.isWindows)
            ListTile(
              leading: const Icon(Icons.settings_ethernet),
              title: const Text('网络适配器'),
              subtitle: const Text('管理 Cronet 和备用适配器设置'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const NetworkAdapterSettingsPage(),
                  ),
                );
              },
            ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Cloudflare 验证'),
            subtitle: const Text('手动触发过盾验证'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _showManualVerify(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showManualVerify(BuildContext context) async {
    // 强制前台模式
    final result = await CfChallengeService().showManualVerify(context, true);

    if (result == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('验证成功')),
      );
    } else if (result == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('验证未通过'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } else {
      // null 表示在冷却中或无 context
      if (CfChallengeService().isInCooldown) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('验证太频繁，请稍后再试')),
        );
      }
    }
  }
}
