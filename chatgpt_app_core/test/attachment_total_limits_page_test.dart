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
  const charsTile = ValueKey('attachment_total_chars_setting');
  const charsField = ValueKey('attachment_total_chars_field');
  const sizeTile = ValueKey('attachment_total_file_size_setting');
  const sizeField = ValueKey('attachment_total_file_size_field');

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
    final tile = find.byKey(fileSize ? sizeTile : charsTile);
    await tester.scrollUntilVisible(tile, 250,
        scrollable: find.byType(Scrollable).first);
    // find 命中含缓存区域的 ListTile 并不保证其中心可点击；明确居中再点。
    await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('每轮总字数校验、持久化与重载，不影响单附件及Token预算', (tester) async {
    final provider = AISettingsProvider();
    final budget = provider.settings.contextInputBudgetTokens;
    await openEditor(tester, provider, fileSize: false);
    expect(find.textContaining('附件数量不限'), findsOneWidget);
    expect(find.textContaining('任务模式按本轮导入原文计'), findsWidgets);
    expect(find.textContaining('图片和原生 PDF 不计入字数'), findsOneWidget);
    for (final invalid in ['0', '1023', '4194305', '12.5']) {
      await tester.enterText(find.byKey(charsField), invalid);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1024～4194304 之间的整数'), findsOneWidget);
      expect(provider.settings.attachmentTotalMaxChars, 1000000);
    }
    await tester.enterText(find.byKey(charsField), '4194304');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(provider.settings.attachmentTotalMaxChars, 4194304);
    expect(provider.settings.attachmentTextMaxChars, 200000);
    expect(provider.settings.contextInputBudgetTokens, budget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    AISettingsDao.resetSecureStateForTest();
    final loaded = await AISettingsDao.loadForAsync(provider.accountHash);
    expect(loaded.attachmentTotalMaxChars, 4194304);
    expect(loaded.contextInputBudgetTokens, budget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('每轮总大小按MiB校验，保存小数与上下边界', (tester) async {
    final provider = AISettingsProvider();
    await openEditor(tester, provider, fileSize: true);
    expect(find.textContaining('图片和文件的原始大小合计'), findsOneWidget);
    for (final invalid in ['0', '0.99', '256.1', 'NaN', 'Infinity']) {
      await tester.enterText(find.byKey(sizeField), invalid);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1～256 之间的大小（MiB）'), findsOneWidget);
      expect(provider.settings.attachmentTotalMaxFileBytes, 64 * mib);
    }
    await tester.enterText(find.byKey(sizeField), '128.5');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(
        provider.settings.attachmentTotalMaxFileBytes, (128.5 * mib).round());
    expect(provider.settings.attachmentTextMaxFileBytes, 10 * mib);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    AISettingsDao.resetSecureStateForTest();
    final loaded = await AISettingsDao.loadForAsync(provider.accountHash);
    expect(loaded.attachmentTotalMaxFileBytes, (128.5 * mib).round());
    expect(tester.takeException(), isNull);
  });

  for (final fileSize in [false, true]) {
    testWidgets('汇总设置取消保留值，恢复默认须保存（fileSize=$fileSize）', (tester) async {
      final provider = AISettingsProvider();
      await provider.update(provider.settings.clone()
        ..attachmentTotalMaxChars = 2000000
        ..attachmentTotalMaxFileBytes = 128 * mib);
      await openEditor(tester, provider, fileSize: fileSize);
      final field = fileSize ? sizeField : charsField;
      final tile = fileSize ? sizeTile : charsTile;
      await tester.enterText(find.byKey(field), fileSize ? '1' : '1024');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(provider.settings.attachmentTotalMaxChars, 2000000);
      expect(provider.settings.attachmentTotalMaxFileBytes, 128 * mib);
      await tester.tap(find.byKey(tile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '恢复默认'));
      await tester.pump();
      expect(tester.widget<TextFormField>(find.byKey(field)).controller!.text,
          fileSize ? '64' : '1000000');
      expect(provider.settings.attachmentTotalMaxChars, 2000000);
      expect(provider.settings.attachmentTotalMaxFileBytes, 128 * mib);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(provider.settings.attachmentTotalMaxChars,
          fileSize ? 2000000 : 1000000);
      expect(provider.settings.attachmentTotalMaxFileBytes,
          fileSize ? 64 * mib : 128 * mib);
      expect(tester.takeException(), isNull);
    });

    testWidgets('汇总设置保存失败回滚并显示错误（fileSize=$fileSize）', (tester) async {
      final provider = AISettingsProvider();
      await openEditor(tester, provider, fileSize: fileSize);
      AISettingsDao.plainWriteOverrideForTest = (_, __) async => false;
      await tester.enterText(find.byKey(fileSize ? sizeField : charsField),
          fileSize ? '256' : '4194304');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(provider.settings.attachmentTotalMaxChars, 1000000);
      expect(provider.settings.attachmentTotalMaxFileBytes, 64 * mib);
      expect(find.textContaining('设置未保存，请稍后重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
