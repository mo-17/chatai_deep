import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';

/// Story / Tavern 页面共用的最小触控目标。
///
/// 取 iOS 44pt 与 Material 48dp 的较小兼容值，页面可以继续通过全局主题
/// 扩大到 48dp，但不能再用 36dp 的紧凑按钮覆盖它。
const double kStoryMinTouchTarget = 44;

bool storyUsesAnimeStyle(BuildContext context) =>
    AppVisualTheme.of(context).isAnime;

/// 经典模式保留页面原有的 OutlineInputBorder；二次元模式直接复用全局
/// InputDecorationTheme 的 border，避免 `InputDecoration(border: null)` 回落到
/// Flutter 自带 4px 圆角并再次覆盖 18px 主题圆角。
InputBorder storyInputBorder(BuildContext context) {
  if (!storyUsesAnimeStyle(context)) return const OutlineInputBorder();
  return Theme.of(context).inputDecorationTheme.border ??
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(
          AppVisualTheme.of(context).cardRadius,
        ),
      );
}

/// 只在二次元模式增加卡片层级；经典模式原样返回 [child]。
class StoryAdaptiveSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry animeMargin;
  final EdgeInsetsGeometry animePadding;
  final double? animeRadius;
  final Color? animeColor;
  final bool emphasized;
  final Key? animeKey;

  const StoryAdaptiveSurface({
    super.key,
    required this.child,
    this.animeMargin = EdgeInsets.zero,
    this.animePadding = EdgeInsets.zero,
    this.animeRadius,
    this.animeColor,
    this.emphasized = false,
    this.animeKey,
  });

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    if (!visual.isAnime) return child;
    final scheme = Theme.of(context).colorScheme;
    final radius = animeRadius ?? visual.cardRadius;
    final borderRadius = BorderRadius.circular(radius);
    return Padding(
      key: animeKey,
      padding: animeMargin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: emphasized
              ? [
                  BoxShadow(
                    color: visual.glowPrimary.withValues(alpha: 0.36),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: animeColor ?? visual.elevatedSurface.withValues(alpha: 0.94),
          shape: RoundedRectangleBorder(
            borderRadius: borderRadius,
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: animePadding, child: child),
        ),
      ),
    );
  }
}

/// 二次元模式的列表卡片；经典模式仍是原来的裸 ListTile/ExpansionTile。
class StoryAdaptiveListItem extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry animeMargin;

  const StoryAdaptiveListItem({
    super.key,
    required this.child,
    this.animeMargin = const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
  });

  @override
  Widget build(BuildContext context) => StoryAdaptiveSurface(
        animeMargin: animeMargin,
        child: child,
      );
}

/// 保留经典空态，只在二次元模式提供带氛围层级的统一空态。
class StoryAdaptiveEmptyState extends StatelessWidget {
  final Widget classicChild;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const StoryAdaptiveEmptyState({
    super.key,
    required this.classicChild,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    if (!storyUsesAnimeStyle(context)) return classicChild;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        key: const ValueKey('anime_story_empty_state'),
        padding: const EdgeInsets.all(24),
        child: StoryAdaptiveSurface(
          animePadding:
              const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
          emphasized: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 32, color: scheme.secondary),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (subtitle?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
                if (action != null) ...[
                  const SizedBox(height: 18),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum StoryStatusKind { running, success, failure, neutral }

/// 把 story 的任务状态映射到 App 统一状态色，不再在页面维护第二套色板。
AppStatusPalette storyStatusPalette(
  BuildContext context,
  StoryStatusKind kind,
) {
  final appKind = switch (kind) {
    StoryStatusKind.running => AppStatusKind.info,
    StoryStatusKind.success => AppStatusKind.success,
    StoryStatusKind.failure => AppStatusKind.error,
    StoryStatusKind.neutral => AppStatusKind.neutral,
  };
  return AppStatusPalette.of(context, appKind);
}

/// 酒馆消息气泡。经典模式保持原 Card；二次元模式用不同语义容器区分
/// Persona 消息与角色消息。
class StoryMessageBubble extends StatelessWidget {
  final bool isUser;
  final Widget child;

  const StoryMessageBubble({
    super.key,
    required this.isUser,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    if (!visual.isAnime) {
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 5),
        child: child,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final color = isUser ? scheme.primaryContainer : scheme.surface;
    final borderColor =
        isUser ? scheme.primary.withValues(alpha: 0.28) : scheme.outlineVariant;
    return Container(
      key: ValueKey(
          isUser ? 'anime_story_user_bubble' : 'anime_story_role_bubble'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(isUser ? 20 : 6),
          bottomRight: Radius.circular(isUser ? 6 : 20),
        ),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: (isUser ? visual.glowPrimary : visual.glowSecondary)
                .withValues(alpha: 0.22),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}
