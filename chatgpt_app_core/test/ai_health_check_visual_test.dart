import 'package:chatgpt_app_core/pages/ai_health_check_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
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

  testWidgets('健康检查在 anime 窄屏使用服务商卡且不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 760);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final store = AISettingsProvider();
    for (final provider in store.settings.providers) {
      provider.enabled = provider.models.isNotEmpty;
    }
    final provider = store.settings.enabledProviders.first;
    final model = provider.models.first;
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: store,
        child: MaterialApp(
          theme: AppThemeFactory.anime(),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(320, 760),
              textScaler: TextScaler.linear(1.25),
            ),
            child: AiHealthCheckPage(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(ValueKey('health_provider_${provider.id}')),
      findsOneWidget,
    );
    expect(find.text(provider.name), findsOneWidget);
    expect(find.text(model.name), findsOneWidget);
    expect(find.byTooltip('测试全部模型'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('健康检查经典模式保留原分组列表', (tester) async {
    final store = AISettingsProvider();
    for (final provider in store.settings.providers) {
      provider.enabled = provider.models.isNotEmpty;
    }
    final provider = store.settings.enabledProviders.first;
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: store,
        child: MaterialApp(
          theme: AppThemeFactory.classic(Colors.blue),
          home: const AiHealthCheckPage(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(ValueKey('health_provider_${provider.id}')),
      findsNothing,
    );
    expect(find.text('全部测试'), findsOneWidget);
  });
}
