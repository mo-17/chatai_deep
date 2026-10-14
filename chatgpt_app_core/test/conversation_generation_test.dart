import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class GenerationTestAuth implements TokenStorage {
  String? account = 'a', token = 'synthetic-a';
  void install() => LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => {},
      syncHeaders: () => {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: this,
      onLogoutNavigate: () {}));
  @override
  Future<void> clear() async {
    account = null;
    token = null;
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() =>
      {'accountHash': account, 'userName': '合成', 'avatar': ''};
  @override
  Future<String?> readToken() async => token;
  @override
  String? readTokenSync() => token;
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    this.token = token;
    account = extras['accountHash'] as String?;
  }
}

AISettings generationSettings() {
  final value = AISettings.defaults()
    ..providers = [
      AiProvider(
          id: 'fixture',
          type: 'openai',
          name: '合成',
          apiKey: 'synthetic',
          apiHost: 'http://localhost:12345/v1',
          enabled: true,
          models: [AiModel(id: 'gpt-4o-a'), AiModel(id: 'gpt-4o-b')])
    ]
    ..activeProviderId = 'fixture';
  value.setActiveModel('gpt-4o-a');
  return value;
}

Future<void> waitGeneration(bool Function() value) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (!value()) {
    if (DateTime.now().isAfter(until)) {
      throw TimeoutException('generation gate');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _HeldChat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  final gates = <String, Completer<void>>{};
  int requests = 0;
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  Future<void> _request(String prompt, List<Map<String, dynamic>> history,
      ChatRequestOptions options) async {
    await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    requests++;
    final gate = gates.putIfAbsent(prompt, Completer<void>.new);
    await Future.any(
        [gate.future, if (options.abortTrigger != null) options.abortTrigger!]);
    if (!gate.isCompleted) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '已停止',
          failureKind: ChatFailureKind.cancelled);
    }
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await _request(prompt, history, options);
    yield StreamEvent.text('reply:$prompt');
    yield StreamEvent.usage(promptTokens: 10, completionTokens: 5);
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    await _request(prompt, history, options);
    return ChatCompletionResult(
        content: 'reply:$prompt', promptTokens: 10, completionTokens: 5);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatePreparation implements ConversationTurnPreparation {
  final gate = Completer<void>();
  bool entered = false, released = false;
  final bool confirmation;
  _GatePreparation({this.confirmation = false});
  @override
  Future<PreparedConversationTurn> prepare(
      ConversationGenerationRun run) async {
    entered = true;
    if (confirmation) {
      if (!await run.confirm('保存文件', '合成文件')) throw StateError('未确认');
    } else {
      await gate.future;
    }
    return PreparedConversationTurn(prompt: run.input.user.content);
  }

  @override
  Future<void> release() async {
    released = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late ConversationListDao conversations;
  late ConversationGenerationService service;
  late _HeldChat chat;
  late AISettings settings;
  final rowIds = <int, int>{};
  ConversationGenerationRun start(int cid,
      {ConversationTurnPreparation? preparation, bool stream = true}) {
    final user = MessageModel(
        ownerType: OwnerType.sender, content: 'input$cid', createdAt: 10 + cid);
    return service.start(
        scope: ConversationGenerationScope(account: 'a'),
        dao: dao,
        profile: ConversationGenerationProfile(settings, 'a',
            loadSettings: () async => settings,
            visibleSettings: () => settings),
        input: ConversationGenerationInput(
            cid: cid,
            conversationRowId: rowIds[cid]!,
            user: user,
            stream: stream),
        preparation: preparation ??
            ReadyConversationTurn(
                PreparedConversationTurn(prompt: user.content)));
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    GenerationTestAuth().install();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    conversations = await ConversationListDao.create(storage);
    rowIds.clear();
    for (final cid in [1, 2, 3]) {
      rowIds[cid] = (await conversations.saveConversation(
          ConversationModel(cid: cid, title: 'cid$cid', icon: '')))!;
    }
    dao = await ConversationGenerationDao.create(storage);
    settings = generationSettings();
    chat = _HeldChat();
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
  });
  tearDown(() async {
    for (final run in service.runs.where((r) => r.busy)) {
      await run.stop('test cleanup');
    }
    service.dispose();
    await storage.db.close();
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  for (final stream in [true, false]) {
    test(
        'two ordinary runs survive detach/reconnect and each persist once stream=$stream',
        () async {
      final a = start(1, stream: stream), b = start(2, stream: stream);
      final host = Object();
      a.attachVisibleHost(host);
      a.detachVisibleHost(host);
      var notices1 = 0, notices2 = 0;
      a.addListener(() => notices1++);
      a.addListener(() => notices2++);
      await waitGeneration(() => chat.requests == 2);
      expect(identical(service.lookup('a', 1), a), isTrue);
      a.attachVisibleHost(Object());
      chat.gates['input1']!.complete();
      chat.gates['input2']!.complete();
      await Future.wait([a.finished, b.finished])
          .timeout(const Duration(seconds: 3));
      expect(a.stage, ConversationGenerationStage.complete);
      expect(b.stage, ConversationGenerationStage.complete);
      expect(chat.requests, 2);
      expect(notices1, greaterThan(0));
      expect(notices2, notices1);
      for (final cid in [1, 2]) {
        final rows = await storage.db.query('tb_messages',
            where: 'cid=?', whereArgs: [cid], orderBy: 'id asc');
        expect(rows, hasLength(2));
        expect(rows.last['content'], 'reply:input$cid');
        expect(
            await storage.db
                .query('tb_usage', where: 'cid=?', whereArgs: [cid]),
            hasLength(1));
      }
      final before = a.record!;
      final usage = UsageRecord.fromJson(
          (await storage.db.query('tb_usage', where: 'cid=1')).single)
        ..id = null;
      final repeated = await dao.saveReply(a.scope.finalWriteScope(), before,
          content: 'reply:input1',
          blocksJson: (await storage.db.query('tb_messages',
                  where: 'id=?', whereArgs: [before.receiverRowId]))
              .single['blocks'] as String,
          state: ConversationGenerationStage.complete,
          usage: usage);
      expect(repeated.receiverRowId, before.receiverRowId);
      expect(await storage.db.query('tb_usage'), hasLength(2));
    });
  }
  test(
      'third run and same-cid duplicate rejected synchronously before user/journal/POST',
      () async {
    final a = start(1), b = start(2);
    expect(() => start(3), throwsStateError);
    expect(() => start(1), throwsStateError);
    await waitGeneration(() => chat.requests == 2);
    expect(await storage.db.query('tb_messages', where: 'cid=3'), isEmpty);
    expect(await storage.db.query(dao.tableName, where: 'cid=3'), isEmpty);
    await a.stop('stop');
    await b.stop('stop');
    expect(chat.requests, 2);
  });
  test('preparation stop settles without release, no user or request',
      () async {
    final prep = _GatePreparation();
    final run = start(1, preparation: prep);
    await waitGeneration(() => prep.entered);
    await run.stop('停止准备').timeout(const Duration(seconds: 3));
    expect(run.stage, ConversationGenerationStage.interrupted);
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect(prep.released, isTrue);
    prep.gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(chat.requests, 0);
  });
  test('confirmation requires matching visible host after leaving page',
      () async {
    final prep = _GatePreparation(confirmation: true);
    final run = start(1, preparation: prep);
    final a = Object(), b = Object();
    run.attachVisibleHost(a);
    await waitGeneration(() => run.confirmation != null);
    final id = run.confirmation!.id;
    run.detachVisibleHost(a);
    expect(
        await run.answerConfirmation(
            host: a, confirmationId: id, accepted: true),
        isFalse);
    expect(
        await run.answerConfirmation(
            host: b, confirmationId: id, accepted: true),
        isFalse);
    expect(chat.requests, 0);
    run.attachVisibleHost(b);
    expect(
        await run.answerConfirmation(
            host: b, confirmationId: id, accepted: true),
        isTrue);
    await waitGeneration(() => chat.requests == 1);
    chat.gates['input1']!.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.complete);
  });
  test(
      'DB final transaction failure retains result, retry saves without another request',
      () async {
    final run = start(1);
    await waitGeneration(() => chat.requests == 1);
    await storage.db.execute(
        "create trigger fail_reply before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'synthetic disk failure'); end");
    chat.gates['input1']!.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.persistenceFailed);
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(await storage.db.query('tb_messages'), hasLength(1));
    await storage.db.execute('drop trigger fail_reply');
    await run.retryPersistence();
    await run.retryPersistence();
    expect(run.stage, ConversationGenerationStage.complete);
    expect(chat.requests, 1);
    expect(await storage.db.query('tb_messages'), hasLength(2));
    expect(await storage.db.query('tb_usage'), hasLength(1));
  });
  test(
      'confirmed source invalidation stays close-only after source restoration and failed journal cleanup',
      () async {
    final old = start(1);
    await waitGeneration(() => chat.requests == 1);
    final source = (await storage.db.query('tb_messages',
            where: 'id=?', whereArgs: [old.record!.userRowId]))
        .single;
    await storage.db.update('tb_messages',
        {'content': 'changed source', 'blocks': '[{"synthetic":"changed"}]'},
        where: 'id=?', whereArgs: [source['id']]);
    await storage.db.execute(
        "create trigger fail_close before update on tb_conversation_generation when NEW.state='interrupted' begin select raise(abort,'synthetic journal failure'); end");
    chat.gates['input1']!.complete();
    await old.finished.timeout(const Duration(seconds: 3));
    expect(old.persistencePending, isTrue);
    expect(old.executionStopped, isTrue);
    expect(old.receiver.content, 'reply:input1');
    expect(old.notice, contains('重试只关闭原记录'));
    final pending = (await dao.read(old.runId))!;
    expect(pending.terminal, isFalse);
    expect(service.registry.lookup('a', 1), same(old.ticket));
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(
        await storage.db.query('tb_messages',
            where: 'memorySourceId=?', whereArgs: [old.receiverId]),
        isEmpty);
    await storage.db.update('tb_messages',
        {'content': source['content'], 'blocks': source['blocks']},
        where: 'id=?', whereArgs: [source['id']]);
    expect(
        generationSourceRowHash((await storage.db
                .query('tb_messages', where: 'id=?', whereArgs: [source['id']]))
            .single),
        generationSourceRowHash(source));
    await storage.db.execute('drop trigger fail_close');
    await Future.wait([
      old.retryPersistence(),
      old.stop('用户停止'),
      old.retryPersistence(),
      old.stop('重复停止')
    ]).timeout(const Duration(seconds: 3));
    expect(old.stage, ConversationGenerationStage.interrupted);
    final closed = (await dao.read(old.runId))!;
    expect(closed.state, 'interrupted');
    expect(closed.revision, pending.revision + 1);
    expect(closed.receiverRowId, isNull);
    expect(closed.usageRowId, isNull);
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(
        await storage.db.query('tb_messages',
            where: 'memorySourceId=?', whereArgs: [old.receiverId]),
        isEmpty);
    expect(service.registry.lookup('a', 1), isNull);
    expect(chat.requests, 1);
    final next = service.start(
        scope: ConversationGenerationScope(account: 'a'),
        dao: dao,
        profile: ConversationGenerationProfile(settings, 'a',
            loadSettings: () async => settings),
        input: ConversationGenerationInput(
            cid: 1,
            conversationRowId: rowIds[1]!,
            user: MessageModel(
                ownerType: OwnerType.sender,
                content: 'fresh after invalidation',
                createdAt: 200)),
        preparation: ReadyConversationTurn(
            PreparedConversationTurn(prompt: 'fresh after invalidation')));
    await waitGeneration(() => chat.requests == 2);
    await Future.wait([old.retryPersistence(), old.stop('迟到停止')]);
    expect(service.registry.lookup('a', 1), same(next.ticket));
    chat.gates['fresh after invalidation']!.complete();
    await next.finished.timeout(const Duration(seconds: 3));
    expect(next.stage, ConversationGenerationStage.complete);
    expect(await storage.db.query('tb_usage'), hasLength(1));
    expect(
        await storage.db.query('tb_messages',
            where: 'memorySourceId=?', whereArgs: [old.receiverId]),
        isEmpty);
    expect(chat.requests, 2);
  });
  for (final finalJournal in [false, true]) {
    test(
        'persistent ${finalJournal ? "journal" : "reply"} failure then stop retains answer and zero-request save retry',
        () async {
      final run = start(1);
      await waitGeneration(() => chat.requests == 1);
      await storage.db.execute(finalJournal
          ? "create trigger disk_block before update on tb_conversation_generation when NEW.state='complete' or NEW.state='interrupted' begin select raise(abort,'synthetic disk'); end"
          : "create trigger disk_block before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'synthetic disk'); end");
      chat.gates['input1']!.complete();
      await run.finished;
      expect(run.persistencePending, isTrue);
      await Future.wait([run.stop('用户停止'), run.retryPersistence()]);
      expect(run.executionStopped, isTrue);
      expect(run.persistencePending, isTrue);
      expect(service.registry.lookup('a', 1), same(run.ticket));
      expect(await storage.db.query('tb_usage'), isEmpty);
      expect(run.receiver.content, 'reply:input1');
      await storage.db.execute('drop trigger disk_block');
      await Future.wait(
          [run.retryPersistence(), run.retryPersistence(), run.stop('再停止')]);
      expect(run.stage, ConversationGenerationStage.complete);
      expect((await dao.read(run.runId))!.state, 'complete');
      expect(await storage.db.query('tb_usage'), hasLength(1));
      expect(
          await storage.db
              .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
          hasLength(1));
      expect(chat.requests, 1);
      expect(service.registry.lookup('a', 1), isNull);
      final next = service.start(
          scope: ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(settings, 'a',
              loadSettings: () async => settings),
          input: ConversationGenerationInput(
              cid: 1,
              conversationRowId: rowIds[1]!,
              user: MessageModel(
                  ownerType: OwnerType.sender,
                  content: 'next',
                  createdAt: 200)),
          preparation:
              ReadyConversationTurn(PreparedConversationTurn(prompt: 'next')));
      await waitGeneration(() => chat.requests == 2);
      chat.gates['next']!.complete();
      await next.finished;
      expect(next.stage, ConversationGenerationStage.complete);
      await run.retryPersistence();
      expect(await storage.db.query('tb_usage'), hasLength(2));
    });
  }

  test(
      'explicit retirement preserves failed journal evidence until a current-account CAS can settle it',
      () async {
    final old = start(1);
    await waitGeneration(() => chat.requests == 1);
    await storage.db.execute(
        "create trigger disk_block before update on tb_conversation_generation when NEW.state='complete' or NEW.state='interrupted' begin select raise(abort,'synthetic disk'); end");
    chat.gates['input1']!.complete();
    await old.finished;
    await old.retire('明确维护');
    expect(old.persistencePending, isTrue);
    expect(service.registry.lookup('a', 1), isNull);
    ConversationGenerationRun submit(String prompt, int at) => service.start(
        scope: ConversationGenerationScope(account: 'a'),
        dao: dao,
        profile: ConversationGenerationProfile(settings, 'a',
            loadSettings: () async => settings),
        input: ConversationGenerationInput(
            cid: 1,
            conversationRowId: rowIds[1]!,
            user: MessageModel(
                ownerType: OwnerType.sender, content: prompt, createdAt: at)),
        preparation:
            ReadyConversationTurn(PreparedConversationTurn(prompt: prompt)));
    final refused = submit('blocked', 200);
    await refused.finished.timeout(const Duration(seconds: 3));
    expect(chat.requests, 1);
    expect(await storage.db.query('tb_conversation_generation'), hasLength(1));
    await storage.db.execute('drop trigger disk_block');
    final next = submit('new', 201);
    await waitGeneration(() => chat.requests == 2);
    await old.retryPersistence();
    await old.stop('迟到停止');
    expect(service.registry.lookup('a', 1), same(next.ticket));
    chat.gates['new']!.complete();
    await next.finished;
    expect((await dao.read(old.runId))!.state, 'interrupted');
    expect(await storage.db.query('tb_usage'), hasLength(1));
    expect(
        await storage.db.query('tb_messages', where: "content='reply:input1'"),
        isEmpty);
    expect(next.stage, ConversationGenerationStage.complete);
  });

  test(
      'maintenance retire cancels stop final-write queued behind real LoginDao ready hook without reentrant deadlock',
      () async {
    service.dispose();
    LoginDao.resetHooksForTest();
    final entered = Completer<void>(), release = Completer<void>();
    LoginDao.addLoginReadyHook(() async {
      entered.complete();
      await release.future;
    });
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
    final run = start(1);
    await waitGeneration(() => chat.requests == 1);
    await storage.db.execute(
        "create trigger disk_block before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'synthetic disk'); end");
    chat.gates['input1']!.complete();
    await run.finished;
    expect(run.persistencePending, isTrue);
    final login = LoginDao.saveAuthToken('synthetic-same-account',
        userName: '合成', extras: {'accountHash': 'a'});
    await entered.future;
    final stopping = run.stop('普通停止');
    await waitGeneration(
        () => run.stage == ConversationGenerationStage.persisting);
    release.complete();
    await Future.wait([login, stopping]).timeout(const Duration(seconds: 3));
    expect(service.registry.lookup('a', 1), isNull);
    expect((await dao.read(run.runId))!.terminal, isTrue);
    expect(chat.requests, 1);
    expect(await storage.db.query('tb_usage'), isEmpty);
    await storage.db.execute('drop trigger disk_block');
    await run.retryPersistence();
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(await storage.db.query('tb_messages'), hasLength(1));
  });
  test(
      'second maintenance retire cancels first journal cleanup queued behind real LoginDao ready hook',
      () async {
    service.dispose();
    LoginDao.resetHooksForTest();
    final entered = Completer<void>(), release = Completer<void>();
    LoginDao.addLoginReadyHook(() async {
      entered.complete();
      await release.future;
    });
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
    final run = start(1);
    await waitGeneration(() => chat.requests == 1);
    await storage.db.execute(
        "create trigger disk_block before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'synthetic disk'); end");
    chat.gates['input1']!.complete();
    await run.finished;
    final login = LoginDao.saveAuthToken('synthetic-same-account',
        userName: '合成', extras: {'accountHash': 'a'});
    await entered.future;
    final retiring = run.retire('第一次维护');
    await waitGeneration(
        () => run.stage == ConversationGenerationStage.persisting);
    release.complete();
    await Future.wait([login, retiring]).timeout(const Duration(seconds: 3));
    expect(run.executionStopped, isTrue);
    expect(run.busy, isFalse);
    expect(service.registry.lookup('a', 1), isNull);
    expect(chat.requests, 1);
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(await storage.db.query('tb_messages'), hasLength(1));
    await storage.db.execute('drop trigger disk_block');
    await run.retryPersistence();
    expect(await storage.db.query('tb_usage'), isEmpty);
  });

  for (final change in ['revision', 'replacement']) {
    test(
        'retired $change mismatch refuses to clean or adopt a replacement journal',
        () async {
      final old = start(1);
      await waitGeneration(() => chat.requests == 1);
      await storage.db.execute(
          "create trigger disk_block before update on tb_conversation_generation when NEW.state='complete' or NEW.state='interrupted' begin select raise(abort,'synthetic disk'); end");
      chat.gates['input1']!.complete();
      await old.finished;
      await old.retire('维护');
      await storage.db.execute('drop trigger disk_block');
      final changed = {
        'revision': old.record!.revision + 1,
        if (change == 'replacement') 'receiverId': 'different-receiver'
      };
      await storage.db.update('tb_conversation_generation', changed,
          where: 'runId=?', whereArgs: [old.runId]);
      final next = service.start(
          scope: ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(settings, 'a',
              loadSettings: () async => settings),
          input: ConversationGenerationInput(
              cid: 1,
              conversationRowId: rowIds[1]!,
              user: MessageModel(
                  ownerType: OwnerType.sender,
                  content: 'no-adoption',
                  createdAt: 202)),
          preparation: ReadyConversationTurn(
              PreparedConversationTurn(prompt: 'no-adoption')));
      await next.finished;
      expect(chat.requests, 1);
      expect((await dao.read(old.runId))!.state, 'generating');
      expect((await dao.read(old.runId))!.revision, changed['revision']);
      await old.retryPersistence();
      expect(await storage.db.query('tb_usage'), isEmpty);
    });
  }
  test(
      'source body changed while response pending rejects late reply and usage',
      () async {
    final run = start(1);
    await waitGeneration(() => chat.requests == 1);
    await storage.db.update('tb_messages', {'content': 'edited'},
        where: 'id=?', whereArgs: [run.record!.userRowId]);
    chat.gates['input1']!.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.interrupted);
    expect(await storage.db.query('tb_messages'), hasLength(1));
    expect(await storage.db.query('tb_usage'), isEmpty);
  });
  test(
      'DAO conversation delete stops held request then same cid cannot receive old result',
      () async {
    final run = start(1);
    await waitGeneration(() => chat.requests == 1);
    await conversations
        .deleteConversation(ConversationModel(id: rowIds[1], cid: 1, icon: ''))
        .timeout(const Duration(seconds: 3));
    rowIds[1] = (await conversations
        .saveConversation(ConversationModel(cid: 1, title: 'new', icon: '')))!;
    chat.gates['input1']!.complete();
    await run.finished;
    expect(await storage.db.query('tb_messages', where: 'cid=1'), isEmpty);
    expect(await storage.db.query(dao.tableName, where: 'cid=1'), isEmpty);
  });
  for (final account in ['a', 'b']) {
    test(
        'real LoginDao ready hook stops held request A->$account and releases cid',
        () async {
      final run = start(1);
      await waitGeneration(() => chat.requests == 1);
      await LoginDao.saveAuthToken('synthetic-new',
          userName: '合成',
          extras: {'accountHash': account}).timeout(const Duration(seconds: 3));
      await run.finished;
      expect(
          run.stage,
          account == 'a'
              ? ConversationGenerationStage.interrupted
              : ConversationGenerationStage.persistenceFailed);
      expect(run.executionStopped, isTrue);
      expect(run.busy, isFalse);
      expect(ConversationExecutionRegistry.instance.lookup('a', 1), isNull);
      chat.gates['input1']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
          await storage.db.query('tb_messages',
              where:
                  "ownerType='OwnerType.receiver' and content like 'reply:%'"),
          isEmpty);
    });
  }
  test(
      'reply plus usage roll back together if journal final CAS transaction fails',
      () async {
    final run = start(1);
    await waitGeneration(() => chat.requests == 1);
    await storage.db.execute(
        "create trigger fail_final before update on tb_conversation_generation "
        "when NEW.state='complete' begin select raise(abort,'synthetic journal failure'); end");
    chat.gates['input1']!.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.persistenceFailed);
    expect(await storage.db.query('tb_messages'), hasLength(1));
    expect(await storage.db.query('tb_usage'), isEmpty);
    await storage.db.execute('drop trigger fail_final');
    await run.retryPersistence();
    expect(run.stage, ConversationGenerationStage.complete);
    expect(chat.requests, 1);
    expect(await storage.db.query('tb_messages'), hasLength(2));
    expect(await storage.db.query('tb_usage'), hasLength(1));
  });
  test(
      'cancel after actual account lease acquisition waits for transaction rollback',
      () async {
    final scope = ConversationGenerationScope(account: 'a');
    final entered = Completer<void>(), release = Completer<void>();
    final transaction = scope.stable(() => storage.db.transaction((tx) async {
          await tx.insert('tb_messages', {
            'cid': 1,
            'content': 'should roll back',
            'ownerType': 'OwnerType.sender',
            'createdAt': 99
          });
          entered.complete();
          await release.future;
          scope.verify();
        }));
    final assertion =
        expectLater(transaction, throwsA(isA<ConversationGenerationStale>()));
    await entered.future;
    scope.cancel();
    var loginDone = false;
    final login = LoginDao.saveAuthToken('next',
        userName: '合成',
        extras: {'accountHash': 'b'}).then((_) => loginDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(loginDone, isFalse);
    release.complete();
    await assertion;
    await login;
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect(loginDone, isTrue);
  });
  test(
      'explicit retry binds existing user UUID and never inserts that user twice',
      () async {
    final old = start(1);
    await waitGeneration(() => chat.requests == 1);
    chat.gates['input1']!.complete();
    await old.finished;
    final source = (await storage.db.query('tb_messages',
            where: 'id=?', whereArgs: [old.record!.userRowId]))
        .single;
    await (await MessageDao.create(storage, cid: 1))
        .deleteMessage(old.record!.receiverRowId!);
    final retried = service.start(
        scope: ConversationGenerationScope(account: 'a'),
        dao: dao,
        profile: ConversationGenerationProfile(settings, 'a',
            loadSettings: () async => settings,
            visibleSettings: () => settings),
        input: ConversationGenerationInput(
            cid: 1,
            conversationRowId: rowIds[1]!,
            user: MessageModel.fromJson(source),
            existingUserRowId: source['id'] as int,
            existingSourceId: source['memorySourceId'] as String,
            existingSourceRowHash: generationSourceRowHash(source)),
        preparation:
            ReadyConversationTurn(PreparedConversationTurn(prompt: 'input1')));
    await retried.finished;
    expect(chat.requests, 2);
    expect(
        await storage.db
            .query('tb_messages', where: "ownerType='OwnerType.sender'"),
        hasLength(1));
    expect(
        await storage.db
            .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
        hasLength(1));
    expect(retried.record!.sourceId, old.record!.sourceId);
  });
  for (final column in ['images', 'blocks', 'createdAt']) {
    test(
        'retry captured full source rejects $column changed while waiting for real LoginDao lease',
        () async {
      final old = start(1);
      await waitGeneration(() => chat.requests == 1);
      chat.gates['input1']!.complete();
      await old.finished;
      final source = (await storage.db.query('tb_messages',
              where: 'id=?', whereArgs: [old.record!.userRowId]))
          .single;
      final captured = generationSourceRowHash(source);
      final entered = Completer<void>(), release = Completer<void>();
      final holding = LoginDao.runWithStableAccount(
          expectedAccountHash: 'a',
          action: () async {
            entered.complete();
            await release.future;
          });
      await entered.future;
      final retry = service.start(
          scope: ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(settings, 'a',
              loadSettings: () async => settings),
          input: ConversationGenerationInput(
              cid: 1,
              conversationRowId: rowIds[1]!,
              user: MessageModel.fromJson(source),
              existingUserRowId: source['id'] as int,
              existingSourceId: source['memorySourceId'] as String,
              existingSourceRowHash: captured),
          preparation: ReadyConversationTurn(
              PreparedConversationTurn(prompt: 'input1')));
      await storage.db.update(
          'tb_messages', {column: column == 'createdAt' ? 333 : '["changed"]'},
          where: 'id=?', whereArgs: [source['id']]);
      release.complete();
      await holding;
      await retry.finished;
      expect(chat.requests, 1);
      expect(retry.record, isNull);
      expect(
          await storage.db.query('tb_conversation_generation'), hasLength(1));
      expect(
          await storage.db
              .query('tb_messages', where: "ownerType='OwnerType.sender'"),
          hasLength(1));
      expect(
          await storage.db
              .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
          hasLength(1));
    });
  }
  for (final fail in [false, true]) {
    test(
        'real backup account lease cancels held generation before ${fail ? 'rollback' : 'commit'}',
        () async {
      final root = await Directory.systemTemp.createTemp('continuity-backup-');
      BackupService.debugGeneratedImageDirectoryResolver = () async => root;
      BackupService.debugRoleCardAssetsDirectoryResolver = () async => root;
      ManagedAttachmentStore.debugRootDirectory =
          Directory('${root.path}/attachments');
      addTearDown(() async {
        BackupService.debugImportFailureInjector = null;
        BackupService.debugGeneratedImageDirectoryResolver = null;
        BackupService.debugRoleCardAssetsDirectoryResolver = null;
        ManagedAttachmentStore.debugRootDirectory = null;
        await root.delete(recursive: true);
      });
      final backup = BackupService(storage);
      final bytes =
          await backup.exportArchive(settings: settings, accountHash: 'a');
      expect(
          ZipDecoder()
              .decodeBytes(bytes)
              .files
              .any((f) => f.name.contains('generation')),
          isFalse);
      final run = start(1);
      await waitGeneration(() => chat.requests == 1);
      if (fail) {
        BackupService.debugImportFailureInjector = (point) async {
          if (point == BackupImportFailurePoint.beforeResourceSwap) {
            throw StateError('synthetic restore failure');
          }
        };
      }
      final operation = LoginDao.runWithStableAccount(
              expectedAccountHash: 'a',
              action: () => backup.importArchive(bytes, accountHash: 'a'))
          .timeout(const Duration(seconds: 3));
      if (fail) {
        await expectLater(operation, throwsStateError);
      } else {
        await operation;
      }
      await run.finished;
      chat.gates['input1']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(chat.requests, 1);
      expect(run.stage, ConversationGenerationStage.interrupted);
      expect(
          await storage.db.query('tb_messages',
              where:
                  "ownerType='OwnerType.receiver' and content like 'reply:%'"),
          isEmpty);
      if (!fail) {
        expect(await storage.db.query(dao.tableName), isEmpty);
      } else {
        expect((await dao.read(run.runId))!.state, 'interrupted');
      }
      expect(ConversationExecutionRegistry.instance.lookup('a', 1), isNull);
    });
  }
  test('cold recovery only interrupts journal and never creates a request',
      () async {
    final scope = ConversationGenerationScope(account: 'a');
    final saved = await dao.begin(scope,
        runId: 'old-run',
        cid: 1,
        conversationRowId: rowIds[1]!,
        assistantId: null,
        sourceId: 'old-source',
        sourceHash: generationContentHash('input'),
        receiverId: 'old-reply',
        receiverAt: 100);
    await dao.recoverInterrupted(scope);
    expect((await dao.read(saved.runId))!.state, 'interrupted');
    expect(chat.requests, 0);
  });
  test('quiet provider configuration revocation stops an already held request',
      () async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    AISettingsDao.configureSecretStore(null);
    final provider = AISettingsProvider();
    await provider.update(settings, expectedAccountHash: 'a');
    final run = service.start(
        scope: ConversationGenerationScope(account: 'a'),
        dao: dao,
        profile: ConversationGenerationProfile(provider.settings, 'a'),
        input: ConversationGenerationInput(
            cid: 1,
            conversationRowId: rowIds[1]!,
            user: MessageModel(
                ownerType: OwnerType.sender,
                content: 'quiet-config',
                createdAt: 90)),
        preparation: ReadyConversationTurn(
            PreparedConversationTurn(prompt: 'quiet-config')));
    await waitGeneration(() => chat.requests == 1);
    final next = provider.settings.clone()
      ..activeProvider.apiKey = 'revoked-synthetic';
    await provider.update(next, notify: false, expectedAccountHash: 'a');
    await run.finished.timeout(const Duration(seconds: 3));
    expect(run.stage, ConversationGenerationStage.interrupted);
    expect(chat.requests, 1);
    expect(service.registry.lookup('a', 1), isNull);
    expect(run.record!.attempts, 1);
    expect(
        await storage.db.query('tb_messages',
            where: "ownerType='OwnerType.receiver' and content like 'reply:%'"),
        isEmpty);
    provider.dispose();
  });
  test(
      'shared owner excludes ordinary/Agent without serializing two ordinary cids',
      () async {
    final ownership = ConversationExecutionRegistry();
    final channel = AgentExecutionChannel(ownership: ownership);
    final owner = Object();
    final t = ownership.claim(
        account: 'a',
        cid: 1,
        owner: owner,
        kind: ConversationExecutionKind.ordinary,
        stop: (_) async {});
    expect(
        channel.run(
            accountHash: 'a',
            cid: 1,
            action: () async => 1,
            pause: (_) async {}),
        throwsStateError);
    final release = Completer<void>();
    final entered = Completer<void>();
    final active = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () async {
          entered.complete();
          await release.future;
        },
        pause: (_) async {});
    await entered.future;
    expect(
        () => ownership.claim(
            account: 'a',
            cid: 2,
            owner: Object(),
            kind: ConversationExecutionKind.ordinary,
            stop: (_) async {}),
        throwsStateError);
    ownership.release(t);
    final newer = ownership.claim(
        account: 'a',
        cid: 1,
        owner: Object(),
        kind: ConversationExecutionKind.ordinary,
        stop: (_) async {});
    ownership.release(t);
    expect(ownership.owns(newer), isTrue);
    ownership.release(newer);
    release.complete();
    await active;
  });
}
