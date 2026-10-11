import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_card_persistence.dart';
import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Database db;
  late AssistantDao dao;
  late Directory root;
  late String currentAccount;
  late int restoreRevision;
  late AssistantOperationScope scope;
  late AssistantCardPersistence persistence;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    dao = await AssistantDao.create(HiDBManager.test(db));
    root = await Directory.systemTemp.createTemp('role-card-persistence-');
    currentAccount = 'synthetic-a';
    restoreRevision = 0;
    scope = AssistantOperationScope(
        accountHash: currentAccount,
        restoreRevision: restoreRevision,
        currentAccount: () => currentAccount,
        currentRestoreRevision: () => restoreRevision);
    persistence = AssistantCardPersistence(
        dao: dao,
        scope: scope,
        directoryResolver: () async => root,
        stableMutation: (action) => action(),
        stableMaintenance: (action) => action());
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  AssistantRoleCardResource resource(String text) => AssistantRoleCardResource(
      type: 'other',
      uri: 'embeded://assets/notes.txt',
      name: 'notes',
      ext: 'txt',
      archivePath: 'assets/notes.txt',
      bytes: Uint8List.fromList(utf8.encode(text)));
  Future<List<String>> content(String manifest) async => [
        for (final item in await AssistantRoleCardAssetStore.load(manifest,
            accountHash: 'synthetic-a', directoryResolver: () async => root))
          if (item.bytes != null) utf8.decode(item.bytes!),
      ];

  test('insert/rename/checked update preserves id and unknown DB column',
      () async {
    final first = await persistence.save(
        AssistantModel(name: '同名', prompt: '旧正文'),
        resources: [resource('旧字节')]);
    final second = await persistence.save(AssistantModel(name: '同名'),
        renameOnConflict: true);
    expect(second.committed.assistant.name, '同名 (2)');
    expect(first.committed.assistant.id, isNot(second.committed.assistant.id));
    await db.execute('alter table tb_assistant add column future text');
    await db.update('tb_assistant', {'future': '留存'},
        where: 'id = ?', whereArgs: [first.committed.assistant.id]);
    final expected = (await dao.snapshot(first.committed.assistant.id!))!;
    final candidate =
        AssistantModel.fromJson(first.committed.assistant.toJson())
          ..prompt = '更新';
    final saved = await persistence.save(candidate, expected: expected);
    expect(saved.committed.assistant.id, first.committed.assistant.id);
    expect(saved.committed.snapshot.row['future'], '留存');
    expect(await content(saved.committed.assistant.roleCardAssets), ['旧字节']);
    expect(first.committed.assistant.prompt, '旧正文');
  });
  test('CAS rejects deleted/changed/restore and never resurrects', () async {
    final saved = await dao.saveChecked(AssistantModel(name: '角色'));
    await db.update('tb_assistant', {'prompt': '外部更新'},
        where: 'id = ?', whereArgs: [saved.snapshot.id]);
    await expectLater(
        dao.saveChecked(saved.assistant, expected: saved.snapshot),
        throwsA(isA<AssistantMutationStale>()));
    await expectLater(dao.deleteChecked(saved.snapshot),
        throwsA(isA<AssistantMutationStale>()));
    final current = (await dao.snapshot(saved.snapshot.id))!;
    await dao.deleteChecked(current);
    await expectLater(dao.saveChecked(saved.assistant, expected: current),
        throwsA(isA<AssistantMutationStale>()));
    expect(await dao.snapshot(current.id), isNull);
    restoreRevision++;
    await expectLater(persistence.save(AssistantModel(name: '恢复后')),
        throwsA(isA<AssistantOperationExpired>()));
    expect((await db.query('tb_assistant')), isEmpty);
  });
  test(
      'resource already published then DB failure keeps complete old row and bytes',
      () async {
    final old = await persistence.save(
        AssistantModel(name: '角色', prompt: '旧正文'),
        resources: [resource('旧字节')]);
    final before = Map<String, Object?>.from(old.committed.snapshot.row);
    final candidate = AssistantModel.fromJson(old.committed.assistant.toJson())
      ..prompt = '新正文';
    final stagePaths = <String>[];
    await expectLater(
        persistence.save(candidate,
            expected: old.committed.snapshot,
            resources: [resource('新字节')],
            afterPrepared: () async {
              final files = await root
                  .list(recursive: true)
                  .where((file) => file is File)
                  .toList();
              stagePaths.addAll(files.map((file) => file.path));
              expect(stagePaths.length, 2);
            },
            beforeCommit: (_) async =>
                throw StateError('synthetic DB commit failure')),
        throwsStateError);
    expect((await dao.snapshot(old.committed.snapshot.id))!.row, before);
    expect(await content(old.committed.assistant.roleCardAssets), ['旧字节']);
    expect(
        await root.list(recursive: true).where((file) => file is File).length,
        1);
  });
  test('overwrite resource write failure does not replace old generation',
      () async {
    final old = await persistence
        .save(AssistantModel(name: '角色'), resources: [resource('旧')]);
    await expectLater(
        persistence.save(old.committed.assistant,
            expected: old.committed.snapshot,
            resources: [resource('新')],
            afterAssetWrite: (_) =>
                throw StateError('synthetic write failure')),
        throwsStateError);
    expect((await dao.snapshot(old.committed.snapshot.id))!.row,
        old.committed.snapshot.row);
    expect(await content(old.committed.assistant.roleCardAssets), ['旧']);
    expect(
        await root.list(recursive: true).where((file) => file is File).length,
        1);
  });
  test(
      'account/restore changes during preparation reject publication and remove owned files',
      () async {
    for (final accountSwitch in [true, false]) {
      currentAccount = 'synthetic-a';
      restoreRevision = 0;
      await expectLater(
          persistence.save(AssistantModel(name: '角色'),
              resources: [resource('合成')], afterPrepared: () async {
            if (accountSwitch) {
              currentAccount = 'synthetic-b';
            } else {
              restoreRevision++;
            }
          }),
          throwsA(isA<AssistantOperationExpired>()));
      expect(await db.query('tb_assistant'), isEmpty);
      expect(
          await root.list(recursive: true).where((file) => file is File).length,
          0);
    }
  });
  test(
      'success switches manifest; cleanup failure remains success with identifiable old generation',
      () async {
    final old = await persistence
        .save(AssistantModel(name: '角色'), resources: [resource('旧')]);
    final next = await persistence.save(old.committed.assistant,
        expected: old.committed.snapshot,
        resources: [resource('新')],
        beforeCleanup: () async =>
            throw StateError('synthetic cleanup failure'));
    expect(next.notices, ['角色已保存；旧资源已保留，会继续占用磁盘空间']);
    expect(await content(next.committed.assistant.roleCardAssets), ['新']);
    expect(await content(old.committed.assistant.roleCardAssets), ['旧']);
    expect((await dao.snapshot(old.committed.snapshot.id))!.row,
        next.committed.snapshot.row);
    final reopened = (await dao.getAssistant(old.committed.snapshot.id))!;
    expect(await content(reopened.roleCardAssets), ['新']);
  });
  test('published old generation retained even when query finds no references',
      () async {
    final old = await persistence
        .save(AssistantModel(name: '角色'), resources: [resource('旧')]);
    final next = await persistence.save(old.committed.assistant,
        expected: old.committed.snapshot, resources: [resource('新')]);
    expect(next.notices, contains('角色已保存；旧资源已保留，会继续占用磁盘空间'));
    expect(await content(next.committed.assistant.roleCardAssets), ['新']);
    expect(
        await root.list(recursive: true).where((file) => file is File).length,
        2);
    final other = await dao.saveChecked(AssistantModel(
        name: '其它', roleCardAssets: next.committed.assistant.roleCardAssets));
    final newer = await persistence.save(next.committed.assistant,
        expected: next.committed.snapshot, resources: [resource('更新')]);
    expect(await content(other.assistant.roleCardAssets), ['新']);
    expect(await content(newer.committed.assistant.roleCardAssets), ['更新']);
  });
  test(
      'reserved new id race rejects insert without partial row or resource leak',
      () async {
    await expectLater(
        persistence.save(AssistantModel(name: '迟到'),
            resources: [resource('迟到')],
            afterPrepared: () async =>
                dao.saveChecked(AssistantModel(name: '先到'))),
        throwsA(isA<DatabaseException>()));
    expect((await db.query('tb_assistant')).single['name'], '先到');
    expect(
        await root.list(recursive: true).where((file) => file is File).length,
        0);
  });
  test('post-commit lease failure never discards published bytes', () async {
    final checked = AssistantCardPersistence(
        dao: dao,
        scope: scope,
        directoryResolver: () async => root,
        stableMutation: (action) async {
          await action();
          currentAccount = 'synthetic-b';
          throw const AssistantOperationExpired();
        });
    final result = await checked
        .save(AssistantModel(name: '已提交'), resources: [resource('有效字节')]);
    expect(result.notices, isNotEmpty);
    expect(await content(result.committed.assistant.roleCardAssets), ['有效字节']);
    expect((await dao.snapshot(result.committed.snapshot.id))!.row,
        result.committed.snapshot.row);
  });
  for (final mutation in ['restore', 'new-reference']) {
    test('query then queued $mutation retains old and new published bytes',
        () async {
      final old = await persistence
          .save(AssistantModel(name: '角色'), resources: [resource('旧有效字节')]);
      final queried = Completer<void>();
      final resume = Completer<void>();
      var tail = Future<void>.value();
      Future<void> enqueue(Future<void> Function() action) {
        final result = tail.then((_) => action());
        tail = result.catchError((_) {});
        return result;
      }

      final protected = AssistantCardPersistence(
          dao: dao,
          scope: scope,
          directoryResolver: () async => root,
          stableMutation: (action) async {
            late AssistantMutationResult result;
            await enqueue(() async {
              result = await action();
            });
            return result;
          },
          stableMaintenance: enqueue);
      final saving = protected.save(old.committed.assistant,
          expected: old.committed.snapshot,
          resources: [resource('新有效字节')], afterCleanupReferenceRead: () async {
        queried.complete();
        await resume.future;
      });
      await queried.future;
      var executed = false;
      final referencing = enqueue(() async {
        executed = true;
        if (mutation == 'restore') {
          await db.update('tb_assistant',
              {'roleCardAssets': old.committed.assistant.roleCardAssets},
              where: 'id = ?', whereArgs: [old.committed.snapshot.id]);
          restoreRevision++;
        } else {
          await dao.saveChecked(AssistantModel(
              name: '新引用',
              roleCardAssets: old.committed.assistant.roleCardAssets));
        }
      });
      await Future<void>.delayed(Duration.zero);
      expect(executed, isFalse);
      resume.complete();
      final next = await saving;
      await referencing;
      expect(next.notices, contains('角色已保存；旧资源已保留，会继续占用磁盘空间'));
      expect(await content(old.committed.assistant.roleCardAssets), ['旧有效字节']);
      expect(await content(next.committed.assistant.roleCardAssets), ['新有效字节']);
    });
  }
  test('new conversation checks role and callback row in the same transaction',
      () async {
    final role = await dao.saveChecked(AssistantModel(name: '角色'));
    final conversations =
        await ConversationListDao.create(HiDBManager.test(db));
    final model = ConversationModel(
        cid: 101, icon: '', title: '合成会话', assistantId: role.snapshot.id);
    final row = await conversations.saveForAssistant(model,
        expectedAssistant: role.snapshot);
    final next = ConversationModel.fromJson(model.toJson())..title = '新标题';
    final updated = await conversations.saveForAssistant(next,
        expectedAssistant: role.snapshot, expectedConversation: row);
    expect(updated['title'], '新标题');
    await db.delete('tb_conversation_list', where: 'cid = ?', whereArgs: [101]);
    await expectLater(
        conversations.saveForAssistant(next,
            expectedAssistant: role.snapshot, expectedConversation: updated),
        throwsA(isA<AssistantMutationStale>()));
    expect(await db.query('tb_conversation_list'), isEmpty);
    await db.update('tb_assistant', {'prompt': 'changed'},
        where: 'id = ?', whereArgs: [role.snapshot.id]);
    await expectLater(
        conversations.saveForAssistant(model, expectedAssistant: role.snapshot),
        throwsA(isA<AssistantMutationStale>()));
    expect(await db.query('tb_conversation_list'), isEmpty);
  });
}
