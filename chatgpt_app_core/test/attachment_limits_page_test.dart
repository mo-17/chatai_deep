import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const mib = 1024 * 1024;
  const charsTile = ValueKey('attachment_text_chars_setting');
  const charsField = ValueKey('attachment_text_chars_field');
  const sizeTile = ValueKey('attachment_text_file_size_setting');
  const sizeField = ValueKey('attachment_text_file_size_field');

  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });
  tearDown(AISettingsDao.resetSecureStateForTest);

  Future<void> openEditor(WidgetTester tester, AISettingsProvider provider,
      {required bool fileSize}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(home: AISettingsPage()),
    ));
    await tester.pumpAndSettle();
    final tile = fileSize ? sizeTile : charsTile;
    await tester.ensureVisible(find.byKey(tile));
    await tester.tap(find.byKey(tile));
    await tester.pumpAndSettle();
  }

  testWidgets('字符上限校验后保存，重载保留且不修改输入预算', (tester) async {
    final provider = AISettingsProvider();
    final budget = provider.settings.contextInputBudgetTokens;
    await openEditor(tester, provider, fileSize: false);
    expect(find.textContaining('PDF 抽取的文字'), findsOneWidget);
    expect(find.textContaining('应用输入预算'), findsWidgets);
    for (final invalid in ['0', '1023', '1048577', '12.5']) {
      await tester.enterText(find.byKey(charsField), invalid);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1024～1048576 之间的整数'), findsOneWidget);
      expect(provider.settings.attachmentTextMaxChars, 200000);
    }
    await tester.enterText(find.byKey(charsField), '500000');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.byKey(charsField), findsNothing);
    expect(find.textContaining('500000 字符'), findsOneWidget);
    expect(provider.settings.attachmentTextMaxChars, 500000);
    expect(provider.settings.contextInputBudgetTokens, budget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    AISettingsDao.resetSecureStateForTest();
    final loaded = await AISettingsDao.loadForAsync(provider.accountHash);
    expect(loaded.attachmentTextMaxChars, 500000);
    expect(loaded.contextInputBudgetTokens, budget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件大小按 MiB 编辑，校验并按字节保存小数值', (tester) async {
    final provider = AISettingsProvider();
    await openEditor(tester, provider, fileSize: true);
    for (final invalid in ['0', '0.99', '32.1', 'NaN', 'Infinity']) {
      await tester.enterText(find.byKey(sizeField), invalid);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1～32 之间的大小（MiB）'), findsOneWidget);
      expect(provider.settings.attachmentTextMaxFileBytes, 10 * mib);
    }
    await tester.enterText(find.byKey(sizeField), '12.5');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(provider.settings.attachmentTextMaxFileBytes, (12.5 * mib).round());
    expect(find.textContaining('12.5 MiB'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    AISettingsDao.resetSecureStateForTest();
    final loaded = await AISettingsDao.loadForAsync(provider.accountHash);
    expect(loaded.attachmentTextMaxFileBytes, (12.5 * mib).round());
    expect(tester.takeException(), isNull);
  });

  for (final fileSize in [false, true]) {
    testWidgets('取消保留值，恢复默认须保存（fileSize=$fileSize）', (tester) async {
      final provider = AISettingsProvider();
      await provider.update(provider.settings.clone()
        ..attachmentTextMaxChars = 500000
        ..attachmentTextMaxFileBytes = 20 * mib);
      await openEditor(tester, provider, fileSize: fileSize);
      final field = fileSize ? sizeField : charsField;
      final tile = fileSize ? sizeTile : charsTile;
      await tester.enterText(find.byKey(field), fileSize ? '3' : '8192');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(provider.settings.attachmentTextMaxChars, 500000);
      expect(provider.settings.attachmentTextMaxFileBytes, 20 * mib);
      await tester.tap(find.byKey(tile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '恢复默认'));
      await tester.pump();
      expect(tester.widget<TextFormField>(find.byKey(field)).controller!.text,
          fileSize ? '10' : '200000');
      expect(provider.settings.attachmentTextMaxChars, 500000);
      expect(provider.settings.attachmentTextMaxFileBytes, 20 * mib);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(
          provider.settings.attachmentTextMaxChars, fileSize ? 500000 : 200000);
      expect(provider.settings.attachmentTextMaxFileBytes,
          fileSize ? 10 * mib : 20 * mib);
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存失败回滚并显示错误（fileSize=$fileSize）', (tester) async {
      final provider = AISettingsProvider();
      await openEditor(tester, provider, fileSize: fileSize);
      AISettingsDao.plainWriteOverrideForTest = (_, __) async => false;
      await tester.enterText(find.byKey(fileSize ? sizeField : charsField),
          fileSize ? '20' : '500000');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(provider.settings.attachmentTextMaxChars, 200000);
      expect(provider.settings.attachmentTextMaxFileBytes, 10 * mib);
      expect(find.textContaining('设置未保存，请稍后重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
