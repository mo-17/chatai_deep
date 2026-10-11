import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/composer_reference_trigger.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/user_message_context.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HistoryMessageSnapshot sampleSnapshot({String account = 'a'}) =>
    HistoryMessageSnapshot(
        accountToken: AccountResourceScope.tokenFor(account),
        conversationId: 10,
        messageId: 7,
        createdAt: 99,
        title: '原对话',
        role: 'assistant',
        content: '完整正文\n不会递归读取工具、思考和附件',
        selectedAt: 100);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TextEditingValue value(String text,
          {TextRange composing = TextRange.empty}) =>
      TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: composing);

  test('新键入词边界触发；邮箱、转义、替换、IME 与多字符粘贴不触发', () {
    for (final text in ['', '你好 ', '问题（']) {
      expect(
          composerReferenceTrigger(value(text), value('$text@')), text.length);
    }
    for (final text in ['email', '姓名', r'\']) {
      expect(composerReferenceTrigger(value(text), value('$text@')), isNull);
    }
    expect(composerReferenceTrigger(value(''), value('粘贴@')), isNull);
    expect(
        composerReferenceTrigger(value(''),
            value('@', composing: const TextRange(start: 0, end: 1))),
        isNull);
    expect(composerReferenceTrigger(value('a'), value('@')), isNull);
  });

  test('冻结快照与块往返，不向模型暴露账号或数据库身份', () {
    final reference = ComposerReference.history(sampleSnapshot());
    final block = ReferenceBlock(
        id: 'ref_block',
        messageId: 'msg_1',
        createdAt: 1,
        status: MessageBlockStatus.success,
        reference: reference);
    final decoded = MessageBlock.decodeList(MessageBlock.encodeList([block]));
    expect((decoded.single as ReferenceBlock).reference.toJson(),
        reference.toJson());
    final text = userMessageExtraText(decoded);
    expect(text, contains(sampleSnapshot().content));
    expect(text, isNot(contains(sampleSnapshot().accountToken)));
    expect(text, isNot(contains('messageId')));
    final corrupted = reference.toJson()..['snapshotDigest'] = '0' * 64;
    expect(() => ComposerReference.fromJson(corrupted), throwsFormatException);
    final mixed = jsonDecode(MessageBlock.encodeList([block])) as List;
    mixed.add({'type': 'reference', 'id': 'broken', 'reference': corrupted});
    expect(MessageBlock.decodeList(jsonEncode(mixed)), hasLength(1),
        reason: '单个损坏引用不能清空同一消息的有效块');
    expect(
        reference
            .asUnavailable()
            .bindAttachment('/tmp/owned', '0' * 64)
            .available,
        isFalse,
        reason: '重绑定不会自动复活不可用标签');
  });

  test('消息引用块拒绝 file/photo 和任意附件路径，保留同消息的正文', () {
    for (final photo in [false, true]) {
      final forged = ComposerReference.attachment('/tmp/external-private.txt',
          photo: photo);
      expect(
          () => ReferenceBlock(
              id: 'forged',
              messageId: 'm',
              createdAt: 1,
              status: MessageBlockStatus.success,
              reference: forged),
          throwsFormatException);
      final decoded = MessageBlock.decodeList(jsonEncode([
        {'type': 'mainText', 'id': 'body', 'content': '保留原正文'},
        {'type': 'reference', 'id': 'forged', 'reference': forged.toJson()},
      ]));
      expect(decoded.single, isA<MainTextBlock>());
    }
  });

  group('引用草稿', () {
    late Directory directory;
    ConversationDraftStore store({String account = 'a', String cid = '10'}) =>
        ConversationDraftStore(
            conversationId: cid,
            accountHash: account,
            directoryResolver: () async => directory);
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('reference_draft_');
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test('纯引用也是草稿，v2重开保留且账号会话隔离', () async {
      final reference = ComposerReference.history(sampleSnapshot());
      final saved = await store().save(text: '', references: [reference]);
      expect(saved!.isEmpty, isFalse);
      expect((await store().load())!.references.single.toJson(),
          reference.toJson());
      expect(await store(account: 'b').load(), isNull);
      expect(await store(cid: '11').load(), isNull);
    });

    test('附件绑定托管路径，删除原文件仍可恢复；篡改后保留不可用标签', () async {
      final file = File('${directory.path}/picked.txt');
      await file.writeAsString('冻结文件');
      final reference = ComposerReference.attachment(file.path, photo: false);
      final saved = await store()
          .save(text: '', files: [file.path], references: [reference]);
      await file.delete();
      final loaded = (await store().load())!;
      expect(loaded.references.single.id, reference.id);
      expect(loaded.references.single.attachmentPath, loaded.filePaths.single);
      expect(loaded.references.single.snapshotDigest, hasLength(64));
      await File(saved!.filePaths.single).writeAsString('被篡改');
      final missing = (await store().load())!;
      expect(missing.filePaths, isEmpty);
      expect(missing.references.single.available, isFalse);
      expect(missing.isEmpty, isFalse);
    });

    test('v1兼容且伪造外部路径不获得读取能力', () async {
      await store().save(text: '旧文字');
      final manifest = (await directory
              .list(recursive: true)
              .where((e) => e.path.endsWith('draft.json'))
              .toList())
          .single as File;
      await manifest.writeAsString(jsonEncode(
          {'version': 1, 'text': 'v1文字', 'images': [], 'files': []}));
      expect((await store().load())!.text, 'v1文字');
      final reference =
          ComposerReference.attachment('/tmp/private.txt', photo: false);
      await manifest.writeAsString(jsonEncode({
        'version': 2,
        'text': '',
        'images': [],
        'files': [],
        'references': [reference.toJson()]
      }));
      expect((await store().load())!.references.single.available, isFalse);
      expect(await store().previewForReference(reference.id), isNull);
    });

    test('发送冻结超过草稿128MiB仍按256MiB配置放行，原草稿保持完整', () async {
      const mib = 1024 * 1024;
      await store().save(text: '此前草稿');
      final paths = <String>[];
      for (var i = 0; i < 5; i++) {
        final bytes = Uint8List(27 * mib)..[0] = i;
        paths.add(
            (await File('${directory.path}/large$i.txt').writeAsBytes(bytes))
                .path);
      }
      final references = paths
          .map((p) => ComposerReference.attachment(p, photo: false))
          .toList();
      await expectLater(
          store().save(text: '', files: paths, references: references),
          throwsA(isA<DraftStorageCapacityException>()));
      expect((await store().load())!.text, '此前草稿');
      final frozen = (await store().freezeForSend(
          text: '',
          files: paths,
          references: references,
          limits: const AttachmentProcessingLimits(
              maxTextFileBytes: 32 * mib, maxTotalFileBytes: 256 * mib)))!;
      expect(frozen.filePaths, hasLength(5));
      expect(frozen.references.every((r) => r.available), isTrue);
      var actual = 0;
      for (final path in frozen.filePaths) {
        actual += await File(path).length();
      }
      expect(actual, 135 * mib);
      expect((await store().load())!.text, '此前草稿', reason: '发送冻结不改写草稿manifest');
    });

    test('大文本预览从同一已验证字节解析，发送拒绝冻结后被替换的托管内容', () async {
      const mib = 1024 * 1024;
      const limits = AttachmentProcessingLimits(
          maxTextFileBytes: 32 * mib, maxTextChars: 1024);
      final bytes = Uint8List(11 * mib)..fillRange(0, 11 * mib, 65);
      final file = await File('${directory.path}/big.txt').writeAsBytes(bytes);
      final frozen = (await store().freezeForSend(
          text: '',
          files: [file.path],
          references: [ComposerReference.attachment(file.path, photo: false)],
          limits: limits))!;
      final proof = frozen.previewForReference(frozen.references.single.id)!;
      expect(await proof.readText(), startsWith('A' * 1024),
          reason: '11MiB不回退为10MiB读取失败');
      final verified = await proof.readBytes();
      await File(frozen.filePaths.single).writeAsString('替换后正文');
      expect(
          await FileProcessor.extractTextFromBytes(verified,
              filename: 'big.txt', limits: limits),
          startsWith('A' * 1024),
          reason: '解析已经验证的字节，不再次打开路径');
      final budget = AttachmentBatchBudget(limits: limits, expectedDigests: {
        frozen.filePaths.single: frozen.references.single.snapshotDigest
      });
      await expectLater(
          FileProcessor.process(frozen.filePaths, const ModelCapabilities(),
              limits: limits, batchBudget: budget),
          throwsA(isA<FormatException>()));
    });

    test('不同临时路径同内容只冻结一次，预览能力限定当前账号会话且拒绝篡改', () async {
      final one = await File('${directory.path}/one.txt').writeAsString('相同正文');
      final two = await File('${directory.path}/two.txt').writeAsString('相同正文');
      final saved = (await store().save(text: '', files: [
        one.path,
        two.path
      ], references: [
        ComposerReference.attachment(one.path, photo: false),
        ComposerReference.attachment(two.path, photo: false)
      ]))!;
      expect(saved.filePaths, hasLength(1));
      expect(saved.references, hasLength(1));
      final owned = await Directory(
              '${directory.path}/${ConversationDraftStore.directoryName}')
          .list(recursive: true)
          .where((e) => e is File && !e.path.endsWith('/draft.json'))
          .cast<File>()
          .toList();
      expect(owned, hasLength(1), reason: '同摘要不同文件名不能在磁盘上留下第二份副本');
      expect(await owned.single.length(), utf8.encode('相同正文').length);
      await store().save(
          text: '',
          files: [two.path],
          references: [ComposerReference.attachment(two.path, photo: false)]);
      expect(
          await Directory(
                  '${directory.path}/${ConversationDraftStore.directoryName}')
              .list(recursive: true)
              .where((e) => e is File && !e.path.endsWith('/draft.json'))
              .length,
          1,
          reason: '后续保存也复用已有摘要目录，不追加另一文件名');
      // 恢复原标签后验证预览能力。
      await store()
          .save(text: '', files: saved.filePaths, references: saved.references);
      final reference = saved.references.single;
      final proof = (await store().previewForReference(reference.id))!;
      await one.delete();
      await two.delete();
      expect(await proof.readText(), contains('相同正文'));
      expect(
          await store(account: 'b').previewForReference(reference.id), isNull);
      expect(await store(cid: '11').previewForReference(reference.id), isNull);
      await File(reference.attachmentPath!).writeAsString('被替换的内容');
      await expectLater(
          proof.readBytes(), throwsA(isA<DraftStorageException>()));
    });
  });

  test('有界分页、完整快照、文字LIKE转义；来源修改删除和迁移后不跳错行', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final storage = HiDBManager.test(db);
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 10, title: '资料对话', icon: ''));
    final messages = await MessageDao.create(storage, cid: 10);
    final ids = <int>[];
    for (var i = 0; i < 6; i++) {
      ids.add(await messages.saveMessageWithBlocks(MessageModel(
          ownerType: OwnerType.sender,
          content: '百分比%_ 第$i条 ${'正文' * 100}',
          createdAt: i + 1)));
    }
    final dao = MessageReferenceDao(storage, accountHash: 'a');
    final first = await dao.search(query: '%_', limit: 2);
    final second =
        await dao.search(query: '%_', beforeId: first.last.id, limit: 2);
    expect(
        first
            .map((e) => e.id)
            .toSet()
            .intersection(second.map((e) => e.id).toSet()),
        isEmpty);
    final snapshot = (await dao.snapshot(ids.first))!;
    expect(snapshot.content, hasLength(greaterThan(160)));
    expect(await dao.sourceStillMatches(snapshot), isTrue);
    expect(
        await MessageReferenceDao(storage, accountHash: 'b')
            .sourceStillMatches(snapshot),
        isFalse);
    await db.update('tb_messages', {'content': '修改后的来源'},
        where: 'id = ?', whereArgs: [ids.first]);
    expect(await dao.sourceStillMatches(snapshot), isFalse);
    expect(snapshot.content, contains('正文'));
    await db.delete('tb_messages', where: 'id = ?', whereArgs: [ids.first]);
    expect(await dao.sourceStillMatches(snapshot), isFalse);
  });
}
