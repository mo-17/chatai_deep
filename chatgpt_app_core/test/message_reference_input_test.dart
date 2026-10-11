import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  ComposerReference history() =>
      ComposerReference.history(HistoryMessageSnapshot(
          accountToken: AccountResourceScope.tokenFor('a'),
          conversationId: 1,
          messageId: 1,
          createdAt: 1,
          title: '资料',
          role: 'user',
          content: '资料正文',
          selectedAt: 2));

  for (final anime in [false, true]) {
    final style = anime ? '二次元' : '经典';
    Future<void> mount(
        WidgetTester tester, Widget Function(StateSetter) builder) async {
      final theme = ThemeProvider();
      if (anime) theme.setVisualStyle(AppVisualStyle.anime);
      addTearDown(theme.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: theme,
          child: MaterialApp(
              theme: theme.getTheme(),
              home: Scaffold(
                  body: StatefulBuilder(
                      builder: (_, setState) => Align(
                          alignment: Alignment.bottomCenter,
                          child: builder(setState)))))));
    }

    testWidgets('$style：纯选区与 composing 通知不产生正文回调，编辑仍通知', (tester) async {
      final controller = TextEditingController(text: '合成草稿');
      addTearDown(controller.dispose);
      final changes = <String>[];
      await mount(
          tester,
          (_) => MessageInputWidget('输入',
              controller: controller,
              speechInputEnabled: false,
              referencesEnabled: true,
              onChanged: changes.add));
      expect(changes, ['合成草稿']);
      changes.clear();
      controller.selection = const TextSelection.collapsed(offset: 1);
      controller.value = controller.value
          .copyWith(composing: const TextRange(start: 0, end: 2));
      controller.value = controller.value.copyWith(
          composing: TextRange.empty,
          selection: const TextSelection(baseOffset: 0, extentOffset: 2));
      await tester.pump();
      expect(changes, isEmpty);
      controller.text = '新的草稿';
      await tester.pump();
      expect(changes, ['新的草稿']);
    });

    testWidgets('$style：触发取消保留@，确认引用才删触发符，标签预览删除且不发送', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var references = <ComposerReference>[];
      var sends = 0;
      await mount(
          tester,
          (setState) => MessageInputWidget('输入',
              controller: controller,
              referencesEnabled: true,
              referenceScopeKey: 'a:1',
              speechInputEnabled: false,
              references: references,
              clearOnSend: false,
              onSend: () => sends++,
              pickHistoryReference: () async => history(),
              onReferencePicked: (reference) =>
                  setState(() => references = [reference]),
              onRemoveReference: (_) => setState(() => references = [])));
      await tester.tap(find.byType(TextField));
      controller.value = const TextEditingValue(
          text: '', selection: TextSelection.collapsed(offset: 0));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: '@', selection: TextSelection.collapsed(offset: 1)));
      await tester.pumpAndSettle();
      expect(find.text('添加引用'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.text, '@');
      controller.value = const TextEditingValue(
          text: '问题 ', selection: TextSelection.collapsed(offset: 3));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: '问题 @', selection: TextSelection.collapsed(offset: 4)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@历史消息'));
      await tester.pumpAndSettle();
      expect(controller.text, '问题 ');
      expect(references, hasLength(1));
      expect(sends, 0);
      await tester.tap(
          find.byKey(ValueKey('preview_reference_${references.single.id}')));
      await tester.pumpAndSettle();
      expect(find.text('资料正文'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(ValueKey('remove_reference_${references.single.id}')));
      await tester.pumpAndSettle();
      expect(references, isEmpty);
      expect(sends, 0);
    });

    testWidgets('$style：旧草稿、邮箱、IME及单字符键盘粘贴不弹选择器', (tester) async {
      final controller = TextEditingController(text: '@旧草稿');
      addTearDown(controller.dispose);
      await mount(
          tester,
          (_) => MessageInputWidget('输入',
              controller: controller,
              referencesEnabled: true,
              referenceScopeKey: 'a:1',
              speechInputEnabled: false));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('添加引用'), findsNothing);
      controller.value = const TextEditingValue(
          text: 'user', selection: TextSelection.collapsed(offset: 4));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: 'user@', selection: TextSelection.collapsed(offset: 5)));
      await tester.pumpAndSettle();
      expect(find.text('添加引用'), findsNothing);
      controller.value = const TextEditingValue(
          text: '', selection: TextSelection.collapsed(offset: 0));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: '@',
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange(start: 0, end: 1)));
      await tester.pumpAndSettle();
      expect(find.text('添加引用'), findsNothing);
      controller.clear();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async =>
              call.method == 'Clipboard.getData' ? {'text': '@'} : null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(controller.text, '@');
      expect(find.text('添加引用'), findsNothing);
    });

    testWidgets('$style：迟到选择不能覆盖新输入或跨账号会话，320px标签不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController(text: '当前输入');
      addTearDown(controller.dispose);
      var pending = Completer<ComposerReference?>();
      var scope = 'a:1';
      var picks = 0;
      late StateSetter change;
      await mount(tester, (setState) {
        change = setState;
        return MessageInputWidget('输入',
            controller: controller,
            referencesEnabled: true,
            referenceScopeKey: scope,
            speechInputEnabled: false,
            pickHistoryReference: () => pending.future,
            onReferencePicked: (_) => picks++,
            references: [history()]);
      });
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@历史消息'));
      await tester.pumpAndSettle();
      controller.text = '后来的草稿';
      pending.complete(history());
      await tester.pumpAndSettle();
      expect(picks, 0);
      expect(controller.text, '后来的草稿');
      pending = Completer<ComposerReference?>();
      await tester.tap(find.byKey(const ValueKey('composer_reference_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@历史消息'));
      await tester.pumpAndSettle();
      change(() => scope = 'b:2');
      await tester.pump();
      pending.complete(history());
      await tester.pumpAndSettle();
      expect(picks, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
