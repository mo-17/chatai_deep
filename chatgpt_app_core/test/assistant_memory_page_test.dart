import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_memory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeAssistantMemoryDao dao;

  setUp(() {
    dao = _FakeAssistantMemoryDao();
  });

  Future<void> pumpPage(WidgetTester tester, AssistantModel assistant) async {
    await tester.pumpWidget(MaterialApp(
      home: AssistantMemoryPage(assistant: assistant, dao: dao),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('长期记忆页空态与新增记忆', (tester) async {
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    expect(find.textContaining('还没有长期记忆'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '记忆内容'), '用户喜欢简短回答');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('用户喜欢简短回答'), findsOneWidget);
    expect(find.textContaining('手动添加'), findsOneWidget);
  });

  testWidgets('长期记忆页新增时空内容会留在弹窗并提示', (tester) async {
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('新增长期记忆'), findsOneWidget);
    expect(find.text('请填写记忆内容'), findsOneWidget);
    expect(dao.items, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, '记忆内容'), '用户喜欢简短回答');
    await tester.pump();

    expect(find.text('请填写记忆内容'), findsNothing);
  });

  testWidgets('长期记忆页新增重复内容会提示并跳过保存', (tester) async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户喜欢简短回答',
      source: 'manual',
    ));
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.widgetWithText(TextField, '记忆内容'), ' 用户喜欢   简短回答 ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('这条长期记忆已存在'), findsOneWidget);
    expect(dao.items, hasLength(1));
    expect(find.text('用户喜欢简短回答'), findsOneWidget);
  });

  testWidgets('长期记忆页编辑和删除记忆', (tester) async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '旧记忆',
      source: 'user_message',
    ));
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    expect(find.text('旧记忆'), findsOneWidget);
    expect(find.textContaining('来自用户消息'), findsOneWidget);

    await tester.tap(find.text('旧记忆'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '记忆内容'), '新记忆');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('新记忆'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('还没有长期记忆'), findsOneWidget);
  });

  testWidgets('长期记忆页编辑原记忆保持同内容时允许保存', (tester) async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户喜欢简短回答',
      source: 'manual',
    ));
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    await tester.tap(find.text('用户喜欢简短回答'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '记忆内容'), '用户喜欢简短回答');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已更新长期记忆'), findsOneWidget);
    expect(dao.items, hasLength(1));
    expect(dao.items.single.content, '用户喜欢简短回答');
  });

  testWidgets('编辑不会丢失稳定身份、来源和 archived 生命周期', (tester) async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '已归档记忆',
      source: 'reply',
      memoryId: 'memory-stable-id',
      assistantSyncId: 'assistant-stable-id',
      sourceType: 'assistant_reply',
      sourceConversationId: '42',
      sourceMessageId: '1700000000000',
      status: AssistantMemoryStatus.archived,
      confirmedByUser: true,
      revision: 3,
      createdAt: 123456,
    ));
    final original = dao.items.single;
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    await tester.tap(find.text('已归档记忆'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, '记忆内容'), '归档后编辑');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    final saved = dao.items.single;
    expect(saved.id, original.id);
    expect(saved.assistantId, original.assistantId);
    expect(saved.source, 'reply');
    expect(saved.createdAt, 123456);
    expect(saved.memoryId, 'memory-stable-id');
    expect(saved.assistantSyncId, 'assistant-stable-id');
    expect(saved.sourceType, 'assistant_reply');
    expect(saved.sourceConversationId, '42');
    expect(saved.sourceMessageId, '1700000000000');
    expect(saved.status, AssistantMemoryStatus.archived);
    expect(saved.confirmedByUser, isTrue);
    expect(saved.revision, 3);
  });

  testWidgets('长期记忆页展示自动建议来源', (tester) async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户喜欢简短回答',
      source: 'suggestion',
    ));
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    expect(find.text('用户喜欢简短回答'), findsOneWidget);
    expect(find.textContaining('来自自动建议'), findsOneWidget);
  });

  testWidgets('长期记忆页展示摘要并支持按内容或来源搜索', (tester) async {
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户喜欢简短回答',
      source: 'manual',
    ));
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户正在写科幻小说',
      source: 'suggestion',
    ));
    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户提到浮岛城市',
      source: 'user_message',
    ));
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    expect(find.text('共 3 条 · 手动 1 · 自动建议 1 · 对话 1'), findsOneWidget);
    expect(find.text('用户喜欢简短回答'), findsOneWidget);
    expect(find.text('用户正在写科幻小说'), findsOneWidget);
    expect(find.text('用户提到浮岛城市'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '科幻');
    await tester.pumpAndSettle();

    expect(find.text('用户正在写科幻小说'), findsOneWidget);
    expect(find.text('用户喜欢简短回答'), findsNothing);
    expect(find.text('用户提到浮岛城市'), findsNothing);

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();

    expect(find.text('用户喜欢简短回答'), findsOneWidget);
    expect(find.text('用户正在写科幻小说'), findsOneWidget);
    expect(find.text('用户提到浮岛城市'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '来自用户消息');
    await tester.pumpAndSettle();

    expect(find.text('用户提到浮岛城市'), findsOneWidget);
    expect(find.text('用户正在写科幻小说'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '不存在');
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的长期记忆'), findsOneWidget);
  });

  testWidgets('长期记忆页可复制单条记忆正文', (tester) async {
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

    await dao.saveMemory(AssistantMemoryModel(
      assistantId: 1,
      content: '用户喜欢简短回答',
      source: 'manual',
    ));
    await pumpPage(tester, AssistantModel(id: 1, name: '艾琳'));

    await tester.tap(find.byTooltip('复制记忆'));
    await tester.pumpAndSettle();

    expect(copied, ['用户喜欢简短回答']);
    expect(find.text('长期记忆已复制'), findsOneWidget);
  });
}

class _FakeAssistantMemoryDao implements IAssistantMemory {
  final List<AssistantMemoryModel> _items = [];
  int _nextId = 1;

  List<AssistantMemoryModel> get items => List.unmodifiable(_items);

  @override
  Future<int> deleteMemory(int id) async {
    final before = _items.length;
    _items.removeWhere((item) => item.id == id);
    return before - _items.length;
  }

  @override
  Future<List<AssistantMemoryModel>> getMemories(int assistantId,
      {int limit = 20}) async {
    return _items
        .where((item) => item.assistantId == assistantId)
        .take(limit)
        .map((item) => AssistantMemoryModel.fromJson(item.toJson()))
        .toList();
  }

  @override
  Future<int?> saveMemory(AssistantMemoryModel model) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    model
      ..id ??= _nextId++
      ..createdAt = model.createdAt == 0 ? now : model.createdAt
      ..updatedAt = now;
    final index = _items.indexWhere((item) => item.id == model.id);
    final copy = AssistantMemoryModel.fromJson(model.toJson());
    if (index >= 0) {
      _items[index] = copy;
    } else {
      _items.insert(0, copy);
    }
    return model.id;
  }
}
