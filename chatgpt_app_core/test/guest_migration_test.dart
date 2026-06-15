import 'dart:io';

import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 游客数据迁移核心 [GuestMigrationService.migrateBetween] 验收：
/// 把游客库 + 游客 AI 设置整体导入空的正式账号库（含 API key，不脱敏）。
/// 走真实 BackupService + DAO（HiDBManager.test 注入 ffi 内存库）。
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

  // 用独立临时文件而非 :memory:——后者在 ffi 下同路径会共享同一连接，
  // 两个库需同时打开时会相互影响。
  var seq = 0;
  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${tmpDir.path}/db_${seq++}.db'));

  /// 造一套游客侧数据：助手 + 绑定它的会话 + 普通会话 + 消息 + 收藏。
  Future<int> seedGuest(HiDBManager storage) async {
    final assistantDao = await AssistantDao.create(storage);
    final aid = await assistantDao
        .saveAssistant(AssistantModel(name: '游客助手', prompt: '你是助手'));
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(
        ConversationModel(cid: 2001, icon: '', assistantId: aid)
          ..title = '游客会话A'
          ..stickTime = 0
          ..updateAt = 1);
    await convDao.saveConversation(ConversationModel(cid: 2002, icon: '')
      ..title = '游客会话B'
      ..stickTime = 0
      ..updateAt = 2);
    await MessageDao.create(storage, cid: 2001);
    await storage.db.insert('tb_messages', {
      'cid': 2001,
      'content': '游客问题',
      'createdAt': 111,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await FavoriteDao.create(storage);
    await storage.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '游客收藏', 'createdAt': 333});
    return aid!;
  }

  test('migrateBetween 把游客会话/助手/收藏/设置（含 key）导入空账号', () async {
    final guest = await newDb();
    final aid = await seedGuest(guest);
    final guestSettings = AISettings.defaults();
    guestSettings.providers.firstWhere((p) => p.id == 'openai').apiKey =
        'sk-guest';

    final account = await newDb();
    final result = await GuestMigrationService.migrateBetween(
      from: guest,
      to: account,
      guestSettings: guestSettings,
      toAccountHash: 'acc-new',
    );
    await guest.db.close();

    expect(result.conversations, 2);
    expect(result.messages, 1);
    expect(result.assistants, 1);
    expect(result.favorites, 1);
    // 迁移不脱敏：API key 跟随过来。
    expect(
        result.settings!.providers.firstWhere((p) => p.id == 'openai').apiKey,
        'sk-guest');

    // 账号库里确有数据，且助手绑定关系（原始 id）保留。
    final convs =
        await account.db.query('tb_conversation_list', where: 'cid = 2001');
    expect(convs.single['assistantId'], aid);
    final assistant = await (await AssistantDao.create(account)).getAssistant(aid);
    expect(assistant!.name, '游客助手');
    await account.db.close();
  });

  test('doneKey 形如 guest_migrated_<hash>', () {
    expect(GuestMigrationService.doneKey('acc-new'), 'guest_migrated_acc-new');
  });
}
