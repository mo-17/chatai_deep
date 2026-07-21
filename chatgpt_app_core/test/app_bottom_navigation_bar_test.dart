import 'package:chatgpt_app_core/pages/bottom_navigator.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
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

  testWidgets('经典与二次元风格使用各自的底部导航', (tester) async {
    final semantics = tester.ensureSemantics();
    final provider = ThemeProvider();
    var selectedIndex = -1;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: Consumer<ThemeProvider>(
          builder: (context, value, _) => MaterialApp(
            theme: value.getTheme(),
            themeAnimationDuration: Duration.zero,
            home: Scaffold(
              body: const SizedBox.expand(),
              bottomNavigationBar: AppBottomNavigationBar(
                currentIndex: 0,
                onSelected: (index) => selectedIndex = index,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('classic_bottom_navigation')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('anime_bottom_navigation')), findsNothing);
    await tester.tap(find.text('我的'));
    expect(selectedIndex, 3);

    provider.setVisualStyle(AppVisualStyle.anime);
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('anime_bottom_navigation')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('classic_bottom_navigation')), findsNothing);
    final destinations = tester.widgetList<NavigationDestination>(
      find.byType(NavigationDestination),
    ).toList();
    expect(destinations, hasLength(4));
    expect(
      (destinations[0].icon as StarcoreSvgIcon).assetName,
      StarcoreIconAssets.navChatDefault,
    );
    expect(
      (destinations[0].selectedIcon! as StarcoreSvgIcon).assetName,
      StarcoreIconAssets.navChatSelected,
    );
    expect(destinations[1].icon, isA<Icon>());
    expect(
      (destinations[2].icon as StarcoreSvgIcon).assetName,
      StarcoreIconAssets.navCreateDefault,
    );
    expect(
      (destinations[2].selectedIcon! as StarcoreSvgIcon).assetName,
      StarcoreIconAssets.navCreateSelected,
    );
    expect(destinations[3].icon, isA<Icon>());
    for (final label in ['聊天', '精彩', '创作', '我的']) {
      expect(find.bySemanticsLabel(RegExp(label)), findsOneWidget);
    }
    for (final assetName in [
      StarcoreIconAssets.navChatDefault,
      StarcoreIconAssets.navChatSelected,
      StarcoreIconAssets.navCreateDefault,
      StarcoreIconAssets.navCreateSelected,
    ]) {
      expect(find.bySemanticsLabel(RegExp(assetName)), findsNothing);
    }
    await tester.tap(find.text('我的'));
    expect(selectedIndex, 3);
    await tester.tap(find.text('创作'));
    expect(selectedIndex, 2);

    provider.setVisualStyle(AppVisualStyle.classic);
    await tester.pumpAndSettle();
    expect(find.byType(StarcoreSvgIcon), findsNothing);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
}
