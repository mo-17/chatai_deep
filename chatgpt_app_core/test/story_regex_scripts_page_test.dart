import 'dart:convert';

import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_regex_scripts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('可新增规则、编辑 flags、预览并保存到房间', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final room = StoryRoomModel(id: 7, title: '雨夜');
    StoryRoomModel? savedRoom;

    await tester.pumpWidget(
      MaterialApp(
        home: StoryRegexScriptsPage(
          room: room,
          onSave: (value) async => savedRoom = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const PageStorageKey<String>('story_regex_stage_userInput')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const PageStorageKey<String>('story_regex_stage_assistantOutput'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const PageStorageKey<String>('story_regex_stage_assistantDisplay'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('story_regex_scripts_add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('story_regex_script_name')),
      '去掉感叹号',
    );
    await tester.enterText(
      find.byKey(const ValueKey('story_regex_script_find')),
      r'!+',
    );
    await tester.enterText(
      find.byKey(const ValueKey('story_regex_script_replace')),
      '',
    );
    await tester
        .tap(find.byKey(const ValueKey('story_regex_script_editor_save')));
    await tester.pumpAndSettle();

    expect(find.text('去掉感叹号'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('story_regex_preview_input')));
    await tester.enterText(
      find.byKey(const ValueKey('story_regex_preview_input')),
      '你好!!',
    );
    await tester.tap(find.byKey(const ValueKey('story_regex_preview_run')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    expect(find.text('处理后文本'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.textContaining('命中 1'), findsOneWidget);

    final editButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '编辑规则',
    );
    await tester.scrollUntilVisible(
      editButton,
      300,
      maxScrolls: 20,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(editButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('story_regex_script_case_sensitive')),
        findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('story_regex_script_case_sensitive')),
    );
    await tester
        .tap(find.byKey(const ValueKey('story_regex_script_editor_save')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('story_regex_scripts_save')));
    await tester.pumpAndSettle();
    expect(savedRoom, same(room));
    final saved = StoryRegexScriptsCodec.decode(room.regexScriptsJson);
    expect(saved.rules.single.name, '去掉感叹号');
    expect(saved.rules.single.caseSensitive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('三阶段规则可启停、上下排序和删除，390px 不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final room = StoryRoomModel(
      title: '房间',
      regexScriptsJson: StoryRegexScriptsCodec.encode(
        const StoryRegexScripts(
          rules: [
            StoryRegexScript(
              key: 'a',
              name: '第一条',
              stage: StoryRegexStage.userInput,
              find: 'a',
              replace: 'A',
              sortOrder: 0,
            ),
            StoryRegexScript(
              key: 'b',
              name: '第二条',
              stage: StoryRegexStage.userInput,
              find: 'b',
              replace: 'B',
              sortOrder: 1,
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoryRegexScriptsPage(room: room, onSave: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('story_regex_rule_enabled_a')));
    await tester.tap(find.byKey(const ValueKey('story_regex_rule_down_a')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('story_regex_rule_enabled_a')),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('story_regex_rule_delete_b')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('第二条'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('story_regex_scripts_save')));
    await tester.pumpAndSettle();
    final saved = StoryRegexScriptsCodec.decode(room.regexScriptsJson);
    expect(saved.rules.single.key, 'a');
    expect(saved.rules.single.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则数量达到上限时新增显示 snackbar，保存异常显示 snackbar', (tester) async {
    final rules = [
      for (var index = 0; index < StoryRegexScriptLimits.maxRules; index++)
        StoryRegexScript(
          key: 'rule-$index',
          name: '规则 $index',
          stage: StoryRegexStage.assistantDisplay,
          find: 'x',
        ),
    ];
    final room = StoryRoomModel(
      title: '上限',
      regexScriptsJson:
          StoryRegexScriptsCodec.encode(StoryRegexScripts(rules: rules)),
    );
    var saveCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StoryRegexScriptsPage(
          room: room,
          onSave: (_) async {
            saveCalled = true;
            throw StateError('disk full');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('story_regex_scripts_add')));
    await tester.pump();
    expect(find.text('最多创建 64 条规则'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(const ValueKey('story_regex_scripts_save')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(saveCalled, isTrue);
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect((snackBar.content as Text).data, contains('保存失败：'));
    expect(jsonDecode(room.regexScriptsJson)['rules'], hasLength(64));
    expect(tester.takeException(), isNull);
  });
}
