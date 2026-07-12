import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/theme_widget.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 外观设置独立于业务设置；风格切换不会改动聊天、账号或 AI 配置。
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return Scaffold(
      appBar: AppBar(title: const Text('外观与主题')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.palette_outlined,
                    color: colorScheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '风格只改变界面外观，不会修改聊天记录、账号或 AI 设置。你可以随时切回经典风格。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text('界面风格', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '选择后立即生效，并会在下次启动时保留。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _StylePreviewCard(
                  key: const ValueKey('visual_style_classic'),
                  style: AppVisualStyle.classic,
                  title: '经典风格',
                  description: '熟悉、简洁、原版布局',
                  selected: provider.visualStyle == AppVisualStyle.classic,
                  colors: [provider.themeColor.shade500, Colors.white],
                  icon: Icons.layers_outlined,
                  onTap: () => provider.setVisualStyle(AppVisualStyle.classic),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StylePreviewCard(
                  key: const ValueKey('visual_style_anime'),
                  style: AppVisualStyle.anime,
                  title: '梦幻二次元',
                  description: '紫粉色调、圆润轻盈',
                  selected: provider.visualStyle == AppVisualStyle.anime,
                  colors: const [Color(0xFF6D28D9), Color(0xFFBE185D)],
                  icon: Icons.auto_awesome_rounded,
                  onTap: () => provider.setVisualStyle(AppVisualStyle.anime),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          AnimatedSwitcher(
            duration: motionDuration,
            child: provider.visualStyle == AppVisualStyle.classic
                ? _ClassicColorSection(
                    key: const ValueKey('classic_color_section'),
                    provider: provider,
                  )
                : _AnimeStyleSection(
                    key: const ValueKey('anime_style_section'),
                    onRestore: () =>
                        provider.setVisualStyle(AppVisualStyle.classic),
                  ),
          ),
        ],
      ),
    );
  }
}

class _StylePreviewCard extends StatelessWidget {
  final AppVisualStyle style;
  final String title;
  final String description;
  final bool selected;
  final List<Color> colors;
  final IconData icon;
  final VoidCallback onTap;

  const _StylePreviewCard({
    super.key,
    required this.style,
    required this.title,
    required this.description,
    required this.selected,
    required this.colors,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = style == AppVisualStyle.anime ? 22.0 : 10.0;
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return Semantics(
      button: true,
      selected: selected,
      label: title,
      hint: selected ? '当前已选择' : '点按切换到$title',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: AnimatedContainer(
            duration: motionDuration,
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 176),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color:
                    selected ? colorScheme.primary : colorScheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: colorScheme.primary.withValues(alpha: 0.14),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: colors,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: Icon(icon, color: Colors.white, size: 30),
                      ),
                      if (selected)
                        const Positioned(
                          top: 7,
                          right: 7,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(3),
                              child: Icon(Icons.check_rounded,
                                  size: 16, color: Color(0xFF6D28D9)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  maxLines: 2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClassicColorSection extends StatelessWidget {
  final ThemeProvider provider;

  const _ClassicColorSection({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('经典强调色', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          '保留原有主题颜色，切换到二次元风格后也不会丢失。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        ThemeWidget(
          selectedColorName: provider.themeColorName,
          onThemeChange: (colorName) => provider.setTheme(colorName: colorName),
        ),
      ],
    );
  }
}

class _AnimeStyleSection extends StatelessWidget {
  final VoidCallback onRestore;

  const _AnimeStyleSection({super.key, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('梦境配色', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFEDE9FE), Color(0xFFFCE7F3)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE7DFF1)),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, color: Color(0xFF6D28D9)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '紫罗兰、樱粉与晴空蓝共同构成二次元风格，正文仍保持高对比度，便于长时间阅读。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF2E1065),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('restore_classic_style'),
            onPressed: onRestore,
            icon: const Icon(Icons.undo_rounded),
            label: const Text('恢复经典风格'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}
