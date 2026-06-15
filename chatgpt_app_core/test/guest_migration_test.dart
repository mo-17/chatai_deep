import 'dart:io';

import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
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
  }) async {
    final assistantDao = await AssistantDao.create(storage);
    final aid = await assistantDao
        .saveAssistant(AssistantModel(name: assistantName, prompt: 'p'));
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(
        ConversationModel(cid: cid, icon: '', assistantId: aid)
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
        msgContent: '游客问题');

    final account = await newDb();
    final r = await GuestMigrationService.mergeGuestData(
        from: guest, to: account);
    await guest.db.close();

    expect(r.conversations, 1);
    expect(r.messages, 1);
    expect(r.assistants, 1);
    expect(r.favorites, 1);

    final conv =
        await account.db.query('tb_conversation_list', where: 'cid = 2001');
    final newAid = conv.single['assistantId'] as int;
    final assistant =
        await (await AssistantDao.create(account)).getAssistant(newAid);
    expect(assistant!.name, '游客助手');
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
        msgContent: '账号消息');

    // 游客也有：助手(id=1) + 会话 cid=2001（与账号冲突）。
    final guest = await newDb();
    await seedOne(guest,
        cid: 2001,
        assistantName: '游客助手',
        convTitle: '游客会话',
        msgContent: '游客消息');

    final r = await GuestMigrationService.mergeGuestData(
        from: guest, to: account);
    await guest.db.close();
    expect(r.conversations, 1);

    // 现在账号应有 2 个会话、2 个助手、2 条消息、2 条收藏。
    final convs = await account.db.query('tb_conversation_list');
    expect(convs.length, 2);
    final assistants = await account.db.query('tb_assistant');
    expect(assistants.length, 2);
    expect((await account.db.query('tb_messages')).length, 2);
    expect((await account.db.query('tb_favorite')).length, 2);

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
    final guestMsgs =
        await account.db.query('tb_messages', where: 'cid = ?', whereArgs: [guestCid]);
    expect(guestMsgs.single['content'], '游客消息');
    await account.db.close();
  });

  test('doneKey 形如 guest_migrated_<hash>', () {
    expect(GuestMigrationService.doneKey('acc-new'), 'guest_migrated_acc-new');
  });
}
