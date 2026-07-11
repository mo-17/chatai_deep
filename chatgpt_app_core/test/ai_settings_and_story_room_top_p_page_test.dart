import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  Future<void> pumpWithSettings(
    WidgetTester tester,
    Widget page,
    AISettingsProvider provider,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AISettingsProvider>.value(
        value: provider,
        child: MaterialApp(home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('AI 设置页可启用并保存核采样 Top P', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = AISettingsProvider();
    await pumpWithSettings(tester, const AISettingsPage(), provider);

    await tester.tap(find.text('核采样 Top P'));
    await tester.pumpAndSettle();

    expect(find.text('启用 Top P'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).last).value, isFalse);

    await tester.tap(find.byType(Switch).last);
    await tester.pump();

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNotNull);
    slider.onChanged!(0.65);
    await tester.pump();
    expect(find.text('当前值：0.65'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '确定'));
    await tester.pumpAndSettle();

    expect(provider.settings.topP, 0.65);
    expect(find.text('top_p 0.65'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Tavern 房间菜单展示预设，模型设置显示 Top P', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final room = StoryRoomModel(
      id: 1,
      title: '酒馆测试房间',
      mode: StoryRoomMode.tavern,
      topP: 0.75,
    );
    final provider = AISettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AISettingsProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          home: StoryRoomPage(
            room: room,
            readAloudService: const NoopReadAloudService(),
            skipInitialLoadForTesting: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('房间设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Tavern 预设'), findsOneWidget);

    await tester.tap(find.text('模型与生成参数'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('模型与生成参数'), findsWidgets);
    expect(find.widgetWithText(TextField, 'Top P'), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.any((field) => field.controller?.text == '0.75'), isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
