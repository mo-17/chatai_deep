import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anime 使用平台化翻页，classic 保持 Flutter 默认配置', () {
    final anime = AppThemeFactory.anime().pageTransitionsTheme;
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.fuchsia,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      final builder = anime.builders[platform];
      expect(builder, isA<AppAnimePageTransitionsBuilder>());
      expect(
        builder!.transitionDuration,
        AppAnimePageTransitionsBuilder.enterDuration,
      );
      expect(
        builder.reverseTransitionDuration,
        AppAnimePageTransitionsBuilder.exitDuration,
      );
    }

    const cupertinoDefault = CupertinoPageTransitionsBuilder();
    for (final platform in const [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      final builder = anime.builders[platform];
      expect(builder, isA<AppAnimeCupertinoPageTransitionsBuilder>());
      expect(builder, isA<CupertinoPageTransitionsBuilder>());
      expect(
        builder!.transitionDuration,
        cupertinoDefault.transitionDuration,
      );
      expect(
        builder.reverseTransitionDuration,
        cupertinoDefault.reverseTransitionDuration,
      );
      expect(builder.delegatedTransition, isNotNull);
    }

    final classic = AppThemeFactory.classic(Colors.pink);
    final flutterDefault = ThemeData(primarySwatch: Colors.pink);
    expect(classic.pageTransitionsTheme, flutterDefault.pageTransitionsTheme);
  });

  testWidgets('Android 只移动不透明顶页，不使用叠加型动画', (tester) async {
    await _pumpTransition(tester, progress: 0.5, secondaryProgress: 0.75);

    final probe = find.byKey(const ValueKey('transition_probe'));
    final transition = find.descendant(
      of: probe,
      matching: find.byKey(const ValueKey('anime_page_transition')),
    );
    expect(transition, findsOneWidget);
    expect(
      find.descendant(
        of: transition,
        matching: find.byKey(const ValueKey('anime_route_surface')),
      ),
      findsOneWidget,
    );

    final slide = tester.widget<SlideTransition>(transition);
    expect(
      slide.position.value.dx,
      closeTo(1 - Curves.easeOutCubic.transform(0.5), 0.000000001),
    );
    expect(slide.position.value.dy, 0);

    for (final forbiddenType in <Type>[
      FadeTransition,
      ScaleTransition,
      Opacity,
      BackdropFilter,
    ]) {
      expect(
        find.descendant(of: probe, matching: find.byType(forbiddenType)),
        findsNothing,
      );
    }
    for (final removedKey in const [
      'anime_page_return_transition',
      'anime_page_paint_gate',
      'anime_page_ticker_gate',
    ]) {
      expect(
        find.descendant(
          of: probe,
          matching: find.byKey(ValueKey(removedKey)),
        ),
        findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('中间帧重叠区像素与独立页面一致，不会和底页混色', (tester) async {
    await _pumpSurfaceReference(tester);
    final reference = await _captureFrame(tester);

    await _pumpSolidGreenReference(tester);
    final bottomReference = await _captureFrame(tester);

    await _pumpTransitionFrame(tester);
    final transition = await _captureFrame(tester);

    // 80px 宽页面在 50% 进度时偏移 10px：左侧仍应露出纯绿色底页。
    _expectColorNear(
      transition.averageAround(4, 40),
      bottomReference.averageAround(4, 40),
      tolerance: 2,
    );

    // 屏幕 x=60 对应滑入页面的本地 x=50。它必须与独立渲染的同一像素
    // 一致，证明半透明页面内容只与自己的不透明 surface 合成。
    final overlapPixel = transition.averageAround(60, 40);
    final referencePixel = reference.averageAround(50, 40);
    _expectColorNear(overlapPixel, referencePixel, tolerance: 8);
    expect(overlapPixel[3], closeTo(255, 1));
    expect(referencePixel[3], closeTo(255, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('实际 Navigator push/pop 时底页静止且顶页全屏滑动', (tester) async {
    await _pumpNavigator(tester);

    expect(find.byKey(const ValueKey('anime_route_surface')), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(
      AppAnimePageTransitionsBuilder.enterDuration ~/ 2,
    );

    _expectRoutePairDuringTransition(tester);
    final pushOffsets = _visibleSlideOffsets(tester);
    expect(pushOffsets, hasLength(2));
    expect(pushOffsets.any((offset) => offset.dx == 0), isTrue);
    expect(pushOffsets.any((offset) => offset.dx > 0 && offset.dx < 1), isTrue);

    await tester.pumpAndSettle();
    expect(find.text('目标页'), findsOneWidget);
    expect(find.byKey(const ValueKey('anime_route_surface')), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(AppAnimePageTransitionsBuilder.exitDuration ~/ 2);

    _expectRoutePairDuringTransition(tester);
    final popOffsets = _visibleSlideOffsets(tester);
    expect(popOffsets, hasLength(2));
    expect(popOffsets.any((offset) => offset.dx == 0), isTrue);
    expect(popOffsets.any((offset) => offset.dx > 0 && offset.dx < 1), isTrue);

    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(find.byKey(const ValueKey('anime_route_surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS 路由仍走 Cupertino 转场并携带不透明 surface', (tester) async {
    await _pumpNavigator(tester, platform: TargetPlatform.iOS);

    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const ValueKey('anime_route_surface')), findsNWidgets(2));
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('目标页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统减少动态效果时直接切页且不创建 Slide', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await _pumpNavigator(tester);
    expect(
      find.byKey(
        const ValueKey('anime_page_transition'),
        skipOffstage: false,
      ),
      findsNothing,
    );

    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('目标页'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('anime_page_transition'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey('anime_page_transition'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dialog 覆盖当前 route surface，不会创建第二张页面背景', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(title: Text('弹窗')),
              ),
              child: const Text('显示弹窗'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('显示弹窗'));
    await tester.pumpAndSettle();

    expect(find.text('弹窗'), findsOneWidget);
    expect(find.byKey(const ValueKey('anime_route_surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _expectRoutePairDuringTransition(WidgetTester tester) {
  expect(find.byKey(const ValueKey('anime_route_surface')), findsNWidgets(2));
  expect(
    find.byKey(
      const ValueKey('anime_page_paint_gate'),
      skipOffstage: false,
    ),
    findsNothing,
  );
}

List<Offset> _visibleSlideOffsets(WidgetTester tester) {
  return find
      .byKey(const ValueKey('anime_page_transition'))
      .evaluate()
      .map((element) => (element.widget as SlideTransition).position.value)
      .toList();
}

Future<void> _pumpNavigator(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppThemeFactory.anime().copyWith(platform: platform),
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
}

Future<void> _pumpTransition(
  WidgetTester tester, {
  required double progress,
  double secondaryProgress = 0,
  bool disableAnimations = false,
}) {
  const transitionBuilder = AppAnimePageTransitionsBuilder();
  return tester.pumpWidget(
    _bareTestHost(
      disableAnimations: disableAnimations,
      childBuilder: (context) => KeyedSubtree(
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
          _FixedStatusAnimation(
            value: secondaryProgress,
            status: _statusForProgress(secondaryProgress),
          ),
          const SizedBox.expand(
            key: ValueKey('transition_destination'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpSurfaceReference(WidgetTester tester) {
  return tester.pumpWidget(
    _bareTestHost(
      childBuilder: (_) => const RepaintBoundary(
        key: ValueKey('capture_boundary'),
        child: AppAnimeRouteSurface(
          child: ColoredBox(color: Color(0x66FF00FF)),
        ),
      ),
    ),
  );
}

Future<void> _pumpSolidGreenReference(WidgetTester tester) {
  return tester.pumpWidget(
    _bareTestHost(
      childBuilder: (_) => const RepaintBoundary(
        key: ValueKey('capture_boundary'),
        child: ColoredBox(color: Color(0xFF00FF00)),
      ),
    ),
  );
}

Future<void> _pumpTransitionFrame(WidgetTester tester) {
  const transitionBuilder = AppAnimePageTransitionsBuilder();
  return tester.pumpWidget(
    _bareTestHost(
      childBuilder: (context) => RepaintBoundary(
        key: const ValueKey('capture_boundary'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF00FF00)),
            transitionBuilder.buildTransitions<void>(
              MaterialPageRoute<void>(
                builder: (_) => const SizedBox.shrink(),
              ),
              context,
              const _FixedStatusAnimation(
                value: 0.5,
                status: AnimationStatus.forward,
              ),
              const _FixedStatusAnimation(
                value: 0,
                status: AnimationStatus.dismissed,
              ),
              const ColoredBox(color: Color(0x66FF00FF)),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _bareTestHost({
  required Widget Function(BuildContext context) childBuilder,
  bool disableAnimations = false,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Theme(
        data: AppThemeFactory.anime(),
        child: Center(
          child: SizedBox(
            width: 80,
            height: 80,
            child: Builder(builder: childBuilder),
          ),
        ),
      ),
    ),
  );
}

Future<_RgbaFrame> _captureFrame(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture_boundary')),
  );
  final frame = await tester.runAsync<_RgbaFrame>(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw StateError('无法读取 route transition 测试帧');
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return _RgbaFrame(
        image.width,
        image.height,
        Uint8List.fromList(bytes),
      );
    } finally {
      image.dispose();
    }
  });
  if (frame == null) throw StateError('无法捕获 route transition 测试帧');
  return frame;
}

void _expectColorNear(
  List<double> actual,
  List<double> expected, {
  required double tolerance,
}) {
  expect(actual, hasLength(4));
  expect(expected, hasLength(4));
  for (var channel = 0; channel < 4; channel++) {
    expect(
      actual[channel],
      closeTo(expected[channel], tolerance),
      reason: 'RGBA 通道 $channel 不一致：actual=$actual, expected=$expected',
    );
  }
}

AnimationStatus _statusForProgress(double progress) {
  if (progress <= 0) return AnimationStatus.dismissed;
  if (progress >= 1) return AnimationStatus.completed;
  return AnimationStatus.forward;
}

class _RgbaFrame {
  final int width;
  final int height;
  final Uint8List bytes;

  const _RgbaFrame(this.width, this.height, this.bytes);

  List<double> averageAround(int centerX, int centerY) {
    final totals = List<int>.filled(4, 0);
    var count = 0;
    for (var y = centerY - 1; y <= centerY + 1; y++) {
      for (var x = centerX - 1; x <= centerX + 1; x++) {
        if (x < 0 || x >= width || y < 0 || y >= height) continue;
        final offset = (y * width + x) * 4;
        for (var channel = 0; channel < 4; channel++) {
          totals[channel] += bytes[offset + channel];
        }
        count++;
      }
    }
    return totals.map((total) => total / count).toList();
  }
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
