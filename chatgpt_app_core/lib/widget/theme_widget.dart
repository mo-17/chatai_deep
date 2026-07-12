import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:flutter/material.dart';

/// 经典风格的强调色选择器。
class ThemeWidget extends StatelessWidget {
  final String selectedColorName;
  final ValueChanged<String> onThemeChange;

  const ThemeWidget({
    super.key,
    required this.selectedColorName,
    required this.onThemeChange,
  });

  static const _labels = <String, String>{
    'blue': '晴空',
    'red': '绯红',
    'pink': '樱粉',
    'purple': '罗兰',
    'deepPurple': '夜紫',
    'indigo': '靛蓝',
    'cyan': '青空',
    'teal': '青碧',
    'green': '森绿',
    'lightGreen': '嫩绿',
    'lime': '青柠',
    'yellow': '日光',
    'amber': '琥珀',
    'orange': '蜜橙',
    'deepOrange': '落日',
    'brown': '可可',
    'grey': '雾灰',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 12,
      children: [
        for (final colorName in ThemeProvider.themes)
          _ColorChoice(
            key: ValueKey('classic_theme_color_$colorName'),
            colorName: colorName,
            label: _labels[colorName] ?? colorName,
            selected: colorName == selectedColorName,
            selectedBorderColor: colorScheme.primary,
            onTap: () => onThemeChange(colorName),
          ),
      ],
    );
  }
}

class _ColorChoice extends StatelessWidget {
  final String colorName;
  final String label;
  final bool selected;
  final Color selectedBorderColor;
  final VoidCallback onTap;

  const _ColorChoice({
    super.key,
    required this.colorName,
    required this.label,
    required this.selected,
    required this.selectedBorderColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final materialColor = ThemeProvider.getThemeColor(colorName);
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label强调色',
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: motionDuration,
              width: 64,
              height: 84,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: selected
                    ? materialColor.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? selectedBorderColor : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: materialColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: materialColor.withValues(alpha: 0.28),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: selected
                          ? const Icon(Icons.check_rounded,
                              size: 20, color: Colors.white)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
