import 'package:flutter/material.dart';

/// 后端模型的显示布局；选择、身份校验和刷新仍由设置页负责。
class BackendModelSelectionTile extends StatelessWidget {
  final String selectionLabel;
  final String catalogMessage;
  final bool loading;
  final VoidCallback onSelect;
  final VoidCallback onRefresh;

  const BackendModelSelectionTile({
    super.key,
    required this.selectionLabel,
    required this.catalogMessage,
    required this.loading,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onSelect,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('后端模型',
                    style: tt.bodyLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Tooltip(
                  message: catalogMessage,
                  child: Text(catalogMessage,
                      key: const ValueKey('backend-model-catalog-message'),
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const ValueKey('backend-model-selector'),
            onPressed: onSelect,
            style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                alignment: Alignment.centerLeft),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: selectionLabel,
                    child: Text(selectionLabel,
                        key: const ValueKey('backend-model-selected-label'),
                        style: tt.bodyMedium?.copyWith(color: cs.primary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: cs.onSurfaceVariant),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: loading ? null : onRefresh,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text('刷新模型清单',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
