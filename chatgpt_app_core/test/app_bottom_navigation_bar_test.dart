import 'package:chatgpt_app_core/pages/bottom_navigator.dart';
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

  testWidgets('经典与二次元风格使用各自的底部导航', (tester) async {
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
    await tester.tap(find.text('创作'));
    expect(selectedIndex, 2);
    expect(tester.takeException(), isNull);
  });
}
