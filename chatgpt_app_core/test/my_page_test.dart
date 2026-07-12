import 'package:chatgpt_app_core/pages/my_page.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  testWidgets('个人中心菜单在小屏下可滚动，不发生底部溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: const MaterialApp(home: MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 服务设置'), findsOneWidget);
    expect(find.text('外观与主题'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('检测更新'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('检测更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人中心可进入外观设置页', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(theme: provider.getTheme(), home: const MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('外观与主题'));
    await tester.pumpAndSettle();

    expect(find.text('界面风格'), findsOneWidget);
    expect(find.text('经典风格'), findsOneWidget);
    expect(find.text('梦幻二次元'), findsOneWidget);
  });

  testWidgets('anime 的 12 个二级页入口统一使用 classic 平台转场', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    final classicTransitions =
        AppThemeFactory.classic(Colors.pink).pageTransitionsTheme;
    final classicAndroidBuilder =
        classicTransitions.builders[TargetPlatform.android]!;
    expect(provider.getTheme().pageTransitionsTheme, classicTransitions);
    final observer = _RecordingNavigatorObserver();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme().copyWith(
                platform: TargetPlatform.android,
              ),
          navigatorObservers: [observer],
          home: const MyPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    observer.pushed.clear();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final scrollable = find.byType(Scrollable).first;
    const entries = [
      '外观与主题',
      'AI 服务设置',
      'MCP 服务',
      '助手管理',
      '知识库',
      '离线语音模型',
      'AI 能力中心',
      '用量统计',
      '生成图片相册',
      '工具审计',
      '跨设备云同步',
      '备份与恢复',
    ];

    for (final title in entries) {
      await tester.scrollUntilVisible(
        find.text(title),
        180,
        scrollable: scrollable,
      );
      await tester.pump();
      final inkWell = tester.widget<InkWell>(
        find
            .ancestor(of: find.text(title), matching: find.byType(InkWell))
            .first,
      );

      inkWell.onTap!();

      expect(observer.pushed, hasLength(1), reason: title);
      final route = observer.pushed.single;
      expect(route, isA<MaterialPageRoute<void>>(), reason: title);
      final materialRoute = route as MaterialPageRoute<void>;
      expect(
        materialRoute.transitionDuration,
        classicAndroidBuilder.transitionDuration,
        reason: title,
      );
      expect(
        materialRoute.reverseTransitionDuration,
        classicAndroidBuilder.reverseTransitionDuration,
        reason: title,
      );

      navigator.removeRoute(route);
      observer.pushed.clear();
      await tester.pump();
    }
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
