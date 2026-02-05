import 'package:flutter/material.dart';

import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/doh/network_settings_service.dart';

/// HTTP 代理设置卡片
class HttpProxyCard extends StatelessWidget {
  const HttpProxyCard({
    super.key,
    required this.proxySettings,
    required this.dohEnabled,
  });

  final ProxySettings proxySettings;
  final bool dohEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proxyService = ProxySettingsService.instance;
    final networkService = NetworkSettingsService.instance;

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: proxySettings.enabled
          ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3)
          : theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: proxySettings.enabled
              ? theme.colorScheme.tertiary.withValues(alpha: 0.3)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('HTTP 代理'),
            subtitle: Text(
              proxySettings.enabled ? '已启用自定义代理' : '使用自定义 HTTP 代理服务器',
            ),
            secondary: Icon(
              proxySettings.enabled ? Icons.vpn_key : Icons.vpn_key_outlined,
              color: proxySettings.enabled ? theme.colorScheme.tertiary : null,
            ),
            value: proxySettings.enabled,
            onChanged: (value) async {
              if (value) {
                // 开启前校验配置
                final hasConfig = proxySettings.host.isNotEmpty && proxySettings.port > 0;
                if (!hasConfig) {
                  // 无配置时强制弹出设置对话框
                  final saved = await _showProxyConfigDialog(context, proxySettings);
                  // 如果未保存有效配置，则不开启
                  if (saved != true) return;
                }
              }

              if (value && dohEnabled) {
                // 启用代理时关闭 DOH
                await networkService.setDohEnabled(false);
              }
              await proxyService.setEnabled(value);
            },
          ),
          if (proxySettings.enabled) ...[
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            ListTile(
              leading: const Icon(Icons.dns),
              title: const Text('代理服务器'),
              subtitle: Text(
                proxySettings.host.isNotEmpty
                    ? '${proxySettings.host}:${proxySettings.port}'
                    : '未配置',
              ),
              trailing: const Icon(Icons.edit, size: 20),
              onTap: () => _showProxyConfigDialog(context, proxySettings),
            ),
            if (proxySettings.username != null && proxySettings.username!.isNotEmpty) ...[
              Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('认证'),
                subtitle: Text('用户名: ${proxySettings.username}'),
                dense: true,
              ),
            ],
          ],
          // 互斥提示
          if (dohEnabled && !proxySettings.enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '启用代理将自动关闭 DOH',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<bool> _showProxyConfigDialog(BuildContext context, ProxySettings proxySettings) async {
    final proxyService = ProxySettingsService.instance;
    final hostController = TextEditingController(text: proxySettings.host);
    final portController = TextEditingController(
      text: proxySettings.port > 0 ? proxySettings.port.toString() : '',
    );
    final usernameController = TextEditingController(text: proxySettings.username ?? '');
    final passwordController = TextEditingController(text: proxySettings.password ?? '');
    final showAuth = ValueNotifier<bool>(
      (proxySettings.username?.isNotEmpty ?? false) ||
          (proxySettings.password?.isNotEmpty ?? false),
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('配置代理服务器'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: hostController,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: '例如：192.168.1.1 或 proxy.example.com',
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portController,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    hintText: '例如：8080',
                  ),
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<bool>(
                  valueListenable: showAuth,
                  builder: (context, show, _) {
                    return Column(
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: show,
                              onChanged: (v) => showAuth.value = v ?? false,
                            ),
                            const Text('需要认证'),
                          ],
                        ),
                        if (show) ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: usernameController,
                            decoration: const InputDecoration(
                              labelText: '用户名',
                            ),
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: passwordController,
                            decoration: const InputDecoration(
                              labelText: '密码',
                            ),
                            obscureText: true,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final host = hostController.text.trim();
                final portText = portController.text.trim();
                if (host.isEmpty || portText.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请填写服务器地址和端口')),
                  );
                  return;
                }
                final port = int.tryParse(portText);
                if (port == null || port <= 0 || port > 65535) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('端口无效')),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      final host = hostController.text.trim();
      final port = int.tryParse(portController.text.trim()) ?? 0;
      final username = showAuth.value ? usernameController.text.trim() : null;
      final password = showAuth.value ? passwordController.text.trim() : null;
      await proxyService.setServer(
        host: host,
        port: port,
        username: username,
        password: password,
      );
    }

    hostController.dispose();
    portController.dispose();
    usernameController.dispose();
    passwordController.dispose();

    return result == true;
  }
}
