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

  testWidgets('全局背景只在二次元风格启用并可恢复经典', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: Consumer<ThemeProvider>(
          builder: (context, value, _) => MaterialApp(
            theme: value.getTheme(),
            themeAnimationDuration: Duration.zero,
            builder: (context, child) => AppVisualBackdrop(
              child: child ?? const SizedBox.shrink(),
            ),
            home: const Scaffold(body: Text('页面内容')),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('anime_app_backdrop')), findsNothing);

    provider.setVisualStyle(AppVisualStyle.anime);
    await tester.pump();
    expect(find.byKey(const ValueKey('anime_app_backdrop')), findsOneWidget);
    expect(Theme.of(tester.element(find.text('页面内容'))).scaffoldBackgroundColor,
        Colors.transparent);

    provider.setVisualStyle(AppVisualStyle.classic);
    await tester.pump();
    expect(find.byKey(const ValueKey('anime_app_backdrop')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
