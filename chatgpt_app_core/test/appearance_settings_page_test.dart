import 'package:chatgpt_app_core/pages/appearance_settings_page.dart';
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

  testWidgets('可在二次元和经典风格间往返切换', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: Consumer<ThemeProvider>(
          builder: (context, value, _) => MaterialApp(
            theme: value.getTheme(),
            themeAnimationDuration: Duration.zero,
            home: const AppearanceSettingsPage(),
          ),
        ),
      ),
    );

    expect(provider.visualStyle, AppVisualStyle.classic);
    expect(find.byKey(const ValueKey('classic_color_section')), findsOneWidget);
    expect(find.byKey(const ValueKey('anime_style_section')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('visual_style_anime')));
    await tester.pumpAndSettle();

    expect(provider.visualStyle, AppVisualStyle.anime);
    expect(find.byKey(const ValueKey('anime_style_section')), findsOneWidget);
    expect(find.byKey(const ValueKey('restore_classic_style')), findsOneWidget);
    final animeTheme =
        Theme.of(tester.element(find.byType(AppearanceSettingsPage)));
    expect(animeTheme.extension<AppVisualTheme>()?.isAnime, isTrue);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('restore_classic_style')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('restore_classic_style')));
    await tester.pumpAndSettle();

    expect(provider.visualStyle, AppVisualStyle.classic);
    expect(find.byKey(const ValueKey('classic_color_section')), findsOneWidget);
    expect(provider.themeColorName, 'pink');
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏和放大文字下设置页仍可滚动', (tester) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          themeAnimationDuration: Duration.zero,
          home: const AppearanceSettingsPage(),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('classic_theme_color_grey')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('classic_theme_color_grey')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('系统要求减少动态效果时关闭外观页动画', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          home: const AppearanceSettingsPage(),
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    final containers = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(switcher.duration, Duration.zero);
    expect(containers, isNotEmpty);
    expect(
        containers.every((widget) => widget.duration == Duration.zero), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('横屏下风格卡与恢复入口不溢出', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          themeAnimationDuration: Duration.zero,
          home: const AppearanceSettingsPage(),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('restore_classic_style')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('restore_classic_style')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
