import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });
  tearDown(AISettingsDao.resetSecureStateForTest);

  const tile = ValueKey('context_input_budget_setting');
  const field = ValueKey('context_input_budget_field');

  Future<void> openEditor(
      WidgetTester tester, AISettingsProvider provider) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(home: AISettingsPage()),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(tile));
    await tester.tap(find.byKey(tile));
    await tester.pumpAndSettle();
  }

  testWidgets('invalid input stays in the editor; valid budget survives reload',
      (tester) async {
    final provider = AISettingsProvider();
    final outputTokens = provider.settings.maxOutputTokens;
    await openEditor(tester, provider);

    await tester.enterText(find.byKey(field), '0');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1024～1048576 之间的整数'), findsOneWidget);
    expect(find.byKey(field), findsOneWidget);
    expect(provider.settings.effectiveContextInputBudgetTokens, 262144);

    await tester.enterText(find.byKey(field), '65536');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.byKey(field), findsNothing);
    expect(find.textContaining('65536 Token'), findsOneWidget);
    expect(provider.settings.contextInputBudgetTokens, 65536);
    expect(provider.settings.maxOutputTokens, outputTokens);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    AISettingsDao.resetSecureStateForTest();
    final reloaded = await AISettingsDao.loadForAsync(provider.accountHash);
    expect(reloaded.contextInputBudgetTokens, 65536);
    expect(reloaded.maxOutputTokens, outputTokens);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel keeps the saved value; restore default requires save',
      (tester) async {
    final provider = AISettingsProvider();
    await provider
        .update(provider.settings.clone()..contextInputBudgetTokens = 131072);
    await openEditor(tester, provider);
    await tester.enterText(find.byKey(field), '8192');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(provider.settings.contextInputBudgetTokens, 131072);

    await tester.tap(find.byKey(tile));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(field)).controller!.text,
        '131072');
    await tester.tap(find.widgetWithText(TextButton, '恢复默认'));
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byKey(field)).controller!.text,
        '${AISettings.defaultContextInputBudgetTokens}');
    expect(provider.settings.contextInputBudgetTokens, 131072);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(provider.settings.contextInputBudgetTokens, 262144);
    expect(find.textContaining('262144 Token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed persistence rolls back and tells the user',
      (tester) async {
    final provider = AISettingsProvider();
    await openEditor(tester, provider);
    AISettingsDao.plainWriteOverrideForTest = (_, __) async => false;
    await tester.enterText(find.byKey(field), '65536');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(provider.settings.effectiveContextInputBudgetTokens, 262144);
    expect(find.textContaining('设置未保存，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
