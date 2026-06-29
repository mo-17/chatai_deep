import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// L3a（只读上下文工具）验收：搜历史 / 列会话 / 读收藏 / 读会话消息，
/// 走真实 DAO + ToolActionContext（注入 ffi 内存库）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late HiDBManager storage;
  // 工具上下文：始终返回这套已 seed 的内存库。
  ToolActionContext ctx() =>
      ToolActionContext(openStorage: () async => storage);

  setUp(() async {
    storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(ConversationModel(cid: 100, icon: '')
      ..title = 'K8s 学习笔记'
      ..stickTime = 0
      ..messageCount = 2
      ..updateAt = 200);
    await convDao.saveConversation(ConversationModel(cid: 101, icon: '')
      ..title = '随便聊聊'
      ..stickTime = 0
      ..updateAt = 100);
    await MessageDao.create(storage, cid: 100);
    await storage.db.insert('tb_messages', {
      'cid': 100,
      'content': 'K8s 的 Pod 是什么',
      'createdAt': 1,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await storage.db.insert('tb_messages', {
      'cid': 100,
      'content': 'Pod 是 K8s 最小调度单元',
      'createdAt': 2,
      'ownerName': 'AI',
      'ownerType': 'receiver',
    });
    await FavoriteDao.create(storage);
    await storage.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '收藏：K8s 速查', 'createdAt': 3});
  });

  tearDown(() async => storage.db.close());

  test('search_chat_history：命中关键词，返回会话标题 + 片段', () async {
    final out =
        await BuiltinTools.searchChatHistory(ctx()).execute({'query': 'Pod'});
    final list = jsonDecode(out.content) as List;
    expect(list.length, 2);
    expect(list.first['conversation'], 'K8s 学习笔记');
    expect(list.any((e) => (e['snippet'] as String).contains('Pod')), isTrue);
  });

  test('search_chat_history：无命中给出友好提示', () async {
    final out = await BuiltinTools.searchChatHistory(ctx())
        .execute({'query': '不存在的词xyz'});
    expect(out.content, contains('没有找到'));
  });

  test('list_conversations：按 updateAt 倒序返回概览', () async {
    final out = await BuiltinTools.listConversations(ctx()).execute({});
    final list = jsonDecode(out.content) as List;
    expect(list.map((e) => e['title']), ['K8s 学习笔记', '随便聊聊']);
    expect(list.first['cid'], 100);
  });

  test('list_conversations：支持按 projectId 过滤', () async {
    await storage.db.update(
      'tb_conversation_list',
      {'projectId': 1},
      where: 'cid = ?',
      whereArgs: [100],
    );
    await storage.db.update(
      'tb_conversation_list',
      {'projectId': 2},
      where: 'cid = ?',
      whereArgs: [101],
    );

    final out =
        await BuiltinTools.listConversations(ctx()).execute({'projectId': 1});
    final list = jsonDecode(out.content) as List;
    expect(list.length, 1);
    expect(list.single['cid'], 100);
  });

  test('list_favorites：返回收藏内容', () async {
    final out = await BuiltinTools.listFavorites(ctx()).execute({});
    final list = jsonDecode(out.content) as List;
    expect(list.single['content'], contains('K8s 速查'));
  });

  test('get_conversation_messages：按 cid 返回消息（role 映射）', () async {
    final out =
        await BuiltinTools.getConversationMessages(ctx()).execute({'cid': 100});
    final list = jsonDecode(out.content) as List;
    expect(list.length, 2);
    expect(list.first['role'], 'user');
    expect(list.last['role'], 'assistant');
  });

  test('get_conversation_messages：cid 无消息时提示', () async {
    final out =
        await BuiltinTools.getConversationMessages(ctx()).execute({'cid': 999});
    expect(out.content, contains('没有消息'));
  });

  test('search_chat_history：支持按 projectId 过滤', () async {
    await storage.db.update(
      'tb_conversation_list',
      {'projectId': 1},
      where: 'cid = ?',
      whereArgs: [100],
    );
    await storage.db.update(
      'tb_conversation_list',
      {'projectId': 2},
      where: 'cid = ?',
      whereArgs: [101],
    );
    await storage.db.insert('tb_messages', {
      'cid': 101,
      'content': 'Pod 是另一个项目里提到的内容',
      'createdAt': 4,
      'ownerName': 'user',
      'ownerType': 'sender',
    });

    final out1 = await BuiltinTools.searchChatHistory(ctx())
        .execute({'query': 'Pod', 'projectId': 1});
    final list1 = jsonDecode(out1.content) as List;
    expect(list1.length, 2);
    expect(list1.any((e) => e['cid'] == 100), isTrue);
    expect(list1.every((e) => e['projectId'] == 1), isTrue);

    final out2 = await BuiltinTools.searchChatHistory(ctx())
        .execute({'query': 'Pod', 'projectId': 2});
    final list2 = jsonDecode(out2.content) as List;
    expect(list2.length, 1);
    expect(list2.single['cid'], 101);
  });

  test('fromAssistant：绑定只读工具且提供 actions 时装配', () {
    final r = ToolRegistry.fromAssistant(
      AISettings.defaults(),
      const ['search_chat_history', 'list_conversations'],
      actions: ctx(),
    );
    expect(r.byName('search_chat_history'), isNotNull);
    expect(r.byName('list_conversations'), isNotNull);
  });

  test('fromAssistant：缺 actions 时只读工具不装配', () {
    final r = ToolRegistry.fromAssistant(
        AISettings.defaults(), const ['search_chat_history']);
    expect(r.isEmpty, isTrue);
  });
}
