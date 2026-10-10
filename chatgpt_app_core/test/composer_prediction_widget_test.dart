import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    AISettingsDao.resetSecureStateForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
  });
  tearDown(AISettingsDao.resetSecureStateForTest);

  test('按账号保存开关，重读保留且另一账号默认关闭', () async {
    final settings = AISettings.defaults()..composerPredictionsEnabled = true;
    await AISettingsDao.saveFor('prediction-a', settings);
    expect(
        (await AISettingsDao.loadForAsync('prediction-a'))
            .composerPredictionsEnabled,
        isTrue);
    expect(
        (await AISettingsDao.loadForAsync('prediction-b'))
            .composerPredictionsEnabled,
        isFalse);
    settings.composerPredictionsEnabled = false;
    await AISettingsDao.saveFor('prediction-a', settings);
    expect(
        (await AISettingsDao.loadForAsync('prediction-a'))
            .composerPredictionsEnabled,
        isFalse);
  });

  testWidgets('设置页默认关闭，解释费用与草稿边界，开关保存', (tester) async {
    final settings = AISettingsProvider();
    addTearDown(settings.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: settings, child: const MaterialApp(home: AISettingsPage())));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('composer_predictions_setting'));
    await tester.scrollUntilVisible(tile, 250,
        scrollable: find.byType(Scrollable).first);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.textContaining('额外消耗模型用量'), findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(settings.settings.composerPredictionsEnabled, isTrue);
    final restored = AISettingsProvider();
    expect(restored.settings.composerPredictionsEnabled, isTrue);
    restored.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final anime in [false, true]) {
    testWidgets('${anime ? '二次元' : '经典'}：建议采纳仅填入，不抢 Tab，不覆盖草稿和输入法',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = ThemeProvider();
      if (anime) theme.setVisualStyle(AppVisualStyle.anime);
      addTearDown(theme.dispose);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var sent = 0;
      var accepted = 0;
      const suggestion = '请给一个具体例子。';
      Future<void> mount(
          {bool streaming = false, List<String> files = const []}) async {
        await tester.pumpWidget(ChangeNotifierProvider.value(
            value: theme,
            child: MaterialApp(
                theme: theme.getTheme(),
                home: Scaffold(
                    body: MessageInputWidget('请输入',
                        controller: controller,
                        speechInputEnabled: false,
                        isStreaming: streaming,
                        pendingFiles: files,
                        suggestedMessage: suggestion,
                        onAcceptSuggestion: () {
                          accepted++;
                          controller.text = suggestion;
                        },
                        onDismissSuggestion: () {},
                        onSend: () => sent++)))));
        await tester.pump();
      }

      await mount();
      final accept = find.byKey(const ValueKey('accept_composer_prediction'));
      expect(accept, findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(controller.text, isEmpty);
      expect(accepted, 0);
      await tester.tap(accept);
      await tester.pump();
      expect(controller.text, suggestion);
      expect(sent, 0);
      expect(accept, findsNothing);
      controller.value = const TextEditingValue(
          text: '拼音', composing: TextRange(start: 0, end: 2));
      await tester.pump();
      expect(accept, findsNothing);
      controller.clear();
      await tester.pump();
      await mount(streaming: true);
      expect(accept, findsNothing);
      await mount(files: ['test.txt']);
      expect(accept, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
