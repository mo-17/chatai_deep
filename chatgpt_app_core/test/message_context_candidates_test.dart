import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Database db;
  late MessageDao dao;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    dao = await MessageDao.create(HiDBManager.test(db), cid: 1);
  });
  tearDown(() async => db.close());

  Future<void> insert(int time, String content,
      {bool user = true, String? images, String? blocks, int cid = 1}) async {
    await db.insert('tb_messages', {
      'cid': cid,
      'createdAt': time,
      'content': content,
      'ownerType': (user ? OwnerType.sender : OwnerType.receiver).toString(),
      if (images != null) 'images': images,
      if (blocks != null) 'blocks': blocks,
    });
  }

  test('旧纯文本数据正序返回，不影响原聊天分页或内容', () async {
    await insert(1, '旧提问');
    await insert(2, '旧回答', user: false);
    final before = await db.query('tb_messages');
    final result = await dao.loadContextCandidates();
    expect(result.messages.map((m) => m.content), ['旧提问', '旧回答']);
    expect(result.hasEarlierMessages, isFalse);
    expect(result.storedBytes, utf8.encode('旧提问旧回答').length);
    expect(await db.query('tb_messages'), before);
    expect((await dao.getMessages()).map((m) => m.content), ['旧提问', '旧回答']);
  });

  test('消息数边界丢弃较早半轮，保留最新完整user轮', () async {
    for (var i = 1; i <= 8; i++) {
      await insert(i, 'message $i', user: i.isOdd);
    }
    final result = await dao.loadContextCandidates(maxMessages: 3);
    expect(result.messages.map((m) => m.createdAt), [7, 8]);
    expect(result.messages.first.ownerType, OwnerType.sender);
    expect(result.hasEarlierMessages, isTrue);
    expect(await dao.getMessageCount(), 8);
  });

  test('多页轻量扫描在1000条候选内结束，历史记录未删除', () async {
    await db.transaction((txn) async {
      for (var i = 1; i <= 1200; i++) {
        await txn.insert('tb_messages', {
          'cid': 1,
          'createdAt': i,
          'content': 'm$i',
          'blocks': 'blocks_$i',
          'ownerType':
              (i.isOdd ? OwnerType.sender : OwnerType.receiver).toString(),
        });
      }
    });
    final result = await dao.loadContextCandidates();
    expect(result.messages.length, 1000);
    expect(result.messages.first.createdAt, 201);
    expect(result.messages.last.createdAt, 1200);
    expect(result.hasEarlierMessages, isTrue);
    expect(await dao.getMessageCount(), 1200);
    final blocks = await dao.getBlocksByCreatedAt(
        result.messages.map((message) => message.createdAt));
    expect(blocks.length, 1000);
    expect(blocks.values, contains('blocks_1200'));
    expect(blocks.values, isNot(contains('blocks_200')));
  });

  test('字节预算包含中文utf8、图片和blocks，旧图片照常恢复', () async {
    await insert(1, 'old ' * 100);
    final images = jsonEncode(['data:image/png;base64,eA==']);
    final blocks = jsonEncode([
      {'type': 'mainText', 'content': 'old block'}
    ]);
    await insert(2, '中文', images: images, blocks: blocks);
    final latestBytes = utf8.encode('中文$images$blocks').length;
    final result = await dao.loadContextCandidates(maxStoredBytes: latestBytes);
    expect(result.messages, hasLength(1));
    expect(
        result.messages.single.imageUrlsOrB64, ['data:image/png;base64,eA==']);
    expect(result.storedBytes, latestBytes);
    expect(result.hasEarlierMessages, isTrue);
    final restoredBlocks = await dao.getBlocksByCreatedAt([2]);
    expect(restoredBlocks.values.single, blocks);
  });

  test('单条最新大图片仍保留，但不再加载更多历史', () async {
    await insert(1, 'old');
    await insert(2, '最新图片',
        images: jsonEncode(['data:image/png;base64,${'a' * 4096}']));
    final result = await dao.loadContextCandidates(maxStoredBytes: 1024);
    expect(result.messages.map((m) => m.createdAt), [2]);
    expect(result.exceededStoredByteBudget, isTrue);
    expect(result.hasEarlierMessages, isTrue);
    expect(result.messages.single.imageUrlsOrB64!.single.length,
        greaterThan(4096));
  });

  test('最新大图片user和小assistant按完整轮保留，更早整轮不累积', () async {
    await insert(1, '更早提问');
    await insert(2, '更早回答', user: false);
    final image = 'data:image/png;base64,${'a' * 4096}';
    await insert(3, '最新大图片', images: jsonEncode([image]));
    await insert(4, '图片是蓝色圆形', user: false);
    final result = await dao.loadContextCandidates(maxStoredBytes: 1024);
    expect(result.messages.map((m) => m.createdAt), [3, 4]);
    expect(result.messages.first.imageUrlsOrB64, [image]);
    expect(result.messages.last.ownerType, OwnerType.receiver);
    expect(result.exceededStoredByteBudget, isTrue);
    expect(result.hasEarlierMessages, isTrue);
    expect(await dao.getMessageCount(), 4);
  });

  test('更早的大图轮整体省略，不留下它的孤立assistant', () async {
    await insert(1, 'old image',
        images: jsonEncode(['data:image/png;base64,${'a' * 4096}']));
    await insert(2, 'old image answer', user: false);
    await insert(3, 'new question');
    await insert(4, 'new answer', user: false);
    final result = await dao.loadContextCandidates(maxStoredBytes: 1024);
    expect(result.messages.map((m) => m.createdAt), [3, 4]);
    expect(result.exceededStoredByteBudget, isFalse);
    expect(result.hasEarlierMessages, isTrue);
  });

  test('多个大图不会都跨SQLite传输，仅保留最新尾部', () async {
    for (var i = 1; i <= 6; i++) {
      await insert(i, 'image $i',
          images: jsonEncode(['data:image/png;base64,${'a' * 3000}']));
    }
    final result = await dao.loadContextCandidates(maxStoredBytes: 7000);
    expect(result.messages.map((m) => m.createdAt), [5, 6]);
    expect(result.storedBytes, lessThanOrEqualTo(7000));
    expect(await dao.getMessageCount(), 6);
  });

  test('会话隔离、空会话与参数边界', () async {
    await insert(1, '其他会话', cid: 2);
    expect((await dao.loadContextCandidates()).messages, isEmpty);
    expect((await dao.loadContextCandidates()).hasEarlierMessages, isFalse);
    await expectLater(
        dao.loadContextCandidates(maxMessages: 0), throwsArgumentError);
    await expectLater(
        dao.loadContextCandidates(maxStoredBytes: 0), throwsArgumentError);
  });
}
