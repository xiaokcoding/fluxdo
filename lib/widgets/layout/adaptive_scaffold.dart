import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../pages/topics_page.dart';
import '../../utils/responsive.dart';
import 'adaptive_navigation.dart';

/// 自适应 Scaffold
///
/// 根据屏幕宽度自动切换布局：
/// - 手机: 底部导航
/// - 平板/桌面: 侧边导航栏
class AdaptiveScaffold extends ConsumerWidget {
  const AdaptiveScaffold({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.floatingActionButton,
    this.railLeading,
    this.extendedRail = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? railLeading;
  final bool extendedRail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showRail = Responsive.showNavigationRail(context);

    if (showRail) {
      return _buildRailLayout(context);
    }
    return _buildBottomNavLayout(context, ref);
  }

  Widget _buildRailLayout(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          AdaptiveNavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations,
            extended: extendedRail,
            leading: railLeading,
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(child: body),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }

  Widget _buildBottomNavLayout(BuildContext context, WidgetRef ref) {
    // 仅在首页 tab 时响应滚动隐藏，其他 tab 始终显示
    final isVisible = selectedIndex == 0
        ? ref.watch(bottomNavVisibleProvider)
        : true;

    return Scaffold(
      body: body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: _AnimatedBottomNav(
        visible: isVisible,
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: destinations,
      ),
    );
  }
}

/// 带动画的底部导航栏
class _AnimatedBottomNav extends StatelessWidget {
  const _AnimatedBottomNav({
    required this.visible,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final bool visible;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<AdaptiveDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: visible ? null : 0,
        child: Wrap(
          children: [
            AdaptiveBottomNavigation(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
            ),
          ],
        ),
      ),
    );
  }
}
