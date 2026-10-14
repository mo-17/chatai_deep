import 'dart:async';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_composer_preparation.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'conversation_generation_preparation_test.dart' show eventually;
import 'conversation_generation_test.dart' as support;

class _Chat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  int requests = 0;
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    requests++;
    return const ChatCompletionResult(content: 'SYNTHETIC_REPLY');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late ConversationGenerationService service;
  late AISettings settings;
  late _Chat chat;
  late Directory base, resources;
  late int rowId;
  final gates = <Completer<Directory>>[];

  ConversationDraftStore draft(
          {int cid = 1,
          bool implicit = false,
          DraftDirectoryResolver? resolver}) =>
      ConversationDraftStore(
          conversationId: '$cid',
          accountHash: implicit ? null : 'a',
          directoryResolver: resolver ?? () async => base);
  MessageModel user() => MessageModel(
      ownerType: OwnerType.sender,
      content: 'task',
      createdAt: 10,
      ownerName: '合成');
  ConversationGenerationRun start(ConversationDraftStore store,
          {List<String> files = const []}) =>
      service.start(
          scope: ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(settings, 'a',
              loadSettings: () async => settings),
          input: ConversationGenerationInput(
              cid: 1, conversationRowId: rowId, user: user(), stream: false),
          preparation: ComposerGenerationPreparation(
              draftStore: store, text: 'task', files: files));
  Future<List<Map<String, Object?>>> replies() =>
      storage.db.query('tb_messages',
          where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]);
  Future<void> senderCommitted(ConversationGenerationRun run) async {
    await eventually(() async => run.record?.userRowId != null);
    expect(
        await storage.db.query('tb_messages',
            where: 'id=?', whereArgs: [run.record!.userRowId]),
        hasLength(1));
    expect(chat.requests, 0);
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    support.GenerationTestAuth().install();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    rowId = (await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 1, title: 'existing', icon: 'keep-avatar')))!;
    dao = await ConversationGenerationDao.create(storage);
    settings = support.generationSettings();
    chat = _Chat();
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
    base = await Directory.systemTemp.createTemp('l2_cleanup_drafts_');
    resources = await Directory.systemTemp.createTemp('l2_cleanup_resources_');
    ManagedAttachmentStore.debugRootDirectory = resources;
    gates.clear();
  });
  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete(base);
    }
    for (final run in service.runs.where((r) => r.busy)) {
      await run.retire('fixture cleanup').timeout(const Duration(seconds: 3));
    }
    service.dispose();
    BackupService.debugImportFailureInjector = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    ManagedAttachmentStore.debugRootDirectory = null;
    await storage.db.close();
    await base.delete(recursive: true);
    await resources.delete(recursive: true);
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  for (final control in [
    'stop',
    'text-stop',
    'cleanup-stop',
    'delete-stop',
    'login',
    'cleanup-login',
    'restore',
    'restore-rollback'
  ]) {
    test('sender committed held manifest settles $control without resolver',
        () async {
      final backup = BackupService(storage);
      List<int>? archive;
      if (control.startsWith('restore')) {
        BackupService.debugGeneratedImageDirectoryResolver =
            () async => resources;
        BackupService.debugRoleCardAssetsDirectoryResolver =
            () async => resources;
        archive =
            await backup.exportArchive(settings: settings, accountHash: 'a');
      }
      final source = File('${base.path}/source.txt');
      await source.writeAsString('SYNTHETIC_RESOURCE');
      await draft().save(text: 'task');
      final gate = Completer<Directory>();
      gates.add(gate);
      var entered = false, resolverCalls = 0;
      final run = start(draft(resolver: () {
        resolverCalls++;
        final precedingReads = control.startsWith('delete-')
            ? 2
            : control.startsWith('cleanup-')
                ? 1
                : 0;
        if (resolverCalls <= precedingReads) {
          return Future.value(base);
        }
        entered = true;
        return gate.future;
      }), files: control == 'text-stop' ? const [] : [source.path]);
      await senderCommitted(run);
      await eventually(() async => entered);
      expect(entered, isTrue);
      final saved = await storage.db.query('tb_messages',
          columns: ['blocks'],
          where: 'id=?',
          whereArgs: [run.record!.userRowId]);
      final publishedFiles = await resources
          .list(recursive: true)
          .where((entity) => entity is File)
          .toList();
      if (control == 'text-stop') {
        expect(saved.single['blocks'], contains('task'));
        expect(publishedFiles, isEmpty);
      } else {
        expect(saved.single['blocks'], contains('source.txt'));
        expect(publishedFiles, hasLength(1));
      }
      Future<void> action;
      if (control.endsWith('stop')) {
        action = run.stop('user stop');
      } else if (control.endsWith('login')) {
        action = LoginDao.saveAuthToken('synthetic-b',
            userName: '合成', extras: {'accountHash': 'b'});
      } else {
        if (control == 'restore-rollback') {
          BackupService.debugImportFailureInjector = (point) async {
            if (point == BackupImportFailurePoint.beforeResourceSwap) {
              throw StateError('synthetic rollback');
            }
          };
        }
        action = LoginDao.runWithStableAccount(
            expectedAccountHash: 'a',
            action: () async {
              await backup.importArchive(archive!, accountHash: 'a');
            });
      }
      try {
        if (control == 'restore-rollback') {
          await expectLater(
              action.timeout(const Duration(seconds: 1)), throwsStateError);
        } else {
          await action.timeout(const Duration(seconds: 1));
        }
        await run.finished.timeout(const Duration(seconds: 1));
        expect(run.executionStopped, isTrue);
        if (control.endsWith('stop')) expect(run.notice, 'user stop');
        expect(ConversationExecutionRegistry.instance.lookup('a', 1), isNull);
        expect(chat.requests, 0);
        // 新草稿在旧 resolver 返回前保存，旧清理不能删除它。
        await draft().save(text: 'new draft');
      } finally {
        if (!gate.isCompleted) gate.complete(base);
        await action
            .catchError((Object _) {})
            .timeout(const Duration(seconds: 3));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await draft().load())!.text, 'new draft');
      expect(chat.requests, 0);
      if (control.endsWith('stop')) {
        // 原引擎会保存空的中断占位；断言没有迟到正文与计费用量。
        expect(await replies(), hasLength(1));
        expect((await replies()).single['content'], '');
        expect(await storage.db.query('tb_usage'), isEmpty);
      } else {
        expect(await replies(), isEmpty);
      }
      // 普通停止/登录不会删除已发布资源；恢复采用原备份资源语义。
      if (control.endsWith('stop') || control.endsWith('login')) {
        for (final file in publishedFiles.cast<File>()) {
          expect(await file.readAsString(), 'SYNTHETIC_RESOURCE');
        }
        expect(await source.readAsString(), 'SYNTHETIC_RESOURCE');
      }
      debugPrint('HELD_MANIFEST:$control senderCommitted=true requests=0 '
          'newDraft=retained ticket=released');
    });
  }

  test('cross cid draft resolver stays outside Login lease and both settle',
      () async {
    await draft().save(text: 'task');
    final gate = Completer<Directory>();
    gates.add(gate);
    var entered = false, successfulProbe = false;
    final writing = draft(
        cid: 2,
        implicit: true,
        resolver: () {
          entered = true;
          return gate.future;
        }).save(text: 'cid2-new');
    writing.ignore();
    await eventually(() async => entered);
    final run = start(draft());
    await senderCommitted(run);
    // 清理已开始排队；探针用真实 SDK 队列，不使用直通 stableOperation。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      await LoginDao.runWithStableAccount(
              expectedAccountHash: 'a', action: () async {})
          .timeout(const Duration(seconds: 1));
      successfulProbe = true;
      gate.complete(base);
      await writing.timeout(const Duration(seconds: 2));
      await run.finished.timeout(const Duration(seconds: 2));
    } finally {
      if (!gate.isCompleted) {
        // red 轮必须可清理，不能把账号队列循环留给后续用例。
        gate.completeError(
            StateError('probe failed; fixture releases resolver'));
      }
      await writing.catchError((Object _) => null);
      await run.finished.timeout(const Duration(seconds: 3));
    }
    expect(successfulProbe, isTrue);
    expect((await draft(cid: 2).load())!.text, 'cid2-new');
    expect(await draft().load(), isNull);
    expect(chat.requests, 1);
    expect(await replies(), hasLength(1));
    debugPrint('CROSS_CID:realLoginProbe=true draft2=retained requests=1');
  });

  test('cancel queued cleanup releases before other cid resolver returns',
      () async {
    await draft().save(text: 'task');
    final gate = Completer<Directory>();
    gates.add(gate);
    var entered = false;
    final writing = draft(
        cid: 2,
        implicit: true,
        resolver: () {
          entered = true;
          return gate.future;
        }).save(text: 'cid2-new');
    writing.ignore();
    await eventually(() async => entered);
    final run = start(draft());
    await senderCommitted(run);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final stopping = run.stop('queued cleanup stop');
    try {
      await stopping.timeout(const Duration(seconds: 1));
      await LoginDao.runWithStableAccount(
              expectedAccountHash: 'a', action: () async {})
          .timeout(const Duration(seconds: 1));
    } finally {
      if (!gate.isCompleted) gate.complete(base);
      await writing;
      await stopping.timeout(const Duration(seconds: 3));
    }
    await draft().save(text: 'latest after stop');
    await draft().whenIdle();
    expect((await draft().load())!.text, 'latest after stop');
    expect((await draft(cid: 2).load())!.text, 'cid2-new');
    expect(chat.requests, 0);
    expect(await replies(), hasLength(1));
    expect((await replies()).single['content'], '');
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(ConversationExecutionRegistry.instance.lookup('a', 1), isNull);
  });

  for (final end in ['invalidate', 'recover', 'rollback']) {
    test('retry delete keeps true summary through $end', () async {
      final sourceId = await storage.db.insert('tb_messages',
          {...user().toJson(), 'cid': 1, 'memorySourceId': 'source-original'});
      final replyId = await storage.db.insert('tb_messages', {
        ...MessageModel(
                ownerType: OwnerType.receiver,
                content: 'OLD_REPLY_SUMMARY',
                createdAt: 20)
            .toJson(),
        'cid': 1
      });
      await storage.db.update(
          'tb_conversation_list',
          {
            'messageCount': 2,
            'lastMessage': 'OLD_REPLY_SUMMARY',
            'updateAt': 20,
            'stickTime': 900,
            'modelId': 'local-fixed'
          },
          where: 'id=?',
          whereArgs: [rowId]);
      final originalIndex = (await storage.db
              .query('tb_conversation_list', where: 'id=?', whereArgs: [rowId]))
          .single;
      final source = (await storage.db
              .query('tb_messages', where: 'id=?', whereArgs: [sourceId]))
          .single;
      final reply = (await storage.db
              .query('tb_messages', where: 'id=?', whereArgs: [replyId]))
          .single;
      final scope = ConversationGenerationScope(account: 'a');
      var record = await dao.begin(scope,
          runId: 'retry-run',
          cid: 1,
          conversationRowId: rowId,
          assistantId: null,
          sourceId: 'source-original',
          sourceHash: generationContentHash('task'),
          receiverId: 'reply-new',
          receiverAt: 30,
          existingUserRowId: sourceId,
          existingSourceRowHash: generationSourceRowHash(source),
          retryReplyRowId: replyId,
          retryReplyHash: generationSourceRowHash(reply));
      if (end == 'rollback') {
        await storage.db.execute(
            "create trigger refuse_summary before update of messageCount on tb_conversation_list begin select raise(abort,'summary blocked'); end");
        await expectLater(dao.acceptUser(scope, record, user()),
            throwsA(isA<DatabaseException>()));
        expect(
            (await storage.db
                    .query('tb_messages', where: 'id=?', whereArgs: [replyId]))
                .single,
            reply);
        expect(
            (await storage.db.query('tb_conversation_list',
                    where: 'id=?', whereArgs: [rowId]))
                .single,
            originalIndex);
        expect((await dao.read(record.runId))!.revision, record.revision);
        await storage.db.execute('drop trigger refuse_summary');
      }
      record = await dao.acceptUser(scope, record, user());
      final acceptedRevision = record.revision;
      record = await dao.acceptUser(scope, record, user());
      expect(record.revision, acceptedRevision);
      if (end == 'recover') {
        await dao.recoverInterrupted(scope);
      } else {
        await dao.invalidate(scope, record);
      }
      final index = (await storage.db
              .query('tb_conversation_list', where: 'id=?', whereArgs: [rowId]))
          .single;
      expect(index['messageCount'], 1);
      expect(index['lastMessage'], 'task');
      for (final key in originalIndex.keys
          .where((k) => k != 'messageCount' && k != 'lastMessage')) {
        expect(index[key], originalIndex[key], reason: 'preserve $key');
      }
      expect(await replies(), isEmpty);
      expect(chat.requests, 0);
      expect((await dao.read(record.runId))!.state, 'interrupted');
      debugPrint('RETRY_SUMMARY:$end count=1 last=task requests=0');
    });
  }
}
