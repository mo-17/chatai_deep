import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';

/// 只读能力标签：图标 + 文案，色从 secondaryContainer 派生。
/// 用于详情页的模型行展示「视觉 / 工具 / 推理 / 联网」能力。
class CapabilityChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? color;
  final Color? textColor;

  const CapabilityChip({
    super.key,
    required this.label,
    required this.icon,
    this.color,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visual = AppVisualTheme.of(context);
    final background = color ?? cs.secondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: visual.isAnime
          ? ShapeDecoration(
              color: background,
              shape: StadiumBorder(
                side: BorderSide(color: cs.outlineVariant),
              ),
            )
          : BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: textColor ?? cs.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: textColor ?? cs.onSecondaryContainer,
                  height: 1,
                ),
          ),
        ],
      ),
    );
  }
}
