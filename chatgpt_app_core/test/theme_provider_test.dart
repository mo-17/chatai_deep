import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  test('无缓存时使用经典风格和原有樱粉强调色', () {
    final provider = ThemeProvider();

    expect(provider.visualStyle, AppVisualStyle.classic);
    expect(provider.themeColorName, 'pink');
    expect(provider.themeColor, Colors.pink);
    expect(
      provider.getTheme().extension<AppVisualTheme>()?.style,
      AppVisualStyle.classic,
    );
  });

  test('风格切换会持久化，且不会覆盖经典强调色', () {
    final provider = ThemeProvider();
    var notifications = 0;
    provider.addListener(() => notifications += 1);

    provider.setTheme(colorName: 'indigo');
    provider.setVisualStyle(AppVisualStyle.anime);

    expect(notifications, 2);
    expect(provider.themeColorName, 'indigo');
    expect(
        provider.getTheme().colorScheme.primary, AppThemeFactory.animePrimary);
    expect(
      provider.getTheme().extension<AppVisualTheme>()?.style,
      AppVisualStyle.anime,
    );
    expect(
      HiCache.getInstance().get<String>(ThemeProvider.keyVisualStyle),
      'anime',
    );

    final restored = ThemeProvider();
    expect(restored.visualStyle, AppVisualStyle.anime);
    expect(restored.themeColorName, 'indigo');

    restored.setVisualStyle(AppVisualStyle.classic);
    final legacyTheme = ThemeData(primarySwatch: Colors.indigo);
    expect(
      restored.getTheme().colorScheme.primary,
      legacyTheme.colorScheme.primary,
    );
    expect(restored.themeColorName, 'indigo');
  });

  test('未知缓存值安全回退经典风格和樱粉', () {
    HiCache.getInstance()
      ..setString(ThemeProvider.keyVisualStyle, 'future-style')
      ..setString(ThemeProvider.keyThemeColor, 'not-a-color');

    final provider = ThemeProvider();

    expect(provider.visualStyle, AppVisualStyle.classic);
    expect(provider.themeColorName, 'pink');
    expect(provider.themeColor, Colors.pink);
  });
}
