import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('视觉分组卡仅在二次元模式增加容器', (tester) async {
    Future<void> pump(ThemeData theme) {
      return tester.pumpWidget(
        MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: const Scaffold(
            body: AppVisualSurface(
              animeKey: ValueKey('anime_surface'),
              child: Text('内容'),
            ),
          ),
        ),
      );
    }

    await pump(AppThemeFactory.classic(Colors.blue));
    expect(find.byKey(const ValueKey('anime_surface')), findsNothing);
    expect(find.text('内容'), findsOneWidget);

    await pump(AppThemeFactory.anime());
    final surface = find.byKey(const ValueKey('anime_surface'));
    expect(surface, findsOneWidget);
    expect(find.text('内容'), findsOneWidget);
    final materialFinder = find.descendant(
      of: surface,
      matching: find.byType(Material),
    );
    expect(materialFinder, findsOneWidget);
    final material = tester.widget<Material>(materialFinder);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(20));
    expect(material.clipBehavior, Clip.antiAlias);
  });

  testWidgets('状态标签有文字语义且二次元状态色来自统一 palette', (tester) async {
    final semantics = tester.ensureSemantics();
    late AppStatusPalette palette;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: Builder(
          builder: (context) {
            palette = AppStatusPalette.of(context, AppStatusKind.success);
            return const Scaffold(
              body: AppStatusBadge(
                label: '可用',
                kind: AppStatusKind.success,
                icon: Icons.check_rounded,
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('可用'), findsOneWidget);
    expect(find.bySemanticsLabel('可用'), findsOneWidget);
    expect(palette.container, const Color(0xFFDCFCE7));
    semantics.dispose();
  });

  testWidgets('系统减少动画时统一动效时长为零', (tester) async {
    late Duration duration;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              duration = AppVisualTheme.motionDurationOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(duration, Duration.zero);
  });
}
