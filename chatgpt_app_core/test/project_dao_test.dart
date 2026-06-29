import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));

  test('旧会话表自动补 projectId，旧数据读取为未分类', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer);');
    await storage.db.insert('tb_conversation_list', {
      'cid': 1,
      'title': '旧会话',
      'icon': '',
      'stickTime': 0,
      'updateAt': 1,
    });

    final dao = await ConversationListDao.create(storage);
    final all = await dao.getConversationList();
    final unclassified = await dao.getConversationList(uncategorized: true);

    expect(all.single.projectId, isNull);
    expect(unclassified.single.title, '旧会话');
    await storage.db.close();
  });

  test('按项目筛选会话，并统计项目会话数', () async {
    final storage = await newDb();
    final projectDao = await ProjectDao.create(storage);
    final project = ProjectModel(name: '产品');
    await projectDao.saveProject(project);
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(
        ConversationModel(cid: 1, icon: '', projectId: project.id)
          ..title = '项目会话'
          ..stickTime = 0
          ..updateAt = 2);
    await convDao.saveConversation(ConversationModel(cid: 2, icon: '')
      ..title = '未分类会话'
      ..stickTime = 0
      ..updateAt = 1);

    final projectConvs =
        await convDao.getConversationList(projectId: project.id);
    final unclassified = await convDao.getConversationList(uncategorized: true);
    final projects = await projectDao.getProjects(withCounts: true);

    expect(projectConvs.single.title, '项目会话');
    expect(unclassified.single.title, '未分类会话');
    expect(projects.single.conversationCount, 1);
    await storage.db.close();
  });

  test('旧项目表自动补 icon，新项目可保存图标和颜色', () async {
    final storage = await newDb();
    await storage.db
        .execute('create table tb_project (id integer primary key autoincrement'
            ', name text not null, color integer, sortOrder integer'
            ', createdAt integer, updatedAt integer);');
    await storage.db.insert('tb_project', {
      'name': '旧项目',
      'color': 0xFF1565C0,
      'sortOrder': 0,
      'createdAt': 1,
      'updatedAt': 1,
    });

    final dao = await ProjectDao.create(storage);
    final old = (await dao.getProjects()).single;
    expect(old.icon, '📁');

    final fresh = ProjectModel(name: '新项目', icon: '💡', color: 0xFFC62828);
    fresh
      ..defaultProviderId = 'openai'
      ..defaultModelId = 'gpt-4o'
      ..defaultAssistantId = 7
      ..defaultUseWebSearch = true
      ..defaultToolIds = ['calculator', 'knowledge_search'];
    await dao.saveProject(fresh);
    final saved = await dao.getProject(fresh.id!);
    expect(saved!.icon, '💡');
    expect(saved.color, 0xFFC62828);
    expect(saved.defaultProviderId, 'openai');
    expect(saved.defaultModelId, 'gpt-4o');
    expect(saved.defaultAssistantId, 7);
    expect(saved.defaultUseWebSearch, isTrue);
    expect(saved.defaultToolIds, ['calculator', 'knowledge_search']);
    await storage.db.close();
  });

  test('会话头像字段兼容旧表，并可恢复默认头像', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer);');

    final dao = await ConversationListDao.create(storage);
    final model = ConversationModel(cid: 9, icon: '')
      ..title = '头像测试'
      ..stickTime = 0;
    await dao.saveConversation(model);
    await dao.updateAvatar(model, 'emoji', '💡');
    var rows = await storage.db.query('tb_conversation_list', where: 'cid = 9');
    expect(rows.single['avatarType'], 'emoji');
    expect(rows.single['avatarValue'], '💡');

    await dao.updateAvatar(model, null, null);
    rows = await storage.db.query('tb_conversation_list', where: 'cid = 9');
    expect(rows.single['avatarType'], isNull);
    expect(rows.single['avatarValue'], isNull);
    await storage.db.close();
  });

  test('会话模型覆盖字段兼容旧表，并可恢复跟随全局', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer);');

    final dao = await ConversationListDao.create(storage);
    final model = ConversationModel(cid: 10, icon: '')
      ..title = '模型测试'
      ..stickTime = 0;
    await dao.saveConversation(model);
    await dao.updateModelOverride(model, 'openai', 'gpt-4o');
    var rows =
        await storage.db.query('tb_conversation_list', where: 'cid = 10');
    expect(rows.single['modelProviderId'], 'openai');
    expect(rows.single['modelId'], 'gpt-4o');
    expect(ConversationModel.fromJson(rows.single).modelId, 'gpt-4o');

    await dao.updateModelOverride(model, null, null);
    rows = await storage.db.query('tb_conversation_list', where: 'cid = 10');
    expect(rows.single['modelProviderId'], isNull);
    expect(rows.single['modelId'], isNull);
    await storage.db.close();
  });

  test('会话联网搜索覆盖字段兼容旧表，并可恢复跟随全局', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer);');

    final dao = await ConversationListDao.create(storage);
    final model = ConversationModel(cid: 11, icon: '')
      ..title = '联网测试'
      ..stickTime = 0;
    await dao.saveConversation(model);
    await dao.updateWebSearchOverride(model, true);
    var rows =
        await storage.db.query('tb_conversation_list', where: 'cid = 11');
    expect(rows.single['webSearchEnabled'], 1);
    expect(ConversationModel.fromJson(rows.single).webSearchEnabled, isTrue);

    await dao.updateWebSearchOverride(model, null);
    rows = await storage.db.query('tb_conversation_list', where: 'cid = 11');
    expect(rows.single['webSearchEnabled'], isNull);
    expect(ConversationModel.fromJson(rows.single).webSearchEnabled, isNull);
    await storage.db.close();
  });

  test('会话工具集覆盖字段兼容旧表，并可 JSON 往返', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer);');

    final dao = await ConversationListDao.create(storage);
    final model = ConversationModel(cid: 12, icon: '', toolIds: [
      'calculator',
      'knowledge_search',
    ])
      ..title = '工具测试'
      ..stickTime = 0;
    await dao.saveConversation(model);
    final rows =
        await storage.db.query('tb_conversation_list', where: 'cid = 12');
    expect(ConversationModel.fromJson(rows.single).toolIds,
        ['calculator', 'knowledge_search']);
    await storage.db.close();
  });

  test('置顶只更新目标会话，不影响同表其他会话', () async {
    final storage = await newDb();
    final dao = await ConversationListDao.create(storage);
    final first = ConversationModel(cid: 13, icon: '')
      ..title = '目标会话'
      ..stickTime = 0
      ..updateAt = 13;
    final second = ConversationModel(cid: 14, icon: '')
      ..title = '旁路会话'
      ..stickTime = 0
      ..updateAt = 14;
    await dao.saveConversation(first);
    await dao.saveConversation(second);

    await dao.updateStickTime(first, isStick: true);

    final rows = await storage.db.query(
      'tb_conversation_list',
      columns: ['cid', 'stickTime'],
      orderBy: 'cid',
    );
    expect(rows.first['cid'], 13);
    expect(rows.first['stickTime'], greaterThan(0));
    expect(rows.last['cid'], 14);
    expect(rows.last['stickTime'], 0);
    await storage.db.close();
  });

  test('搜索会话：标题/全量消息命中，并支持项目和未分类过滤', () async {
    final storage = await newDb();
    final projectDao = await ProjectDao.create(storage);
    final project = ProjectModel(name: '产品');
    await projectDao.saveProject(project);
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(
        ConversationModel(cid: 21, icon: '', projectId: project.id)
          ..title = '发布计划'
          ..assistantId = 9
          ..modelId = 'gpt-4o'
          ..lastMessage = '准备 Android 包'
          ..stickTime = 0
          ..updateAt = 2);
    await convDao.saveConversation(ConversationModel(cid: 22, icon: '')
      ..title = '普通聊天'
      ..lastMessage = '没有关键词'
      ..stickTime = 0
      ..updateAt = 1);
    await MessageDao.create(storage, cid: 21);
    await storage.db.insert('tb_messages', {
      'cid': 21,
      'content': 'Alpha 版本需要补充项目知识库',
      'createdAt': 1,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await storage.db.insert('tb_messages', {
      'cid': 22,
      'content': 'Alpha 出现在未分类会话',
      'createdAt': 2,
      'ownerName': 'user',
      'ownerType': 'sender',
    });

    final all = await convDao.searchConversations('Alpha');
    expect(all.map((e) => e.conversation.cid), containsAll([21, 22]));
    expect(all.first.snippet, contains('Alpha'));

    final scoped =
        await convDao.searchConversations('Alpha', projectId: project.id);
    expect(scoped.single.conversation.cid, 21);

    final uncategorized =
        await convDao.searchConversations('Alpha', uncategorized: true);
    expect(uncategorized.single.conversation.cid, 22);

    final byTitle = await convDao.searchConversations('发布');
    expect(byTitle.single.conversation.cid, 21);

    final byAssistant =
        await convDao.searchConversations('Alpha', assistantId: 9);
    expect(byAssistant.single.conversation.cid, 21);
    final byModel =
        await convDao.searchConversations('Alpha', modelId: 'gpt-4o');
    expect(byModel.single.conversation.cid, 21);
    final recent = await convDao.searchConversations('Alpha', updatedAfter: 2);
    expect(recent.single.conversation.cid, 21);

    final favoriteDao = await FavoriteDao.create(storage);
    await favoriteDao.addFavorite(
        FavoriteModel(ownerName: 'AI', content: 'Alpha 收藏内容', createdAt: 3));
    final favorites = await favoriteDao.searchFavorites('Alpha');
    expect(favorites.single.content, contains('收藏'));
    await storage.db.close();
  });

  test('DbMigration.run 集中补齐旧 schema 新列与索引', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer);');
    await storage.db
        .execute('create table tb_project (id integer primary key autoincrement'
            ', name text not null, color integer, sortOrder integer'
            ', createdAt integer, updatedAt integer);');

    await DbMigration.run(storage.db);

    Future<bool> hasColumn(String table, String column) async {
      final rows = await storage.db.rawQuery('pragma table_info($table)');
      return rows.any((r) => r['name'] == column);
    }

    expect(await hasColumn('tb_conversation_list', 'toolIds'), isTrue);
    expect(await hasColumn('tb_project', 'defaultToolIds'), isTrue);
    expect(await hasColumn('tb_messages', 'blocks'), isTrue);
    final kbRefs = await storage.db.rawQuery(
        "select name from sqlite_master where type='table' and name='tb_project_kb'");
    expect(kbRefs, isNotEmpty);
    await storage.db.close();
  });

  test('长会话基础回归：1000 条消息可分页并可搜索命中', () async {
    final storage = await newDb();
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(ConversationModel(cid: 1000, icon: '')
      ..title = '长会话'
      ..lastMessage = 'needle'
      ..stickTime = 0
      ..updateAt = 1000);
    await MessageDao.create(storage, cid: 1000);
    final batch = storage.db.batch();
    for (var i = 0; i < 1000; i++) {
      batch.insert('tb_messages', {
        'cid': 1000,
        'content': i == 777 ? 'needle message $i' : 'message $i',
        'createdAt': i,
        'ownerName': i.isEven ? 'user' : 'AI',
        'ownerType': i.isEven ? 'sender' : 'receiver',
      });
    }
    await batch.commit(noResult: true);

    final messageDao = await MessageDao.create(storage, cid: 1000);
    expect((await messageDao.getMessages(pageSize: 100)).length, 100);
    final hits = await convDao.searchConversations('needle');
    expect(hits.single.conversation.cid, 1000);
    expect(hits.single.snippet, contains('needle'));
    await storage.db.close();
  });

  test('收藏搜索反查会话时同时匹配 createdAt 和 content，避免同时间误跳转', () async {
    final storage = await newDb();
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(ConversationModel(cid: 31, icon: '')
      ..title = '正确会话'
      ..stickTime = 0
      ..updateAt = 31);
    await convDao.saveConversation(ConversationModel(cid: 32, icon: '')
      ..title = '同时间会话'
      ..stickTime = 0
      ..updateAt = 32);
    await MessageDao.create(storage, cid: 31);
    await storage.db.insert('tb_messages', {
      'cid': 31,
      'content': 'Alpha 收藏内容',
      'createdAt': 777,
      'ownerName': 'AI',
      'ownerType': 'receiver',
    });
    await storage.db.insert('tb_messages', {
      'cid': 32,
      'content': 'Alpha 另一个内容',
      'createdAt': 777,
      'ownerName': 'AI',
      'ownerType': 'receiver',
    });
    final favoriteDao = await FavoriteDao.create(storage);
    await favoriteDao.addFavorite(FavoriteModel(
      ownerName: 'AI',
      content: 'Alpha 收藏内容',
      createdAt: 777,
    ));

    final result = await favoriteDao.searchFavoriteResults('Alpha');

    expect(result.single.cid, 31);
    expect(result.single.conversationTitle, '正确会话');
    await storage.db.close();
  });

  test('搜索会话：支持更新时间上下界与双边界组合', () async {
    final storage = await newDb();
    final convDao = await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 41);
    for (final item in [
      (cid: 41, title: 'Alpha 旧会话', updateAt: 1000),
      (cid: 42, title: 'Alpha 中间会话', updateAt: 2000),
      (cid: 43, title: 'Alpha 新会话', updateAt: 3000),
    ]) {
      await convDao.saveConversation(ConversationModel(cid: item.cid, icon: '')
        ..title = item.title
        ..lastMessage = 'Alpha'
        ..stickTime = 0
        ..updateAt = item.updateAt);
    }

    final after =
        await convDao.searchConversations('Alpha', updatedAfter: 2000);
    expect(after.map((e) => e.conversation.cid), [43, 42]);

    final before =
        await convDao.searchConversations('Alpha', updatedBefore: 2000);
    expect(before.map((e) => e.conversation.cid), [42, 41]);

    final between = await convDao.searchConversations('Alpha',
        updatedAfter: 1500, updatedBefore: 2500);
    expect(between.single.conversation.cid, 42);
    await storage.db.close();
  });
}
