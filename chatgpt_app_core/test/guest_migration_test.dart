import 'dart:io';

import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 游客数据**行级合并** [GuestMigrationService.mergeGuestData] 验收：
/// 追加到空账号 / 追加到已有数据且 cid+助手 id 冲突的账号（重映射正确）。
/// 走真实 DAO（HiDBManager.test 注入 ffi 临时文件库——两库需同时打开，
/// 不能用共享的 :memory:）。
void main() {
  late Directory tmpDir;

  setUpAll(() async {
    sqfliteFfiInit();
    tmpDir = await Directory.systemTemp.createTemp('guest_mig_test');
  });

  tearDownAll(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  var seq = 0;
  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${tmpDir.path}/db_${seq++}.db'));

  /// 在 [storage] 里造一个「助手 + 绑定它的会话(cid) + 一条消息 + 一条收藏」。
  /// 返回 (助手 id)。
  Future<int> seedOne(
    HiDBManager storage, {
    required int cid,
    required String assistantName,
    required String convTitle,
    required String msgContent,
    String? projectName,
  }) async {
    final assistantDao = await AssistantDao.create(storage);
    final aid = await assistantDao
        .saveAssistant(AssistantModel(name: assistantName, prompt: 'p'));
    final convDao = await ConversationListDao.create(storage);
    int? projectId;
    if (projectName != null) {
      final projectDao = await ProjectDao.create(storage);
      final project = ProjectModel(name: projectName, defaultAssistantId: aid);
      await projectDao.saveProject(project);
      projectId = project.id;
    }
    await convDao.saveConversation(ConversationModel(
        cid: cid, icon: '', assistantId: aid, projectId: projectId)
      ..title = convTitle
      ..stickTime = 0
      ..updateAt = 1);
    await MessageDao.create(storage, cid: cid);
    await storage.db.insert('tb_messages', {
      'cid': cid,
      'content': msgContent,
      'createdAt': 111,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await FavoriteDao.create(storage);
    await storage.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '收藏-$convTitle', 'createdAt': 333});
    return aid!;
  }

  test('合并到空账号：计数正确，助手绑定（重映射 id）保留', () async {
    final guest = await newDb();
    final gAid = await seedOne(guest,
        cid: 2001,
        assistantName: '游客助手',
        convTitle: '游客会话',
        msgContent: '游客问题',
        projectName: '游客项目');

    final account = await newDb();
    final r =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);
    await guest.db.close();

    expect(r.conversations, 1);
    expect(r.messages, 1);
    expect(r.assistants, 1);
    expect(r.favorites, 1);
    expect(r.projects, 1);

    final conv =
        await account.db.query('tb_conversation_list', where: 'cid = 2001');
    final newAid = conv.single['assistantId'] as int;
    final assistant =
        await (await AssistantDao.create(account)).getAssistant(newAid);
    expect(assistant!.name, '游客助手');
    final project = (await account.db.query('tb_project',
            where: 'id = ?', whereArgs: [conv.single['projectId']]))
        .single;
    expect(project['name'], '游客项目');
    expect(project['defaultAssistantId'], newAid);
    // 空账号无冲突：助手 id 仍从 1 起，guest 原 id 也是 1，这里只验证名字对得上。
    expect(gAid, isNotNull);
    await account.db.close();
  });

  test('合并到已有数据账号：cid 与助手 id 冲突时重映射，账号原数据不动', () async {
    // 账号已有：助手(id=1) + 会话 cid=2001。
    final account = await newDb();
    final accAid = await seedOne(account,
        cid: 2001,
        assistantName: '账号助手',
        convTitle: '账号会话',
        msgContent: '账号消息',
        projectName: '账号项目');

    // 游客也有：助手(id=1) + 会话 cid=2001（与账号冲突）。
    final guest = await newDb();
    await seedOne(guest,
        cid: 2001,
        assistantName: '游客助手',
        convTitle: '游客会话',
        msgContent: '游客消息',
        projectName: '游客项目');

    final r =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);
    await guest.db.close();
    expect(r.conversations, 1);

    // 现在账号应有 2 个会话、2 个助手、2 条消息、2 条收藏。
    final convs = await account.db.query('tb_conversation_list');
    expect(convs.length, 2);
    final assistants = await account.db.query('tb_assistant');
    expect(assistants.length, 2);
    expect((await account.db.query('tb_messages')).length, 2);
    expect((await account.db.query('tb_favorite')).length, 2);
    expect((await account.db.query('tb_project')).length, 2);

    // 账号原会话 cid=2001 仍在，且仍绑账号助手（名字=账号助手）。
    final accConv =
        (await account.db.query('tb_conversation_list', where: 'cid = 2001'))
            .single;
    expect(accConv['assistantId'], accAid);
    final accAssistant = await (await AssistantDao.create(account))
        .getAssistant(accConv['assistantId'] as int);
    expect(accAssistant!.name, '账号助手');

    // 游客会话被重映射到新 cid（≠2001），绑定的是新插入的「游客助手」，
    // 且其消息也跟到了新 cid。
    final guestConv = (await account.db.query('tb_conversation_list',
            where: 'title = ?', whereArgs: ['游客会话']))
        .single;
    final guestCid = guestConv['cid'] as int;
    expect(guestCid, isNot(2001));
    final guestAssistant = await (await AssistantDao.create(account))
        .getAssistant(guestConv['assistantId'] as int);
    expect(guestAssistant!.name, '游客助手');
    final guestMsgs = await account.db
        .query('tb_messages', where: 'cid = ?', whereArgs: [guestCid]);
    expect(guestMsgs.single['content'], '游客消息');
    final guestProject = (await account.db.query('tb_project',
            where: 'id = ?', whereArgs: [guestConv['projectId']]))
        .single;
    expect(guestProject['name'], '游客项目');
    expect(guestProject['defaultAssistantId'], guestConv['assistantId']);
    await account.db.close();
  });

  test('doneKey 形如 guest_migrated_<hash>', () {
    expect(GuestMigrationService.doneKey('acc-new'), 'guest_migrated_acc-new');
  });

  test('mergeGuestData：来源数据库旧会话表（无 projectId）可正常迁移', () async {
    final guest = await newDb();
    // 先制造一套旧版会话表：无 projectId 列。
    await guest.db.execute('drop table if exists tb_conversation_list');
    await guest.db.execute(
        'create table tb_conversation_list (id integer primary key autoincrement'
        ', cid integer, title text, icon text, updateAt integer'
        ', messageCount integer, lastMessage text, stickTime integer, assistantId integer)');

    // 其余表照常创建，用于完整迁移通路。
    await AssistantDao.create(guest);
    await MessageDao.create(guest, cid: 3001);
    await FavoriteDao.create(guest);

    final assistantDao = await AssistantDao.create(guest);
    final assistId = await assistantDao
        .saveAssistant(AssistantModel(name: '旧版助手', prompt: 'p'));
    await guest.db.insert('tb_conversation_list', {
      'cid': 3001,
      'title': '旧 schema 会话',
      'icon': '',
      'updateAt': 1,
      'messageCount': 1,
      'stickTime': 0,
      'assistantId': assistId,
    });
    await guest.db.insert('tb_messages', {
      'cid': 3001,
      'content': '旧 schema 消息',
      'createdAt': 10,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await guest.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '旧 schema 收藏', 'createdAt': 11});

    final account = await newDb();
    final result =
        await GuestMigrationService.mergeGuestData(from: guest, to: account);
    expect(result.conversations, 1);
    expect(result.messages, 1);
    expect(result.assistants, 1);
    expect(result.favorites, 1);
    expect(result.projects, 0);

    final conv = await account.db
        .query('tb_conversation_list', where: 'cid = ?', whereArgs: [3001]);
    expect(conv.single['assistantId'], isNotNull);
    expect(conv.single['projectId'], isNull);

    await guest.db.close();
    await account.db.close();
  });
}
