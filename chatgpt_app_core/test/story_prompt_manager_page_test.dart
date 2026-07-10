import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_prompt_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    StoryRoomModel room, {
    List<String>? saved,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StoryPromptManagerPage(
          room: room,
          onSave: (next) async => saved?.add(next.promptConfigJson),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('展示固定与自定义摘要，房间规则始终锁定', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final room = StoryRoomModel(title: '雨夜书店');
    await pumpPage(tester, room);

    expect(find.text('固定 10 · 自定义 0 · 已启用 10'), findsOneWidget);
    expect(find.text('预览摘要：系统 8 条 · 对话内 2 条'), findsOneWidget);
    expect(find.text('房间规则'), findsOneWidget);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('prompt-toggle-builtin.rules')),
          )
          .onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('新增自定义模块，选择 in-chat depth 后保存房间', (tester) async {
    final room = StoryRoomModel(title: '雨夜书店');
    final saved = <String>[];
    await pumpPage(tester, room, saved: saved);

    await tester.tap(find.byTooltip('新增自定义模块'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-module-content')),
      '{{char}} 记得 {{room}} 的约定。',
    );
    await tester.tap(find.text('对话内'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('prompt-module-depth')),
      '3',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存模块'));
    await tester.pumpAndSettle();

    expect(find.text('固定 10 · 自定义 1 · 已启用 11'), findsOneWidget);

    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    final savedConfig = StoryPromptConfigCodec.decode(room.promptConfigJson);
    final custom = savedConfig.modules.last;
    expect(saved, [room.promptConfigJson]);
    expect(custom.content, '{{char}} 记得 {{room}} 的约定。');
    expect(custom.placement, StoryPromptPlacement.historyDepth);
    expect(custom.depth, 3);
  });

  testWidgets('可禁用固定模块并删除自定义模块', (tester) async {
    const config = StoryPromptConfig(modules: [
      ...StoryPromptConfigCodec.defaultModules,
      StoryPromptModule(key: 'custom-note', content: '删除我'),
    ]);
    final room = StoryRoomModel(
      title: '雨夜书店',
      promptConfigJson: StoryPromptConfigCodec.encode(config),
    );
    await pumpPage(tester, room);

    await tester.tap(
      find.byKey(const ValueKey('prompt-toggle-builtin.room')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('prompt-toggle-builtin.room')),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.byTooltip('模块操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除我'), findsNothing);
    expect(find.text('固定 10 · 自定义 0 · 已启用 9'), findsOneWidget);
  });
}
