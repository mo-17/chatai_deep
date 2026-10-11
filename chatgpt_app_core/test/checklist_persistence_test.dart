import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/application/checklist_state_coordinator.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';

import 'interactive_card_test.dart' show checklistJson, cardFence;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager db;
  late MessageDao dao;
  late int rowId;
  late Directory temp;
  final content = '${cardFence(checklistJson())}${cardFence(checklistJson())}';
  final cards =
      InteractiveCardParser.parse(content).whereType<CardProjection>().toList();
  final block = MainTextBlock(
      id: 'main',
      messageId: 'msg_100',
      createdAt: 100,
      status: MessageBlockStatus.success,
      content: content,
      protocolMessages: const [
        {'role': 'assistant', 'content': '原协议'}
      ]);

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false)));
  Future<int> seed(MessageDao target,
          {String? blocks, OwnerType owner = OwnerType.receiver}) =>
      target.saveMessageWithBlocks(
          MessageModel(ownerType: owner, content: content, createdAt: 100),
          blocksJson: blocks ?? MessageBlock.encodeList([block]));
  Future<ChecklistWriteResult> write(
          {int index = 0,
          String item = 'ticket',
          bool checked = true,
          MessageDao? target,
          int? expectedId,
          String? expectedText,
          String? key}) =>
      (target ?? dao).setChecklistItemChecked(
          createdAt: 100,
          blockId: 'main',
          expectedContent: expectedText ?? content,
          cardKey: key ?? cards[index].key,
          itemId: item,
          checked: checked,
          expectedRowId: expectedId ?? rowId);
  Future<MainTextBlock> reload() async => MessageBlock.decodeList(
          (await dao.getBlocksByCreatedAt([100]))['msg_100'])
      .first as MainTextBlock;

  setUp(() async {
    sqfliteFfiInit();
    temp = await Directory.systemTemp.createTemp('checklist-persistence-');
    BackupService.debugGeneratedImageDirectoryResolver = () async => temp;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => temp;
    db = await newDb();
    dao = await MessageDao.create(db, cid: 7);
    rowId = await seed(dao);
  });
  tearDown(() async {
    LoginSdkConfig.reset();
    if (db.db.isOpen) await db.db.close();
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    await temp.delete(recursive: true);
  });
  test('两张卡并发合并，重开恢复，只更新 blocks 且原文协议不变', () async {
    final before = (await db.db.query('tb_messages')).single;
    final results = await Future.wait([write(), write(index: 1, item: 'bag')]);
    expect(
        results.map((r) => r.status), everyElement(ChecklistWriteStatus.saved));
    final reopened = await MessageDao.create(db, cid: 7);
    final saved = MessageBlock.decodeList(
            (await reopened.getBlocksByCreatedAt([100]))['msg_100'])
        .single as MainTextBlock;
    expect(saved.localCardStates[cards[0].key]!.checkedItemIds, {'ticket'});
    expect(saved.localCardStates[cards[1].key]!.checkedItemIds, {'bag'});
    expect(saved.content, content);
    expect(saved.protocolMessages, block.protocolMessages);
    final after = (await db.db.query('tb_messages')).single;
    expect({...after}..remove('blocks'), {...before}..remove('blocks'));
    expect((await write(checked: false)).status, ChecklistWriteStatus.saved);
    expect((await reload()).localCardStates[cards[0].key]!.checkedItemIds,
        isEmpty);
  });
  test('cid 和账号数据库隔离', () async {
    final otherCid = await MessageDao.create(db, cid: 8);
    expect(
        (await write(target: otherCid)).status, ChecklistWriteStatus.notFound);
    final account = await newDb();
    try {
      final other = await MessageDao.create(account, cid: 7);
      final otherId = await seed(other);
      expect((await write()).status, ChecklistWriteStatus.saved);
      final untouched = MessageBlock.decodeList(
              (await other.getBlocksByCreatedAt([100]))['msg_100'])
          .single as MainTextBlock;
      expect(untouched.localCardStates, isEmpty);
      expect((await write(target: other, expectedId: otherId, index: 1)).status,
          ChecklistWriteStatus.saved);
      expect((await reload()).localCardStates.keys, [cards[0].key]);
    } finally {
      await account.db.close();
    }
  });
  test('删除、相同正文重生成也拒绝旧 row 绑定，不 INSERT 复活', () async {
    await dao.deleteMessageByCreatedAt(100);
    expect((await write()).status, ChecklistWriteStatus.notFound);
    expect(await dao.getMessageCount(), 0);
    final newId = await seed(dao);
    expect(newId, isNot(rowId));
    expect((await write()).status, ChecklistWriteStatus.stale);
    expect((await reload()).localCardStates, isEmpty);
  });
  test('正文/hash/item/block 身份变化拒绝写入', () async {
    expect((await write(expectedText: '$content ')).status,
        ChecklistWriteStatus.stale);
    expect(
        (await write(key: '0:${'a' * 64}')).status, ChecklistWriteStatus.stale);
    expect((await write(item: 'unknown')).status, ChecklistWriteStatus.stale);
    final changed = block.toJson()
      ..['content'] = content.replaceAll('确认车票', '确认机票');
    await db.db.update('tb_messages', {
      'blocks': jsonEncode([changed])
    });
    expect((await write()).status, ChecklistWriteStatus.stale);
    expect((await reload()).localCardStates, isEmpty);
  });
  test('重复 createdAt、用户块及活跃/错误消息只读', () async {
    await seed(dao);
    expect((await write()).status, ChecklistWriteStatus.stale);
    await dao.deleteMessageByCreatedAt(100);
    rowId = await seed(dao, owner: OwnerType.sender);
    expect((await write()).status, ChecklistWriteStatus.stale);
    await db.db
        .update('tb_messages', {'ownerType': OwnerType.receiver.toString()});
    for (final status in ['streaming', 'paused', 'error']) {
      await db.db.update('tb_messages', {
        'blocks': jsonEncode([block.toJson()..['status'] = status])
      });
      expect((await write()).status, ChecklistWriteStatus.stale);
    }
    await db.db.update('tb_messages', {
      'blocks': jsonEncode([
        block.toJson(),
        {'type': 'error', 'id': 'error', 'status': 'success'}
      ])
    });
    expect((await write()).status, ChecklistWriteStatus.stale);
  });
  test('坏状态不丢正文；目标/其它块未知字段原样保留', () async {
    final rawBlock = block.toJson()
      ..['futureField'] = {
        'keep': ['unchanged']
      }
      ..['localCardStates'] = {
        cards[0].key: {
          'version': 1,
          'checkedItemIds': ['unknown']
        },
        cards[1].key: {
          'version': 1,
          'checkedItemIds': ['bag']
        },
        'futureState': {'opaque': 42}
      };
    final unknown = {
      'type': 'future',
      'id': 'other',
      'unknown': {'opaque': true}
    };
    await db.db.update('tb_messages', {
      'blocks': jsonEncode([rawBlock, unknown])
    });
    expect((await reload()).content, content);
    expect((await write()).status, ChecklistWriteStatus.saved);
    final saved =
        jsonDecode((await dao.getBlocksByCreatedAt([100]))['msg_100']!) as List;
    expect(saved[0]['futureField'], rawBlock['futureField']);
    expect(saved[1], unknown);
    expect(saved[0]['localCardStates']['futureState'], {'opaque': 42});
    expect((await reload()).localCardStates[cards[1].key]!.checkedItemIds,
        {'bag'});
  });
  test('SQLite 保存失败保留上一个状态，无副作用', () async {
    expect((await write()).status, ChecklistWriteStatus.saved);
    final original = (await dao.getBlocksByCreatedAt([100]))['msg_100'];
    await db.db.execute(
        "create trigger reject_card before update of blocks on tb_messages begin select raise(abort, 'fixture failure'); end");
    expect((await write(item: 'bag')).status, ChecklistWriteStatus.failed);
    expect((await dao.getBlocksByCreatedAt([100]))['msg_100'], original);
  });
  test('第五张卡跨 MainTextBlock 仍不可写', () async {
    final four = block.copyWith(content: cardFence(checklistJson()) * 4);
    final second = block.toJson()..['id'] = 'second';
    await db.db.update('tb_messages', {
      'blocks': jsonEncode([four.toJson(), second])
    });
    final result = await dao.setChecklistItemChecked(
        createdAt: 100,
        blockId: 'second',
        expectedContent: content,
        cardKey: cards[0].key,
        itemId: 'ticket',
        checked: true,
        expectedRowId: rowId);
    expect(result.status, ChecklistWriteStatus.stale);
  });
  test('备份/恢复及游客迁移保留本地状态和原文', () async {
    await write();
    await write(index: 1, item: 'bag');
    final convs = await ConversationListDao.create(db);
    await convs
        .saveConversation(ConversationModel(cid: 7, icon: '', title: '合成卡片'));
    final service = BackupService(db);
    final bytes = await service.exportArchive(
        settings: AISettings.defaults(), accountHash: 'fixture');
    final restored = await newDb(), migrated = await newDb();
    try {
      await BackupService(restored)
          .importArchive(bytes, accountHash: 'fixture');
      await GuestMigrationService.mergeGuestData(from: db, to: migrated);
      for (final target in [restored, migrated]) {
        final targetDao = await MessageDao.create(target, cid: 7);
        final saved = MessageBlock.decodeList(
                (await targetDao.getBlocksByCreatedAt([100]))['msg_100'])
            .single as MainTextBlock;
        expect(saved.content, content);
        expect(saved.localCardStates[cards[0].key]!.checkedItemIds, {'ticket'});
        expect(saved.localCardStates[cards[1].key]!.checkedItemIds, {'bag'});
        expect(saved.protocolMessages, block.protocolMessages);
      }
    } finally {
      await restored.db.close();
      await migrated.db.close();
    }
  });

  test('协调器序列化同一卡操作，排队期间页面过期或账号改变不写库', () async {
    final auth = _CardTokenStorage();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => const {},
        syncHeaders: () => const {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: auth,
        onLogoutNavigate: () {}));
    var pageCurrent = true;
    final coordinator = ChecklistStateCoordinator(
        dao: dao, accountHash: 'fixture', isCurrent: () => pageCurrent);
    Future<ChecklistWriteResult> coordinated() => coordinator.setChecked(
        createdAt: 100,
        blockId: 'main',
        expectedContent: content,
        cardKey: cards[0].key,
        itemId: 'ticket',
        checked: true,
        expectedRowId: rowId,
        messageIsCurrent: () => true);
    final gate = Completer<void>();
    final lease = LoginDao.runWithStableAccount(
        expectedAccountHash: 'fixture', action: () => gate.future);
    final first = coordinated();
    expect((await coordinated()).status, ChecklistWriteStatus.stale);
    gate.complete();
    await lease;
    expect((await first).status, ChecklistWriteStatus.saved);
    await write(checked: false);
    for (final changeAccount in [false, true]) {
      final gate = Completer<void>();
      final lease = LoginDao.runWithStableAccount(
          expectedAccountHash: 'fixture', action: () => gate.future);
      // 先确保租约进入，再排队卡片操作。
      await Future<void>.delayed(Duration.zero);
      final pending = coordinated();
      changeAccount ? auth.account = 'other' : pageCurrent = false;
      gate.complete();
      try {
        await lease;
      } catch (_) {}
      expect((await pending).status, isNot(ChecklistWriteStatus.saved));
      expect((await reload()).localCardStates[cards[0].key]!.checkedItemIds,
          isEmpty);
      auth.account = 'fixture';
      pageCurrent = true;
    }
  });
}

class _CardTokenStorage implements TokenStorage {
  String account = 'fixture';
  @override
  Map<String, dynamic>? readProfileSync() =>
      {'accountHash': account, 'userName': '合成账号'};
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  String? readTokenSync() => 'fixture-token';
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  Future<void> clear() async {}
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}
