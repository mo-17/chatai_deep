import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conversation_generation_test.dart' as support;

class _Chat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  int requests = 0;
  final done = Completer<void>();
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    requests++;
    await Future.any([done.future, options.abortTrigger!]);
    yield StreamEvent.text('合成回答');
    yield StreamEvent.usage(promptTokens: 3, completionTokens: 2);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late ConversationGenerationService service;
  late ConversationGenerationDao dao;
  late PersonalMemoryDao personal;
  late _Chat chat;
  late int id;
  late Directory resources;
  final evidence = <Map<String, Object?>>[];
  tearDownAll(() async {
    final path = Platform.environment['CHATAI_CANDIDATE_MAINTENANCE_EVIDENCE'];
    if (path != null) await File(path).writeAsString(jsonEncode(evidence));
  });
  setUp(() async {
    LoginDao.resetHooksForTest();
    support.GenerationTestAuth().install();
    resources = await Directory.systemTemp.createTemp('candidate_maintenance_');
    BackupService.debugGeneratedImageDirectoryResolver = () async => resources;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => resources;
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    id = (await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 1, title: 'synthetic', icon: '')))!;
    dao = await ConversationGenerationDao.create(storage);
    personal = await PersonalMemoryDao.create(storage, accountHash: 'a');
    await personal.setPreferences(
        revision: (await personal.preferences()).revision,
        enabled: true,
        suggestionsEnabled: true);
    chat = _Chat();
    service = ConversationGenerationService(
        createChat: (_) => chat,
        createMemory: (run) async => ConversationMemoryContext(
            storage: storage,
            accountHash: 'a',
            cid: 1,
            assistantId: null,
            taskMode: false,
            personal: personal,
            assistant: await AssistantMemoryDao.create(storage)));
  });
  tearDown(() async {
    for (final run in service.runs.where((r) => r.busy)) {
      await run.retire('test cleanup');
    }
    service.dispose();
    await storage.db.close();
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    BackupService.debugImportFailureInjector = null;
    await resources.delete(recursive: true);
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  ConversationGenerationRun start({ConversationGenerationScope? scope}) =>
      service.start(
          scope: scope ?? ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(
              support.generationSettings(), 'a',
              loadSettings: () async => support.generationSettings()),
          input: ConversationGenerationInput(
              cid: 1,
              conversationRowId: id,
              user: MessageModel(
                  ownerType: OwnerType.sender,
                  content: '我希望回答简短清楚',
                  createdAt: 10)),
          preparation: ReadyConversationTurn(
              PreparedConversationTurn(prompt: '我希望回答简短清楚')));
  test(
      'first successful persistence retry creates candidate once with original turn token and zero extra requests',
      () async {
    await storage.db.execute(
        "create trigger fail_reply before insert on tb_messages when new.ownerType='OwnerType.receiver' begin select raise(abort,'disk failed'); end");
    final run = start();
    await support.waitGeneration(() => chat.requests == 1);
    chat.done.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.persistenceFailed);
    expect(await storage.db.query('tb_personal_memory'), isEmpty);
    expect(await storage.db.query('tb_usage'), isEmpty);
    await storage.db.execute('drop trigger fail_reply');
    await Future.wait([run.retryPersistence(), run.retryPersistence()]);
    expect(run.stage, ConversationGenerationStage.complete);
    final pending = await storage.db.query('tb_personal_memory');
    expect(pending, hasLength(1));
    expect(pending.single['status'], 'pending');
    expect(pending.single['confirmedByUser'], 0);
    expect(await storage.db.query('tb_personal_memory_journal'), hasLength(1));
    expect(await storage.db.query('tb_usage'), hasLength(1));
    expect(chat.requests, 1);
    await run.retryPersistence();
    await run.stop('already saved');
    expect(await storage.db.query('tb_personal_memory'), pending);
    expect(chat.requests, 1);
  });
  test(
      'suggestion epoch revoked while final save failed does not acquire new authorization',
      () async {
    await storage.db.execute(
        "create trigger fail_reply before insert on tb_messages when new.ownerType='OwnerType.receiver' begin select raise(abort,'disk failed'); end");
    final run = start();
    await support.waitGeneration(() => chat.requests == 1);
    chat.done.complete();
    await run.finished;
    final prefs = await personal.preferences();
    await personal.setPreferences(
        revision: prefs.revision, enabled: false, suggestionsEnabled: false);
    await personal.setPreferences(
        revision: (await personal.preferences()).revision,
        enabled: true,
        suggestionsEnabled: true);
    await storage.db.execute('drop trigger fail_reply');
    await run.retryPersistence();
    expect(run.stage, ConversationGenerationStage.complete);
    expect(await storage.db.query('tb_personal_memory'), isEmpty);
    expect(chat.requests, 1);
  });
  test(
      'stop before model completion never suggests even though interrupted placeholder persists',
      () async {
    final run = start();
    await support.waitGeneration(() => chat.requests == 1);
    await run.stop('user stopped');
    expect(await storage.db.query('tb_personal_memory'), isEmpty);
    expect(chat.requests, 1);
  });
  for (final action in ['source-blocks', 'relogin']) {
    test(
        'candidate transaction rejects $action between reply commit and queued collection',
        () async {
      final committed = Completer<void>(), release = Completer<void>();
      var blocked = false, epoch = 0;
      LoginDao.addLoginHook(() => epoch++);
      final scope = ConversationGenerationScope(
          account: 'a',
          currentEpoch: () => epoch,
          stableOperation: (operation) => LoginDao.runWithStableAccount(
              expectedAccountHash: 'a',
              action: () async {
                await operation();
                if (!blocked &&
                    (await storage.db.query('tb_usage')).isNotEmpty) {
                  blocked = true;
                  committed.complete();
                  await release.future.timeout(const Duration(seconds: 3));
                }
              }));
      final run = start(scope: scope);
      await support.waitGeneration(() => chat.requests == 1);
      chat.done.complete();
      await committed.future.timeout(const Duration(seconds: 3));
      Future<void>? login;
      if (action == 'source-blocks') {
        await storage.db.update(
            'tb_messages', {'blocks': '[{"type":"changed"}]'},
            where: 'id=?', whereArgs: [run.record!.userRowId]);
      } else {
        login = LoginDao.saveAuthToken('synthetic-again',
            userName: 'synthetic', extras: {'accountHash': 'a'});
      }
      release.complete();
      await login;
      await run.finished;
      expect(await storage.db.query('tb_personal_memory'), isEmpty);
      expect(await storage.db.query('tb_personal_memory_journal'), isEmpty);
      expect(await storage.db.query('tb_usage'), hasLength(1));
      expect(chat.requests, 1);
      expect(
          (await storage.db.query('tb_messages',
              where: 'ownerType=?',
              whereArgs: [OwnerType.receiver.toString()])),
          hasLength(1));
    });
  }
  for (final rollback in [false, true]) {
    test(
        'persistence retry queued candidate cancelled by real outer Login backup ${rollback ? 'rollback' : 'commit'} maintenance without deadlock',
        () async {
      final backup = BackupService(storage);
      final archive = await backup.exportArchive(
          settings: support.generationSettings(), accountHash: 'a');
      await storage.db.execute(
          "create trigger fail_reply before insert on tb_messages when new.ownerType='OwnerType.receiver' begin select raise(abort,'disk failed'); end");
      final run = start();
      await support.waitGeneration(() => chat.requests == 1);
      chat.done.complete();
      await run.finished;
      expect(run.stage, ConversationGenerationStage.persistenceFailed);
      await storage.db.execute('drop trigger fail_reply');
      final blocked = Completer<void>(), entered = Completer<void>();
      final outerEntered = Completer<void>(), releaseOuter = Completer<void>();
      final blocker = LoginDao.runWithStableAccount(
          expectedAccountHash: 'a',
          action: () async {
            entered.complete();
            await blocked.future.timeout(const Duration(seconds: 3));
          });
      await entered.future;
      final retry = run.retryPersistence();
      await support.waitGeneration(
          () => run.stage == ConversationGenerationStage.persisting);
      // settlement/write 入队也使用 microtask，先让 final 真正排在 blocker 后。
      await Future<void>.delayed(Duration.zero);
      final restore = LoginDao.runWithStableAccount(
          expectedAccountHash: 'a',
          action: () async {
            outerEntered.complete();
            await releaseOuter.future.timeout(const Duration(seconds: 3));
            await backup.importArchive(archive, accountHash: 'a');
          });
      final restoreChecked =
          rollback ? expectLater(restore, throwsA(anything)) : restore;
      blocked.complete();
      await blocker;
      await outerEntered.future.timeout(const Duration(seconds: 3));
      expect(run.stage, ConversationGenerationStage.complete,
          reason: '外层许可必须排在 final 短事务后');
      expect(await storage.db.query('tb_usage'), hasLength(1));
      expect(
          (await storage.db.query('tb_messages',
              where: 'ownerType=?',
              whereArgs: [OwnerType.receiver.toString()])),
          hasLength(1));
      expect(await storage.db.query('tb_personal_memory'), isEmpty);
      final before = await storage.db.query('tb_messages');
      if (rollback) {
        BackupService.debugImportFailureInjector = (point) async {
          if (point == BackupImportFailurePoint.beforeResourceSwap) {
            throw StateError('synthetic rollback');
          }
        };
      }
      // 外层已占账号许可；候选只能排在其后。维护必须取消该原许可等待，不能绕开。
      releaseOuter.complete();
      await Future.wait([retry, restoreChecked])
          .timeout(const Duration(seconds: 5));
      expect(service.registry.owns(run.ticket), isFalse);
      expect(chat.requests, 1);
      expect(await storage.db.query('tb_personal_memory'), isEmpty);
      expect(await storage.db.query('tb_personal_memory_journal'), isEmpty);
      final after = await storage.db.query('tb_messages');
      expect(after, rollback ? before : isEmpty);
      await LoginDao.runWithStableAccount(
          expectedAccountHash: 'a', action: () async {});
      evidence.add({
        'case': 'retry-candidate-backup-${rollback ? 'rollback' : 'commit'}',
        'fakeModelRequests': chat.requests,
        'candidateRows': [],
        'messagesBefore': before,
        'messagesAfter': after,
        'journalAfter': await storage.db.query(dao.tableName),
        'usageAfter': await storage.db.query('tb_usage'),
        'ticketReleased': true
      });
    });
  }
}
