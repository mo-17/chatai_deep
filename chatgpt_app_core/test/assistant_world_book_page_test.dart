import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester,
    AssistantModel assistant, {
    required List<String> saved,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: AssistantWorldBookPage(
        operationScope: AssistantOperationScope(
            accountHash: 'test',
            restoreRevision: 0,
            currentAccount: () => 'test',
            currentRestoreRevision: () => 0),
        assistant: assistant,
        onSave: (next) async => saved.add(next.memoryBook),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('世界书页空态与新增关键词设定', (tester) async {
    final assistant = AssistantModel(id: 1, name: '艾琳');
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    expect(find.textContaining('还没有世界书设定'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '触发关键词'), '钟声, 潮汐');
    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '钟声代表浮岛潮汐');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('钟声代表浮岛潮汐'), findsOneWidget);
    expect(find.text('启用 · 钟声 / 潮汐'), findsOneWidget);
    expect(assistant.memoryBook, '钟声, 潮汐 => 钟声代表浮岛潮汐');
    expect(saved.single, assistant.memoryBook);
  });

  testWidgets('世界书页新增时空设定内容会留在弹窗并提示', (tester) async {
    final assistant = AssistantModel(id: 1, name: '艾琳');
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '触发关键词'), '钟声');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('新增世界书设定'), findsOneWidget);
    expect(find.text('请填写设定内容'), findsOneWidget);
    expect(assistant.memoryBook, isEmpty);
    expect(saved, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '钟声代表潮汐');
    await tester.pump();

    expect(find.text('请填写设定内容'), findsNothing);
  });

  testWidgets('世界书页新增重复设定内容会提示并跳过保存', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '钟声 => 钟声代表浮岛潮汐',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '触发关键词'), '潮汐');
    await tester.enterText(
        find.widgetWithText(TextField, '设定内容'), '钟声代表   浮岛潮汐');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('这条世界书设定已存在'), findsOneWidget);
    expect(assistant.memoryBook, '钟声 => 钟声代表浮岛潮汐');
    expect(saved, isEmpty);
  });

  testWidgets('世界书页展示摘要并支持按关键词或内容搜索', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '''
城市由七座浮岛组成
[off] [p=8] 钟声 => 钟声代表潮汐
钥匙, 门 => 银钥匙可以打开塔门
''',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    expect(find.text('共 3 条 · 常驻 1 · 关键词 2 · 禁用 1'), findsOneWidget);
    expect(find.text('城市由七座浮岛组成'), findsOneWidget);
    expect(find.text('钟声代表潮汐'), findsOneWidget);
    expect(find.text('银钥匙可以打开塔门'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '钥匙');
    await tester.pumpAndSettle();

    expect(find.text('银钥匙可以打开塔门'), findsOneWidget);
    expect(find.text('钟声代表潮汐'), findsNothing);
    expect(find.text('城市由七座浮岛组成'), findsNothing);

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();

    expect(find.text('银钥匙可以打开塔门'), findsOneWidget);
    expect(find.text('钟声代表潮汐'), findsOneWidget);
    expect(find.text('城市由七座浮岛组成'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '不存在');
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的世界书设定'), findsOneWidget);
  });

  testWidgets('世界书页可输入一句话预览运行时命中的设定', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '''
城市由七座浮岛组成
[p=8] 钟声 => 钟声代表潮汐
[off] 雨夜 => 雨夜会触发旧书店记忆
''',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.enterText(
        find.widgetWithText(TextField, '输入一句话试触发世界书'), '今晚听见钟声');
    await tester.pumpAndSettle();

    expect(find.text('命中角色记忆 2 条（常驻 1 / 关键词 1）'), findsOneWidget);
    expect(find.text('常驻：城市由七座浮岛组成'), findsOneWidget);
    expect(find.text('钟声 · p=8：钟声代表潮汐'), findsOneWidget);
    expect(find.text('雨夜 · 已禁用：雨夜会触发旧书店记忆'), findsNothing);

    await tester.tap(find.byTooltip('复制命中世界书'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('命中角色记忆 2 条（常驻 1 / 关键词 1）'));
    expect(copied.single, contains('- 常驻：城市由七座浮岛组成'));
    expect(copied.single, contains('- 钟声 · p=8：钟声代表潮汐'));
    expect(find.text('命中世界书已复制'), findsOneWidget);

    await tester.tap(find.byTooltip('清空试触发'));
    await tester.pumpAndSettle();

    expect(find.text('命中角色记忆 2 条（常驻 1 / 关键词 1）'), findsNothing);

    await tester.enterText(
        find.widgetWithText(TextField, '输入一句话试触发世界书'), '完全无关的一句话');
    await tester.pumpAndSettle();

    expect(find.text('命中角色记忆 1 条（常驻 1 / 关键词 0）'), findsOneWidget);
    expect(find.text('常驻：城市由七座浮岛组成'), findsOneWidget);
  });

  testWidgets('世界书页可复制单条设定原始行', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '[off] [p=8] 钟声, 潮汐 => 钟声代表潮汐',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.tap(find.byTooltip('复制设定'));
    await tester.pumpAndSettle();

    expect(copied, ['[off] [p=8] 钟声, 潮汐 => 钟声代表潮汐']);
    expect(find.text('世界书设定已复制'), findsOneWidget);
  });

  testWidgets('世界书页编辑常驻设定并删除关键词设定', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '''
# 保留注释
城市由七座浮岛组成
钟声 => 钟声代表潮汐
''',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    expect(find.text('城市由七座浮岛组成'), findsOneWidget);
    expect(find.text('启用 · 常驻设定'), findsOneWidget);
    expect(find.text('钟声代表潮汐'), findsOneWidget);

    await tester.tap(find.text('城市由七座浮岛组成'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, '城市由八座浮岛组成');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('城市由八座浮岛组成'), findsOneWidget);
    expect(assistant.memoryBook, contains('# 保留注释'));
    expect(assistant.memoryBook, contains('城市由八座浮岛组成'));

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('钟声代表潮汐'), findsNothing);
    expect(assistant.memoryBook, isNot(contains('钟声 => 钟声代表潮汐')));
    expect(saved, hasLength(2));
  });

  testWidgets('世界书页可编辑启用状态和优先级', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '钟声 => 钟声代表潮汐',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.tap(find.text('钟声代表潮汐'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(SwitchListTile));
    await tester.enterText(find.widgetWithText(TextField, '优先级'), '12');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已禁用 · 钟声 · 优先级 12'), findsOneWidget);
    expect(assistant.memoryBook, '[off] [p=12] 钟声 => 钟声代表潮汐');
    expect(saved.single, assistant.memoryBook);
  });

  testWidgets('世界书页可编辑 Tavern 注入位置、扫描深度和触发概率', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook:
          '[exclude=白天|庆典] [pos=before_char] [depth=3] [prob=40] 钟楼 => 钟楼会在远处响起',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    expect(
      find.text('启用 · 钟楼 · 排除 白天 / 庆典 · 位置 before_char · 深度 3 · 概率 40%'),
      findsOneWidget,
    );

    await tester.tap(find.text('钟楼会在远处响起'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('角色人设前'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('角色人设前'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('角色人设后').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '排除关键词'), '雨天, 宴会');
    await tester.enterText(find.widgetWithText(TextField, '扫描深度'), '5');
    await tester.enterText(find.widgetWithText(TextField, '触发概率'), '120');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('启用 · 钟楼 · 排除 雨天 / 宴会 · 位置 after_char · 深度 5 · 概率 100%'),
      findsOneWidget,
    );
    expect(
      assistant.memoryBook,
      '[exclude=雨天|宴会] [pos=after_char] [depth=5] [prob=100] 钟楼 => 钟楼会在远处响起',
    );
    expect(saved.single, assistant.memoryBook);
  });

  testWidgets('世界书页编辑时保留 Tavern 高级元信息', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook:
          '[re] [cs] [ww] [sec=潮汐|浮岛] [exclude=白天] [p=12] [pos=after_char] [depth=3] [prob=40] [prob_disabled] [norec] [group=bell] [gw=7] [group_override] [group_scoring] [logic=3] [sticky=2] [cooldown=4] [delay=1] [characters=艾琳|船长] [characters_exclude] [persona] [character_description] [character_personality] [character_depth_prompt] [scenario] [creator_notes] 钟声 || Bell\\s+\\d+ => 钟声代表潮汐',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.tap(find.text('钟声代表潮汐'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '钟声代表新的潮汐');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      assistant.memoryBook,
      '[re] [cs] [ww] [sec=潮汐|浮岛] [p=12] [exclude=白天] [pos=after_char] [depth=3] [prob=40] [prob_disabled] [norec] [group=bell] [gw=7] [group_override] [group_scoring] [logic=3] [sticky=2] [cooldown=4] [delay=1] [characters=艾琳|船长] [characters_exclude] [persona] [character_description] [character_personality] [character_depth_prompt] [scenario] [creator_notes] 钟声 || Bell\\s+\\d+ => 钟声代表新的潮汐',
    );
    expect(assistant.worldBookJson, contains('"sticky":2'));
    expect(assistant.worldBookJson, contains('"matchScenario":true'));
    expect(saved.single, assistant.memoryBook);
  });

  testWidgets('世界书页编辑原设定保持同内容时允许保存', (tester) async {
    final assistant = AssistantModel(
      id: 1,
      name: '艾琳',
      memoryBook: '钟声 => 钟声代表潮汐',
    );
    final saved = <String>[];
    await pumpPage(tester, assistant, saved: saved);

    await tester.tap(find.text('钟声代表潮汐'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '钟声代表潮汐');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已更新世界书设定'), findsOneWidget);
    expect(saved.single, assistant.memoryBook);
  });
}
