import 'package:flutter/material.dart';

/// 分组小标题（labelMedium + primary 色 + 字距），统一三屏的 section header。
class SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsets padding;

  const SectionLabel(this.text,
      {super.key, this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 8)});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.primary,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 分组卡片：M3 tonal 卡片（surfaceContainerLow + 圆角 12），子项间自动分隔线。
/// 暗色下补一道 0.5px 描边，避免卡片融进深色背景（规格 do/don't）。
class SectionCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets margin;

  const SectionCard({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(height: 1, indent: 16, color: cs.outlineVariant));
      }
      rows.add(children[i]);
    }
    return Card(
      elevation: 0,
      margin: margin,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isDark
            ? BorderSide(color: cs.outlineVariant, width: 0.5)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}
