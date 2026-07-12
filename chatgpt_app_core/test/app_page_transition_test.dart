import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anime 使用轻量平台转场，classic 保持 Flutter 默认配置', () {
    final anime = AppThemeFactory.anime().pageTransitionsTheme;
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.fuchsia,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      final builder = anime.builders[platform];
      expect(builder, isA<AppAnimePageTransitionsBuilder>());
      expect(builder!.transitionDuration,
          AppAnimePageTransitionsBuilder.enterDuration);
      expect(builder.reverseTransitionDuration,
          AppAnimePageTransitionsBuilder.exitDuration);
    }

    for (final platform in const [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      final builder = anime.builders[platform];
      expect(builder, isA<AppAnimeCupertinoPageTransitionsBuilder>());
      expect(builder, isA<CupertinoPageTransitionsBuilder>());
      expect(builder!.transitionDuration,
          AppAnimeCupertinoPageTransitionsBuilder.enterDuration);
      expect(builder.reverseTransitionDuration,
          AppAnimeCupertinoPageTransitionsBuilder.exitDuration);
      expect(builder.delegatedTransition, isNotNull);
    }

    final classic = AppThemeFactory.classic(Colors.pink);
    final flutterDefault = ThemeData(primarySwatch: Colors.pink);
    expect(
      classic.pageTransitionsTheme,
      flutterDefault.pageTransitionsTheme,
    );
  });

  testWidgets('anime 新页面保持不透明，只使用轻微位移和独立重绘层', (tester) async {
    await _pumpTransition(tester, progress: 0.5);

    final probe = find.byKey(const ValueKey('transition_probe'));
    final transition = find.descendant(
      of: probe,
      matching: find.byKey(const ValueKey('anime_page_transition')),
    );
    expect(transition, findsOneWidget);
    final slide = tester.widget<SlideTransition>(transition);
    final outgoingFade = tester.widget<FadeTransition>(
      find.descendant(
        of: transition,
        matching: find.byKey(const ValueKey('anime_page_outgoing_fade')),
      ),
    );
    final curvedProgress = Curves.easeOutCubic.transform(0.5);
    expect(outgoingFade.opacity.value, 1);
    expect(
      slide.position.value.dx,
      closeTo(
        AppAnimePageTransitionsBuilder.beginOffsetX * (1 - curvedProgress),
        0.000000001,
      ),
    );
    expect(slide.position.value.dy, 0);
    expect(
      find.descendant(
        of: transition,
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: transition, matching: find.byType(ScaleTransition)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('anime 在转场开头快速隐藏旧页面，避免透明页面叠绘残影', (tester) async {
    const secondaryProgress =
        AppAnimePageTransitionsBuilder.outgoingFadeFraction / 2;
    await _pumpTransition(
      tester,
      progress: 1,
      secondaryProgress: secondaryProgress,
    );

    final probe = find.byKey(const ValueKey('transition_probe'));
    final outgoingFade = tester.widget<FadeTransition>(
      find.descendant(
        of: probe,
        matching: find.byKey(const ValueKey('anime_page_outgoing_fade')),
      ),
    );
    final outgoingProgress = const Interval(
      0,
      AppAnimePageTransitionsBuilder.outgoingFadeFraction,
      curve: Curves.easeOutCubic,
    ).transform(secondaryProgress);

    expect(
      outgoingFade.opacity.value,
      closeTo(1 - outgoingProgress, 0.000000001),
    );
    expect(outgoingFade.opacity.value, lessThan(0.15));
    expect(tester.takeException(), isNull);
  });

  testWidgets('实际 Navigator push 时旧页面先淡出，新页面保持完整不透明', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime().copyWith(
          platform: TargetPlatform.android,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('目标页')),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final opacities = tester
        .widgetList<FadeTransition>(
          find.byKey(const ValueKey('anime_page_outgoing_fade')),
        )
        .map((fade) => fade.opacity.value)
        .toList();
    expect(opacities, hasLength(2));
    expect(opacities.any((opacity) => opacity <= 0.001), isTrue);
    expect(opacities.any((opacity) => opacity == 1), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anime 返回开头快速恢复底页，避免空白闪烁', (tester) async {
    final secondaryController = AnimationController(
      vsync: tester,
      duration: AppAnimePageTransitionsBuilder.exitDuration,
    );
    try {
      secondaryController.reverse(from: 0.91);

      await _pumpTransition(
        tester,
        progress: 1,
        secondaryAnimation: secondaryController,
      );

      final probe = find.byKey(const ValueKey('transition_probe'));
      final outgoingFade = tester.widget<FadeTransition>(
        find.descendant(
          of: probe,
          matching: find.byKey(const ValueKey('anime_page_outgoing_fade')),
        ),
      );
      final reverseProgress = const Interval(
        1 - AppAnimePageTransitionsBuilder.outgoingFadeFraction,
        1,
        curve: Curves.easeInCubic,
      ).transform(0.91);

      expect(
        outgoingFade.opacity.value,
        closeTo(1 - reverseProgress, 0.000000001),
      );
      expect(outgoingFade.opacity.value, greaterThan(0.85));
      expect(tester.takeException(), isNull);
    } finally {
      secondaryController.dispose();
    }
  });

  testWidgets('系统减少动态效果时直接显示目标页', (tester) async {
    await _pumpTransition(
      tester,
      progress: 0,
      disableAnimations: true,
    );

    final probe = find.byKey(const ValueKey('transition_probe'));
    expect(
      find.descendant(
        of: probe,
        matching: find.byKey(const ValueKey('anime_page_transition')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: probe,
        matching: find.byKey(const ValueKey('transition_destination')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpTransition(
  WidgetTester tester, {
  required double progress,
  double secondaryProgress = 0,
  Animation<double>? secondaryAnimation,
  bool disableAnimations = false,
}) {
  const transitionBuilder = AppAnimePageTransitionsBuilder();
  return tester.pumpWidget(
    MaterialApp(
      theme: AppThemeFactory.anime(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Builder(
          builder: (context) => KeyedSubtree(
            key: const ValueKey('transition_probe'),
            child: transitionBuilder.buildTransitions<void>(
              MaterialPageRoute<void>(
                builder: (_) => const SizedBox.shrink(),
              ),
              context,
              AlwaysStoppedAnimation<double>(progress),
              secondaryAnimation ??
                  AlwaysStoppedAnimation<double>(secondaryProgress),
              const SizedBox(
                key: ValueKey('transition_destination'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
