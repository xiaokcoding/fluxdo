import 'package:flutter/material.dart';
import '../../utils/responsive.dart';
import '../../utils/layout_lock.dart';

/// Master-Detail 双栏布局
/// 平板/桌面上显示双栏，手机上只显示 master 或 detail
class MasterDetailLayout extends StatelessWidget {
  static const double defaultMasterWidth = 380;
  static const double defaultMinDetailWidth = 400;

  const MasterDetailLayout({
    super.key,
    required this.master,
    this.detail,
    this.emptyDetail,
    this.masterFloatingActionButton,
    this.masterWidth = defaultMasterWidth,
    this.minDetailWidth = defaultMinDetailWidth,
    this.showDivider = true,
  });

  /// 主列表（左侧）
  final Widget master;

  /// 详情内容（右侧），为 null 时显示 emptyDetail
  final Widget? detail;

  /// 无详情时的占位组件
  final Widget? emptyDetail;

  /// 主列表区域的 FAB
  final Widget? masterFloatingActionButton;

  /// 主列表宽度
  final double masterWidth;

  /// 详情区最小宽度
  final double minDetailWidth;

  /// 是否显示分隔线
  final bool showDivider;

  /// 是否显示双栏布局
  static bool canShowBothPanesFor(
    BuildContext context, {
    double masterWidth = defaultMasterWidth,
    double minDetailWidth = defaultMinDetailWidth,
  }) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final computed = screenWidth >= masterWidth + minDetailWidth && !Responsive.isMobile(context);
    return LayoutLock.resolveCanShowBoth(computed: computed);
  }

  /// 是否显示双栏布局
  bool canShowBothPanes(BuildContext context) {
    return canShowBothPanesFor(
      context,
      masterWidth: masterWidth,
      minDetailWidth: minDetailWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showBothPanes = canShowBothPanes(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    if (!showBothPanes) {
      // 单栏模式：只显示 master，但仍需要显示 FAB
      if (masterFloatingActionButton != null) {
        return Stack(
          children: [
            master,
            Positioned(
              right: 16,
              bottom: 16 + bottomPadding,
              child: masterFloatingActionButton!,
            ),
          ],
        );
      }
      return master;
    }

    // 平板/桌面：双栏布局
    return Row(
      children: [
        SizedBox(
          width: masterWidth,
          child: Stack(
            children: [
              master,
              if (masterFloatingActionButton != null)
                Positioned(
                  right: 16,
                  bottom: 16 + bottomPadding,
                  child: masterFloatingActionButton!,
                ),
            ],
          ),
        ),
        if (showDivider) const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          child: detail ?? emptyDetail ?? _buildEmptyState(context),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.article_outlined,
            size: 64,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '选择一个话题查看详情',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 用于在 Master-Detail 模式下管理选中状态
class MasterDetailController extends ChangeNotifier {
  int? _selectedId;

  int? get selectedId => _selectedId;

  bool get hasSelection => _selectedId != null;

  void select(int id) {
    if (_selectedId != id) {
      _selectedId = id;
      notifyListeners();
    }
  }

  void clear() {
    if (_selectedId != null) {
      _selectedId = null;
      notifyListeners();
    }
  }
}
