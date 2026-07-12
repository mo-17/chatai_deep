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

  testWidgets('anime 转场只使用轻微位移、淡入和独立重绘层', (tester) async {
    await _pumpTransition(tester, progress: 0.5);

    final probe = find.byKey(const ValueKey('transition_probe'));
    final transition = find.descendant(
      of: probe,
      matching: find.byKey(const ValueKey('anime_page_transition')),
    );
    expect(transition, findsOneWidget);
    final fade = tester.widget<FadeTransition>(transition);
    final slide = tester.widget<SlideTransition>(
      find.descendant(of: transition, matching: find.byType(SlideTransition)),
    );
    final curvedProgress = Curves.easeOutCubic.transform(0.5);
    expect(
      fade.opacity.value,
      closeTo(0.96 + 0.04 * curvedProgress, 0.000000001),
    );
    expect(
      slide.position.value.dx,
      closeTo(0.035 * (1 - curvedProgress), 0.000000001),
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
              const AlwaysStoppedAnimation<double>(0),
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
