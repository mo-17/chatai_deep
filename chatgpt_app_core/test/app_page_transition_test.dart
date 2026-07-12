import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets('anime 可见页面只做轻微位移，不再使用交叉淡化', (tester) async {
    await _pumpTransition(tester, progress: 0.5);

    final probe = find.byKey(const ValueKey('transition_probe'));
    final transition = find.descendant(
      of: probe,
      matching: find.byKey(const ValueKey('anime_page_transition')),
    );
    expect(transition, findsOneWidget);
    final slide = tester.widget<SlideTransition>(transition);
    final returnSlide = tester.widget<SlideTransition>(
      find.descendant(
        of: transition,
        matching: find.byKey(
          const ValueKey('anime_page_return_transition'),
        ),
      ),
    );
    final paintGate = tester.widget<Opacity>(_paintGateIn(probe));
    final curvedProgress = Curves.easeOutCubic.transform(0.5);
    expect(paintGate.opacity, 1);
    expect(
      slide.position.value.dx,
      closeTo(
        AppAnimePageTransitionsBuilder.beginOffsetX * (1 - curvedProgress),
        0.000000001,
      ),
    );
    expect(slide.position.value.dy, 0);
    expect(returnSlide.position.value, Offset.zero);
    expect(
      find.descendant(
        of: transition,
        matching: find.byType(RepaintBoundary),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: transition, matching: find.byType(ScaleTransition)),
      findsNothing,
    );
    expect(
      find.descendant(of: transition, matching: find.byType(FadeTransition)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('push 开始的第一个状态帧就停止绘制旧页面', (tester) async {
    final secondaryController = AnimationController(
      vsync: tester,
      duration: AppAnimePageTransitionsBuilder.enterDuration,
    );
    try {
      secondaryController.forward(from: 0);
      await _pumpTransition(
        tester,
        progress: 1,
        secondaryAnimation: secondaryController,
      );

      final probe = find.byKey(const ValueKey('transition_probe'));
      final paintGate = _paintGateIn(probe);
      final opacity = tester.widget<Opacity>(paintGate);
      final renderOpacity = tester.renderObject<RenderOpacity>(paintGate);
      final tickerGate = tester.widget<TickerMode>(
        find.descendant(
          of: probe,
          matching: find.byKey(const ValueKey('anime_page_ticker_gate')),
        ),
      );

      expect(secondaryController.value, 0);
      expect(secondaryController.status, AnimationStatus.forward);
      expect(opacity.opacity, 0);
      expect(renderOpacity.paintsChild(renderOpacity.child!), isFalse);
      expect(tickerGate.enabled, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      secondaryController.dispose();
    }
  });

  testWidgets('实际 Navigator push 和 pop 的每一采样帧都只绘制一个页面', (tester) async {
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
    _expectSinglePaintedRoute(tester, expectedRouteCount: 2);
    await tester.pump(const Duration(milliseconds: 16));
    _expectSinglePaintedRoute(tester, expectedRouteCount: 2);
    await tester.pump(const Duration(milliseconds: 40));
    _expectSinglePaintedRoute(tester, expectedRouteCount: 2);
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pump();
    _expectSinglePaintedRoute(tester, expectedRouteCount: 2);
    await tester.pump(const Duration(milliseconds: 16));
    _expectSinglePaintedRoute(tester, expectedRouteCount: 2);
    await tester.pump(const Duration(milliseconds: 30));
    _expectSinglePaintedRoute(tester, expectedRouteCount: 2);
    await tester.pumpAndSettle();

    _expectSinglePaintedRoute(tester, expectedRouteCount: 1);
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pop 被取消时绘制所有权原子切回顶页，不产生叠绘帧', (tester) async {
    final transitionController = AnimationController(
      vsync: tester,
      duration: AppAnimePageTransitionsBuilder.exitDuration,
    );
    try {
      transitionController.reverse(from: 0.5);
      await _pumpRoutePair(tester, transitionController);

      final bottomRoute = find.byKey(const ValueKey('bottom_route'));
      final topRoute = find.byKey(const ValueKey('top_route'));
      final routePair = find.byKey(const ValueKey('route_pair'));
      expect(tester.widget<Opacity>(_paintGateIn(bottomRoute)).opacity, 1);
      expect(tester.widget<Opacity>(_paintGateIn(topRoute)).opacity, 0);
      _expectSinglePaintedRoute(
        tester,
        expectedRouteCount: 2,
        ancestor: routePair,
      );

      transitionController.forward();
      await tester.pump();

      expect(tester.widget<Opacity>(_paintGateIn(bottomRoute)).opacity, 0);
      expect(tester.widget<Opacity>(_paintGateIn(topRoute)).opacity, 1);
      _expectSinglePaintedRoute(
        tester,
        expectedRouteCount: 2,
        ancestor: routePair,
      );
      expect(tester.takeException(), isNull);
    } finally {
      transitionController.dispose();
    }
  });

  testWidgets('pop 时底页从反方向轻微归位且立即成为唯一绘制页', (tester) async {
    final secondaryController = AnimationController(
      vsync: tester,
      duration: AppAnimePageTransitionsBuilder.exitDuration,
    );
    try {
      secondaryController.reverse(from: 0.5);

      await _pumpTransition(
        tester,
        progress: 1,
        secondaryAnimation: secondaryController,
      );

      final probe = find.byKey(const ValueKey('transition_probe'));
      final paintGate = _paintGateIn(probe);
      final returnSlide = tester.widget<SlideTransition>(
        find.descendant(
          of: probe,
          matching: find.byKey(
            const ValueKey('anime_page_return_transition'),
          ),
        ),
      );
      final opacity = tester.widget<Opacity>(paintGate);
      final renderOpacity = tester.renderObject<RenderOpacity>(paintGate);
      final reverseProgress = Curves.easeInCubic.transform(0.5);

      expect(secondaryController.status, AnimationStatus.reverse);
      expect(opacity.opacity, 1);
      expect(renderOpacity.paintsChild(renderOpacity.child!), isTrue);
      expect(
        returnSlide.position.value.dx,
        closeTo(
          AppAnimePageTransitionsBuilder.returnOffsetX * reverseProgress,
          0.000000001,
        ),
      );
      expect(returnSlide.position.value.dy, 0);
      expect(tester.takeException(), isNull);
    } finally {
      secondaryController.dispose();
    }
  });

  testWidgets('系统减少动态效果时直接显示目标页', (tester) async {
    await _pumpTransition(
      tester,
      progress: 1,
      disableAnimations: true,
    );

    final probe = find.byKey(const ValueKey('transition_probe'));
    final paintGate = tester.widget<Opacity>(_paintGateIn(probe));
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
    expect(
      find.descendant(
        of: probe,
        matching: find.byKey(
          const ValueKey('anime_page_return_transition'),
        ),
      ),
      findsNothing,
    );
    expect(paintGate.opacity, 1);
    expect(tester.takeException(), isNull);
  });
}

Finder _paintGateIn(Finder ancestor) {
  return find.descendant(
    of: ancestor,
    matching: find.byKey(const ValueKey('anime_page_paint_gate')),
  );
}

void _expectSinglePaintedRoute(
  WidgetTester tester, {
  required int expectedRouteCount,
  Finder? ancestor,
}) {
  final gateKey = find.byKey(
    const ValueKey('anime_page_paint_gate'),
    skipOffstage: false,
  );
  final gates = ancestor == null
      ? gateKey
      : find.descendant(
          of: ancestor,
          matching: gateKey,
          skipOffstage: false,
        );
  final elements = gates.evaluate().toList();
  expect(elements, hasLength(expectedRouteCount));

  final opacities = elements
      .map((element) => element.widget as Opacity)
      .map((widget) => widget.opacity)
      .toList();
  final paintedRoutes = elements.where((element) {
    final renderOpacity = element.renderObject! as RenderOpacity;
    return renderOpacity.child != null &&
        renderOpacity.paintsChild(renderOpacity.child!);
  }).length;

  expect(opacities.every((opacity) => opacity == 0 || opacity == 1), isTrue);
  expect(opacities.where((opacity) => opacity == 1), hasLength(1));
  expect(paintedRoutes, 1);
}

Future<void> _pumpRoutePair(
  WidgetTester tester,
  Animation<double> transitionAnimation,
) {
  const transitionBuilder = AppAnimePageTransitionsBuilder();
  const completed = _FixedStatusAnimation(
    value: 1,
    status: AnimationStatus.completed,
  );
  const dismissed = _FixedStatusAnimation(
    value: 0,
    status: AnimationStatus.dismissed,
  );
  return tester.pumpWidget(
    MaterialApp(
      theme: AppThemeFactory.anime(),
      home: Builder(
        builder: (context) => KeyedSubtree(
          key: const ValueKey('route_pair'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              KeyedSubtree(
                key: const ValueKey('bottom_route'),
                child: transitionBuilder.buildTransitions<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const SizedBox.shrink(),
                  ),
                  context,
                  completed,
                  transitionAnimation,
                  const ColoredBox(color: Colors.purple),
                ),
              ),
              KeyedSubtree(
                key: const ValueKey('top_route'),
                child: transitionBuilder.buildTransitions<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const SizedBox.shrink(),
                  ),
                  context,
                  transitionAnimation,
                  dismissed,
                  const ColoredBox(color: Colors.pink),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
              _FixedStatusAnimation(
                value: progress,
                status: _statusForProgress(progress),
              ),
              secondaryAnimation ??
                  _FixedStatusAnimation(
                    value: secondaryProgress,
                    status: _statusForProgress(secondaryProgress),
                  ),
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

AnimationStatus _statusForProgress(double progress) {
  if (progress <= 0) return AnimationStatus.dismissed;
  if (progress >= 1) return AnimationStatus.completed;
  return AnimationStatus.forward;
}

class _FixedStatusAnimation extends Animation<double> {
  @override
  final double value;

  @override
  final AnimationStatus status;

  const _FixedStatusAnimation({
    required this.value,
    required this.status,
  });

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}
