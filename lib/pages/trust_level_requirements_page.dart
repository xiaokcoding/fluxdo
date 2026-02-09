import 'package:flutter/material.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import '../widgets/common/trust_level_skeleton.dart';
import '../services/network/discourse_dio.dart';

class TrustLevelRequirementsPage extends StatefulWidget {
  const TrustLevelRequirementsPage({super.key});

  @override
  State<TrustLevelRequirementsPage> createState() =>
      _TrustLevelRequirementsPageState();
}

class _TrustLevelRequirementsPageState
    extends State<TrustLevelRequirementsPage> {
  bool _isLoading = true;
  String? _error;
  String _title = '';
  List<String> _paragraphs = [];
  List<List<String>> _tableData = [];
  List<bool> _greenRows = []; // 标记哪些行的第二列是绿色
  List<bool> _redRows = []; // 标记哪些行的第二列是红色

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final dio = DiscourseDio.create();
      final response = await dio.get('https://connect.linux.do/');

      if (response.statusCode == 200) {
        _parseHtml(response.data);
      } else {
        setState(() {
          _error = '请求失败: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = '加载失败: $e';
        _isLoading = false;
      });
    }
  }

  void _parseHtml(String htmlContent) {
    try {
      final document = html_parser.parse(htmlContent);

      // 查找包含"信任级别"的 div
      final allDivs = document.querySelectorAll('div');
      html_dom.Element? targetDiv;

      for (var div in allDivs) {
        final h2 = div.querySelector('h2');
        if (h2 != null && h2.text.contains('信任级别')) {
          targetDiv = div;
          break;
        }
      }

      if (targetDiv != null) {
        // 提取标题
        final h2 = targetDiv.querySelector('h2');
        if (h2 != null) {
          _title = h2.text.trim();
        }

        // 提取段落
        final paragraphs = targetDiv.querySelectorAll('p');
        _paragraphs = [];
        for (var p in paragraphs) {
          _paragraphs.add(p.text.trim());
        }

        // 提取表格
        final table = targetDiv.querySelector('table');
        if (table != null) {
          final rows = table.querySelectorAll('tr');
          _tableData = [];
          _greenRows = [];
          _redRows = [];

          for (var row in rows) {
            final cells = row.querySelectorAll('th, td');
            final rowData = <String>[];
            for (var cell in cells) {
              rowData.add(cell.text.trim());
            }
            _tableData.add(rowData);

            // 检查第二列的状态类（status-met 为绿色，status-unmet 为红色）
            if (cells.length > 1) {
              final secondCell = cells[1];
              _greenRows.add(secondCell.classes.contains('status-met'));
              _redRows.add(secondCell.classes.contains('status-unmet'));
            } else {
              _greenRows.add(false);
              _redRows.add(false);
            }
          }
        }
      } else {
        setState(() {
          _error = '未找到信任级别信息，请确保已登录';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = '解析失败: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: _isLoading
          ? const TrustLevelSkeleton()
          : _error != null
              ? _buildError(theme)
              : RefreshIndicator(
                  onRefresh: _fetchData,
                  child: CustomScrollView(
                    slivers: [
                      _buildAppBar(theme),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            if (_tableData.isNotEmpty) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 4, bottom: 12),
                                child: Text(
                                  '详细指标',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                              _buildRequirementsTable(theme),
                            ],
                            if (_paragraphs.length > 1) ...[
                              const SizedBox(height: 24),
                              _buildStatusList(theme),
                            ],
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildAppBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return SliverAppBar.large(
      title: const Text('信任要求'),
      centerTitle: false,
      expandedHeight: 220,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colorScheme.surface,
                colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -20,
                top: -20,
                child: Icon(
                  Icons.verified_user_outlined,
                  size: 240,
                  color: colorScheme.primary.withValues(alpha:0.05),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                        height: 1.2,
                      ),
                    ),
                    if (_paragraphs.isNotEmpty &&
                        _paragraphs[0].isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _paragraphs[0],
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.secondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRequirementsTable(ThemeData theme) {
    if (_tableData.isEmpty) return const SizedBox.shrink();

    final colorScheme = theme.colorScheme;
    final headers = _tableData[0];
    final rows = _tableData.sublist(1);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha:0.4),
        ),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha:0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Table Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    headers[0],
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    headers.length > 1 ? headers[1] : '',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.start,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    headers.length > 2 ? headers[2] : '',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.start,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          // Table Body
          ...List.generate(rows.length, (index) {
            final row = rows[index];
            final globalIndex = index + 1; // 对应 _greenRows 索引
            final isGreen =
                globalIndex < _greenRows.length && _greenRows[globalIndex];
            final isRed =
                globalIndex < _redRows.length && _redRows[globalIndex];

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: index != rows.length - 1
                    ? Border(
                        bottom: BorderSide(
                          color: colorScheme.outlineVariant.withValues(alpha:0.2),
                        ),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      row[0],
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    flex: 4,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isGreen
                              ? colorScheme.primaryContainer.withValues(alpha:0.4)
                              : (isRed
                                  ? colorScheme.errorContainer.withValues(alpha:0.4)
                                  : colorScheme.surfaceContainer),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          row.length > 1 ? row[1] : '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isGreen
                                ? colorScheme.primary
                                : (isRed
                                    ? colorScheme.error
                                    : colorScheme.onSurface),
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    flex: 2,
                    child: Text(
                      row.length > 2 ? row[2] : '',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.start,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStatusList(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            '状态总览',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        ...List.generate(_paragraphs.length - 1, (index) {
          final text = _paragraphs[index + 1];
          final isSuccess = text.contains('已达到') || text.contains('恭喜');

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isSuccess
                  ? theme.colorScheme.primaryContainer.withValues(alpha:0.2)
                  : theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSuccess
                    ? theme.colorScheme.primary.withValues(alpha:0.3)
                    : theme.colorScheme.outline.withValues(alpha:0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isSuccess ? Icons.check_circle_outline : Icons.info_outline,
                  color: isSuccess
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isSuccess
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight: isSuccess ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha:0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _error ?? '未知错误',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _fetchData,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
