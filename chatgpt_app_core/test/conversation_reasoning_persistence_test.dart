import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  final databases = <HiDBManager>[];
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reasoning_persistence_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${temporary.path}/attachments');
    BackupService.debugGeneratedImageDirectoryResolver = () async => temporary;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => temporary;
  });

  tearDown(() async {
    for (final database in databases) {
      if (database.db.isOpen) await database.db.close();
    }
    databases.clear();
    ManagedAttachmentStore.debugRootDirectory = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    await temporary.delete(recursive: true);
  });

  Future<HiDBManager> openDatabase() async {
    final storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
      '${temporary.path}/db_${databases.length}.db',
    ));
    databases.add(storage);
    return storage;
  }

  ConversationModel model(int cid, {DeepSeekReasoningEffort? effort}) =>
      ConversationModel(
        cid: cid,
        icon: '',
        title: '会话 $cid',
        updateAt: cid,
        deepSeekReasoningEffort: effort,
      );

  test('旧记录及未知等级安全回退默认', () {
    final original = model(1).toJson()..remove('deepSeekReasoningEffort');
    expect(
        ConversationModel.fromJson(original).deepSeekReasoningEffort, isNull);
    for (final invalid in [
      42,
      'ultra',
      <String, Object>{'effort': 'max'}
    ]) {
      expect(
        ConversationModel.fromJson({
          ...original,
          'deepSeekReasoningEffort': invalid,
        }).deepSeekReasoningEffort,
        isNull,
      );
    }
  });

  test('旧表按需增加等级列，原会话内容保持不变', () async {
    final storage = await openDatabase();
    await storage.db.execute('CREATE TABLE tb_conversation_list ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, cid INTEGER, title TEXT, '
        'icon TEXT, updateAt INTEGER, messageCount INTEGER, '
        'lastMessage TEXT, stickTime INTEGER)');
    await storage.db.insert('tb_conversation_list', {
      'cid': 101,
      'title': '历史会话',
      'icon': '',
      'updateAt': 1,
      'lastMessage': '原回答',
      'messageCount': 2,
      'stickTime': 0,
    });
    final dao = await ConversationListDao.create(storage);
    // 连续初始化也必须成功。
    await ConversationListDao.create(storage);
    final old = (await dao.getConversationList()).single;
    expect(old.deepSeekReasoningEffort, isNull);
    expect(old.lastMessage, '原回答');
    expect(old.messageCount, 2);
  });

  test('所有等级重开保持，恢复默认只清除等级', () async {
    final storage = await openDatabase();
    final dao = await ConversationListDao.create(storage);
    final conversation = model(102)..lastMessage = '保留回答';
    await dao.saveConversation(conversation);
    for (final effort in DeepSeekReasoningEffort.values) {
      await dao.updateReasoningEffort(conversation, effort);
      final reloaded = (await dao.getConversationList()).single;
      expect(reloaded.deepSeekReasoningEffort, effort);
      expect(reloaded.lastMessage, '保留回答');
    }
    await dao.updateReasoningEffort(conversation, null);
    expect((await dao.getConversationList()).single.deepSeekReasoningEffort,
        isNull);
  });

  test('空白新会话选等级后，首次保存携带等级', () async {
    final storage = await openDatabase();
    final dao = await ConversationListDao.create(storage);
    final conversation = model(103)..title = null;
    expect(
        await dao.updateReasoningEffort(
            conversation, DeepSeekReasoningEffort.low),
        0);
    expect(await dao.getConversationList(), isEmpty);
    conversation.title = '首次发送';
    await dao.saveConversation(conversation);
    expect((await dao.getConversationList()).single.deepSeekReasoningEffort,
        DeepSeekReasoningEffort.low);
  });

  test('保存失败不提前修改会话等级', () async {
    final storage = await openDatabase();
    final dao = await ConversationListDao.create(storage);
    final conversation = model(104, effort: DeepSeekReasoningEffort.high);
    await dao.saveConversation(conversation);
    await storage.db.close();
    await expectLater(
        dao.updateReasoningEffort(conversation, DeepSeekReasoningEffort.max),
        throwsA(isA<Exception>()));
    expect(conversation.deepSeekReasoningEffort, DeepSeekReasoningEffort.high);
  });

  test('备份还原保留会话等级、默认值与原消息', () async {
    final source = await openDatabase();
    final dao = await ConversationListDao.create(source);
    await dao.saveConversation(model(105, effort: DeepSeekReasoningEffort.max));
    await dao.saveConversation(model(106));
    await MessageDao.create(source, cid: 105);
    await source.db.insert('tb_messages', {
      'cid': 105,
      'content': '原有历史',
      'createdAt': 1,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    final bytes = await BackupService(source)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'source');
    final target = await openDatabase();
    await BackupService(target).importArchive(bytes, accountHash: 'target');
    final rows = await target.db.query('tb_conversation_list', orderBy: 'cid');
    expect(rows[0]['deepSeekReasoningEffort'], 'max');
    expect(rows[1]['deepSeekReasoningEffort'], isNull);
    expect((await target.db.query('tb_messages')).single['content'], '原有历史');
  });

  test('游客合并发生 cid 冲突仍保留各自等级与消息', () async {
    final source = await openDatabase();
    final target = await openDatabase();
    final guestDao = await ConversationListDao.create(source);
    final targetDao = await ConversationListDao.create(target);
    await guestDao.saveConversation(
        model(107, effort: DeepSeekReasoningEffort.low)..title = '游客会话');
    await targetDao.saveConversation(
        model(107, effort: DeepSeekReasoningEffort.off)..title = '账号会话');
    await MessageDao.create(source, cid: 107);
    await source.db.insert('tb_messages', {
      'cid': 107,
      'content': '游客历史',
      'createdAt': 1,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await GuestMigrationService.mergeGuestData(from: source, to: target);
    final rows = await target.db.query('tb_conversation_list');
    final guest = rows.singleWhere((row) => row['title'] == '游客会话');
    final account = rows.singleWhere((row) => row['title'] == '账号会话');
    expect(guest['cid'], isNot(107));
    expect(guest['deepSeekReasoningEffort'], 'low');
    expect(account['deepSeekReasoningEffort'], 'off');
    expect((await target.db.query('tb_messages')).single['cid'], guest['cid']);
  });
}
