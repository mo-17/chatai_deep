import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anime 与 classic 共用 Flutter 平台默认路由转场', () {
    final classic = AppThemeFactory.classic(Colors.pink).pageTransitionsTheme;
    final anime = AppThemeFactory.anime().pageTransitionsTheme;
    final flutterDefault = ThemeData(
      primarySwatch: Colors.pink,
    ).pageTransitionsTheme;

    expect(classic, flutterDefault);
    expect(anime, classic);

    for (final platform in anime.builders.keys) {
      final animeBuilder = anime.builders[platform]!;
      final classicBuilder = classic.builders[platform]!;
      expect(animeBuilder.runtimeType, classicBuilder.runtimeType);
      expect(
        animeBuilder.transitionDuration,
        classicBuilder.transitionDuration,
      );
      expect(
        animeBuilder.reverseTransitionDuration,
        classicBuilder.reverseTransitionDuration,
      );
    }

    final androidBuilder = anime.builders[TargetPlatform.android];
    expect(androidBuilder, isA<ZoomPageTransitionsBuilder>());
    final androidZoom = androidBuilder! as ZoomPageTransitionsBuilder;
    expect(androidZoom.allowSnapshotting, isTrue);
    expect(androidZoom.allowEnterRouteSnapshotting, isTrue);

    final appleBuilder = anime.builders[TargetPlatform.iOS];
    expect(appleBuilder, isA<CupertinoPageTransitionsBuilder>());
    expect(appleBuilder!.delegatedTransition, isNotNull);
  });

  testWidgets('anime 实际页面跳转不再插入专用转场包装', (tester) async {
    final observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime().copyWith(
          platform: TargetPlatform.android,
        ),
        navigatorObservers: [observer],
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
    observer.pushed.clear();

    await tester.tap(find.text('打开'));
    await tester.pump();

    expect(observer.pushed, hasLength(1));
    final route = observer.pushed.single as MaterialPageRoute<void>;
    final classicBuilder = AppThemeFactory.classic(
      Colors.pink,
    ).pageTransitionsTheme.builders[TargetPlatform.android]!;
    expect(route.transitionDuration, classicBuilder.transitionDuration);
    expect(
      route.reverseTransitionDuration,
      classicBuilder.reverseTransitionDuration,
    );
    expect(
      find.byKey(const ValueKey('anime_page_transition')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('anime_page_paint_gate')),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(find.text('目标页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) pushed.add(route);
  }
}
