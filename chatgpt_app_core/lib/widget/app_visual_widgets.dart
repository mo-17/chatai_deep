import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';

/// 仅在二次元模式增加分组卡面；经典模式原样返回 [child]。
class AppVisualSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Key? animeKey;
  final bool clip;

  const AppVisualSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.animeKey,
    this.clip = true,
  });

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    if (!visual.isAnime) return child;
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(visual.cardRadius);
    return Padding(
      key: animeKey,
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: visual.glowPrimary,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: visual.elevatedSurface.withValues(alpha: 0.94),
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: clip ? Clip.antiAlias : Clip.none,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 跨页面统一的二次元空态。传入 [classic] 可保证经典模式完全沿用旧结构。
class AppVisualEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final Widget? classic;
  final Key? animeKey;

  const AppVisualEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.classic,
    this.animeKey,
  });

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    if (!visual.isAnime && classic != null) return classic!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [scheme.primaryContainer, scheme.secondaryContainer],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(icon, size: 36, color: scheme.primary),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (action != null) ...[
          const SizedBox(height: 20),
          action!,
        ],
      ],
    );
    if (!visual.isAnime) return Center(child: content);
    return Center(
      child: SingleChildScrollView(
        key: animeKey,
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AppVisualSurface(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 非交互状态标签；颜色始终同时配文字，不靠颜色单独传达状态。
class AppStatusBadge extends StatelessWidget {
  final String label;
  final AppStatusKind kind;
  final IconData? icon;

  const AppStatusBadge({
    super.key,
    required this.label,
    required this.kind,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppStatusPalette.of(context, kind);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: palette.container,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: palette.foreground),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: palette.onContainer,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
