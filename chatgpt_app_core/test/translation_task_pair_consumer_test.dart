import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_finalizer.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_selection_session.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

class PrepareGate
    implements
        ChatService,
        BackendSelectionPreparingChatService,
        OptionsAwareChatService {
  final ChatService actual;
  final Completer<void> entered = Completer(), release = Completer();
  PrepareGate(this.actual);
  @override
  Future<BackendSelection> prepareBackendSelection(
      {Future<void>? abortTrigger}) async {
    final pair = await (actual as BackendSelectionPreparingChatService)
        .prepareBackendSelection(abortTrigger: abortTrigger);
    entered.complete();
    await release.future;
    return pair;
  }

  @override
  void verifyPreparedBackendSelection(BackendSelection p) =>
      (actual as BackendSelectionPreparingChatService)
          .verifyPreparedBackendSelection(p);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const [],
          required ChatRequestOptions options}) =>
      actual.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages,
          options: options);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('unused fixture method');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database db;
  late HiDBManager storage;
  late StoryTemplateTranslationTaskDao dao;
  late StoryTemplateDao templates;
  late StoryTemplateTranslationCoordinator coordinator;
  late PairTokens tokens;
  late AISettings settings;
  late String oldHost;
  late bool oldHttps;
  int serial = 0, gets = 0, factories = 0;
  bool empty = false, unique = false;
  PrepareGate? held;
  Completer<void>? postGate, postEntered;
  final posts = <Map<String, dynamic>>[], evidence = <Map<String, Object?>>[];
  BackendSelection pair(String code,
          {String account = 'account-a', String? origin}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: 'same',
          accountHash: account,
          origin: origin ?? BackendConfig.buildUri('/uapi/ai/catalog').origin);
  TranslationRequestProfile profile(BackendSelection? p) =>
      TranslationRequestProfile(
          mode: TranslationExecutionMode.backend,
          modelId: 'same',
          backendSelection: p,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          reasoningControlSuppressed: false);
  final payload = StoryRoomTemplatePayload(results: [
    AssistantRoleCardImportResult(
        assistant: AssistantModel(
            name: 'Alice',
            prompt: 'Answer in English.',
            description: 'A kind friend.'))
  ]);
  StoryTemplateModel template() => payload.toTemplate(
      title: 'Synthetic original', sourceTitle: 'fixture', translated: false);
  TranslationEligibilityResult allow(TranslationRequestProfile p) =>
      const TranslationEligibilityResult();
  TranslationStreamExecutor executor(TranslationRequestProfile p,
      {bool hold = false, BackendSelection? wrong}) {
    factories++;
    final actual = ChatService.from(TranslationModelResolver.apply(
        settings, wrong == null ? p : profile(wrong)));
    if (p.backendSelection != null && wrong == null) {
      expect(actual.capabilities.tool, p.backendSelection!.providerCode == 'A');
    }
    final service = hold ? (held = PrepareGate(actual)) : actual;
    return TranslationStreamExecutor(
        service: service,
        profile: p,
        firstEventTimeout: const Duration(seconds: 2),
        idleTimeout: const Duration(seconds: 2),
        totalTimeout: const Duration(seconds: 4));
  }

  Future<void> wait(bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'bounded task settlement');
  }

  Future<StoryTemplateTranslationTaskModel> seed(TranslationRequestProfile p,
      {int attempts = 0, String? status}) async {
    final t = StoryTemplateTranslationTaskModel(
        sourceTitle: 'old',
        sourcePayload: jsonEncode(payload.toJson()),
        outputTitle: 'copy',
        requestProfile: jsonEncode(p.toJson()),
        attempts: attempts,
        status: status ?? StoryTemplateTranslationTaskStatus.queued,
        log: attempts == 0 ? '已创建中文副本任务' : 'old attempt',
        error: attempts == 0 ? '' : 'unknown_send',
        partialPayload: attempts == 0 ? '' : '{"kept":"original"}');
    await dao.saveTask(t);
    return t;
  }

  Future<void> initialize() =>
      coordinator.initialize(storage, accountHash: 'account-a');
  Future<void> settled() => wait(() =>
      coordinator.tasks.isNotEmpty &&
      ![
        StoryTemplateTranslationTaskStatus.queued,
        StoryTemplateTranslationTaskStatus.running
      ].contains(coordinator.tasks.single.status));
  Future<void> mocked(Future<void> Function() body) =>
      http.runWithClient(() async {
        try {
          await ModelCatalog.refreshFromBackend();
          await body();
        } finally {
          if (held?.release.isCompleted == false) held!.release.complete();
          if (postGate?.isCompleted == false) postGate!.complete();
          await coordinator.detachForLifecycle();
        }
      },
          () => MockClient((r) async {
                try {
                  expect(r.url.host, 'task.synthetic.invalid');
                  expect(r.headers['Authorization'], 'Bearer synthetic-jwt');
                  if (r.url.path == '/uapi/ai/catalog') {
                    return http.Response(
                        jsonEncode({
                          'code': 0,
                          'data': {
                            'providers': [
                              for (final p in empty
                                  ? <String>[]
                                  : unique
                                      ? ['A']
                                      : ['A', 'B'])
                                {'code': p, 'displayName': 'Synthetic $p'}
                            ],
                            'models': [
                              for (final p in empty
                                  ? <String>[]
                                  : unique
                                      ? ['A']
                                      : ['A', 'B'])
                                {
                                  'providerCode': p,
                                  'modelId': 'same',
                                  'displayName': 'same',
                                  'supportsTool': p == 'A',
                                  'supportsVision': false,
                                  'supportsPdf': false,
                                  'supportsReasoning': false
                                }
                            ]
                          }
                        }),
                        200);
                  }
                  if (r.url.path == '/uapi/ai/model-selection') {
                    gets++;
                    if (!unique) {
                      return http.Response(
                          jsonEncode({
                            'safeCode': 'model_ambiguous',
                            'message': 'synthetic SQL secret'
                          }),
                          409);
                    }
                    return http.Response(
                        jsonEncode({
                          'code': 0,
                          'data': {
                            'providerCode': 'A',
                            'modelId': r.url.queryParameters['modelId']
                          }
                        }),
                        200);
                  }
                  expect(r.method, 'POST');
                  expect(r.url.path, '/uapi/chat/completions/stream');
                  final body = jsonDecode(r.body) as Map<String, dynamic>;
                  posts.add(body);
                  final rows = await dao.getTasks();
                  expect(rows.single.status,
                      StoryTemplateTranslationTaskStatus.running);
                  expect(rows.single.attempts, greaterThan(0));
                  expect(
                      jsonDecode(rows.single.requestProfile)['backendSelection']
                          ['providerCode'],
                      body['providerCode']);
                  if (postEntered?.isCompleted == false) {
                    postEntered!.complete();
                  }
                  if (postGate != null) await postGate!.future;
                  return http.Response(
                      'data: ${jsonEncode({
                            'choices': [
                              {
                                'delta': {
                                  'content': jsonEncode({
                                    for (final key in (jsonDecode(
                                            (body['messages'] as List)
                                                .last['content']
                                                .toString()
                                                .split('\n')
                                                .last) as Map)
                                        .keys)
                                      key: '中文'
                                  })
                                }
                              }
                            ]
                          })}\n\ndata: [DONE]\n\n',
                      200,
                      headers: {
                        'content-type': 'text/event-stream; charset=utf-8'
                      });
                } catch (_) {
                  // 原样抛出合成夹具异常，生产 transport 仍只保留固定安全码。
                  rethrow;
                }
              }));
  setUpAll(() {
    root = Directory(Platform.environment['R3B4_ROOT']!);
    expect(root.path,
        '/tmp/chatai-r3b4-owned-${Platform.environment['R3B4_NONCE']}');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': Platform.environment['R3B4_NONCE']});
    sqfliteFfiInit();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'task.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'task.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
    db = await databaseFactoryFfi
        .openDatabase('${root.path}/case-${serial++}.sqlite');
    storage = HiDBManager.test(db);
    dao = await StoryTemplateTranslationTaskDao.create(storage,
        accountHash: 'account-a');
    templates = await StoryTemplateDao.create(storage);
    coordinator = StoryTemplateTranslationCoordinator();
    settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = pair('A')
      ..backendModel = 'same';
    gets = 0;
    factories = 0;
    empty = false;
    unique = false;
    posts.clear();
    held = null;
    postGate = postEntered = null;
  });
  tearDown(() async {
    await db.close();
    evidence.add({
      'case': serial,
      'closed': !db.isOpen,
      'posts': posts.length,
      'resolverGets': gets,
      'logout': tokens.clears
    });
    expect(tokens.clears, 0);
    coordinator.dispose();
    LoginSdkConfig.reset();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() {
    File('${root.path}/consumer-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'allSqliteClosed': evidence.every((x) => x['closed'] == true),
      'cases': evidence.length,
      'httpSynthetic': true
    }));
  });
  for (final code in ['A', 'B']) {
    test(
        'modern same model $code claims expected version and sends stored pair',
        () async => mocked(() async {
              await seed(profile(pair(code)));
              await initialize();
              await coordinator.resumeRecoverable(
                  checkEligibility: allow, resolveExecutor: executor);
              await settled();
              final t = (await dao.getTasks()).single;
              expect(t.status, StoryTemplateTranslationTaskStatus.completed,
                  reason: '${t.stage}/${t.error}/${t.log}');
              expect(t.attempts, 1);
              expect(posts, isNotEmpty);
              expect(
                  posts.every(
                      (p) => p['providerCode'] == code && p['model'] == 'same'),
                  true);
              expect(gets, 0);
              expect(factories, 1);
            }));
  }
  for (final kind in ['template', 'tavern']) {
    test(
        'new prepared $kind session is reused while global changes, factory not called',
        () async => mocked(() async {
              await initialize();
              final p = profile(pair('A'));
              var globalChanged = false;
              TranslationEligibilityResult initialCheck(
                  TranslationRequestProfile p) {
                if (globalChanged) {
                  throw StateError('must not reselect current global');
                }
                return allow(p);
              }

              final scope = TranslationSelectionScope(
                  accountHash: 'account-a',
                  currentAccount: () => tokens.account);
              final s = await TranslationSelectionSession.prepare(
                  scope: scope,
                  settings: settings,
                  preference: TranslationModelPreference(
                      mode: TranslationModelPreferenceMode.followGlobal,
                      reasoningPolicy: p.reasoningPolicy),
                  profile: p,
                  cancellation: TranslationCancellationController());
              postGate = Completer();
              postEntered = Completer();
              Future<void> start() async {
                try {
                  await Function.apply(
                      kind == 'template'
                          ? coordinator.start
                          : coordinator.startTavernRoomImport,
                      [
                        kind == 'template' ? template() : payload.results
                      ],
                      {
                        if (kind == 'tavern') #sourceTitle: 'fixture',
                        #requestProfile: s.profile,
                        #checkEligibility: initialCheck,
                        #resolveExecutor: (TranslationRequestProfile _) {
                          factories++;
                          throw StateError('must reuse');
                        },
                        #preparedSession: s
                      });
                } on NoSuchMethodError {
                  if (kind == 'tavern') {
                    await coordinator.startTavernRoomImport(payload.results,
                        sourceTitle: 'fixture',
                        requestProfile: s.profile,
                        checkEligibility: initialCheck, resolveExecutor: (p) {
                      factories++;
                      return s.executor;
                    });
                    return;
                  }
                  await coordinator.start(template(),
                      requestProfile: s.profile,
                      checkEligibility: initialCheck, resolveExecutor: (p) {
                    factories++;
                    return s.executor;
                  });
                }
              }

              await start();
              await wait(() => postEntered!.isCompleted);
              settings.backendSelection = pair('B');
              globalChanged = true;
              postGate!.complete();
              await settled();
              expect((await dao.getTasks()).single.status,
                  StoryTemplateTranslationTaskStatus.completed);
              expect(factories, 0);
              expect(posts.every((p) => p['providerCode'] == 'A'), true);
              expect(
                  jsonDecode((await dao.getTasks()).single.requestProfile)[
                      'backendSelection']['providerCode'],
                  'A');
              expect(gets, 0);
            }));
  }
  test(
      'new zero-attempt legacy binds original creation scope before claim',
      () async => mocked(() async {
            unique = true;
            await ModelCatalog.refreshFromBackend();
            await initialize();
            await coordinator.start(template(),
                requestProfile: profile(null),
                checkEligibility: allow,
                resolveExecutor: executor);
            await settled();
            final t = (await dao.getTasks()).single;
            expect(t.status, StoryTemplateTranslationTaskStatus.completed,
                reason: '${t.stage}/${t.error}/${t.log}');
            expect(t.attempts, 1);
            expect(
                jsonDecode(t.requestProfile)['backendSelection']
                    ['providerCode'],
                'A');
            expect(gets, 1);
            expect(posts.every((p) => p['providerCode'] == 'A'), true);
          }));
  test(
      'new legacy ambiguity preserves v1 and has zero attempt/model POST',
      () async => mocked(() async {
            await initialize();
            await coordinator.start(template(),
                requestProfile: profile(null),
                checkEligibility: allow,
                resolveExecutor: executor);
            await settled();
            final t = (await dao.getTasks()).single;
            expect(t.status,
                StoryTemplateTranslationTaskStatus.needsConfiguration);
            expect(t.attempts, 0);
            expect(jsonDecode(t.requestProfile)['version'], 1);
            expect(t.error, 'model_ambiguous');
            expect(
                jsonEncode(t.toJson()).contains('synthetic SQL secret'), false);
            expect(gets, 1);
            expect(posts, isEmpty);
          }));
  for (final switched in [false, true]) {
    test(
        'malformed modern array switched=$switched never claims or rewrites old identity',
        () async => mocked(() async {
              final t = await seed(profile(pair('A')));
              await db.update(dao.tableName,
                  {'requestProfile': '[{"version":2,"backendSelection":{}}]'},
                  where: 'id=?', whereArgs: [t.id]);
              await initialize();
              final before = await dao.backendBindingSnapshot(t.id!);
              if (switched) {
                tokens.account = 'account-b';
              }
              await coordinator.resumeRecoverable(
                  checkEligibility: allow, resolveExecutor: executor);
              final after = await dao.backendBindingSnapshot(t.id!);
              expect(after!['attempts'], 0);
              expect(after['requestProfile'], before!['requestProfile']);
              if (switched) {
                expect(after, before);
              } else {
                expect(after['status'],
                    StoryTemplateTranslationTaskStatus.needsConfiguration);
              }
              expect(gets, 0);
              expect(posts, isEmpty);
            }));
  }
  for (final attempts in [0, 2]) {
    test(
        'persisted legacy attempts=$attempts has no origin proof and is never rebound',
        () async => mocked(() async {
              final original = await seed(profile(null), attempts: attempts);
              await initialize();
              await coordinator.resumeRecoverable(
                  checkEligibility: allow, resolveExecutor: executor);
              final t = (await dao.getTasks()).single;
              expect(t.status,
                  StoryTemplateTranslationTaskStatus.needsConfiguration);
              expect(t.attempts, attempts);
              expect(t.requestProfile, original.requestProfile);
              expect(t.partialPayload, original.partialPayload);
              if (attempts > 0) {
                expect(t.error, 'unknown_send');
              }
              expect(gets, 0);
              expect(posts, isEmpty);
            }));
  }
  for (final bad in ['account', 'origin', 'disabled']) {
    test(
        'invalid stored modern $bad blocks before attempt',
        () async => mocked(() async {
              final p = profile(pair('A',
                  account: bad == 'account' ? 'account-b' : 'account-a',
                  origin: bad == 'origin'
                      ? 'https://other.synthetic.invalid'
                      : null));
              final original = await seed(p);
              await initialize();
              if (bad == 'disabled') {
                empty = true;
                await ModelCatalog.refreshFromBackend();
              }
              await coordinator.resumeRecoverable(
                  checkEligibility: allow, resolveExecutor: executor);
              final t = (await dao.getTasks()).single;
              expect(t.status,
                  StoryTemplateTranslationTaskStatus.needsConfiguration);
              expect(t.attempts, 0);
              expect(t.requestProfile, original.requestProfile);
              expect(posts, isEmpty);
              expect(gets, 0);
            }));
  }
  for (final change in [
    'account',
    'token',
    'epoch',
    'origin',
    'restore',
    'cancel'
  ]) {
    test(
        'last prepare await $change prevents claim and POST',
        () async => mocked(() async {
              await seed(profile(pair('A')));
              await initialize();
              final f = coordinator.resumeRecoverable(
                  checkEligibility: allow,
                  resolveExecutor: (p) => executor(p, hold: true));
              await wait(() => held?.entered.isCompleted == true);
              expect((await dao.getTasks()).single.attempts, 0);
              switch (change) {
                case 'account':
                  tokens.account = 'account-b';
                case 'token':
                  tokens.token = 'different-jwt';
                case 'epoch':
                  ModelCatalog.resetExecutionForTest();
                case 'origin':
                  BackendConfig.host = 'other.synthetic.invalid';
                case 'restore':
                  BackupService.agentExecutionRevision++;
                case 'cancel':
                  await coordinator.cancel(coordinator.tasks.single);
              }
              held!.release.complete();
              await f;
              expect((await dao.getTasks()).single.attempts, 0);
              expect(posts, isEmpty);
              expect(gets, 0);
            }));
  }
  test(
      'stale expected version after preparation does not claim newer profile',
      () async => mocked(() async {
            final original = await seed(profile(pair('A')));
            await initialize();
            final f = coordinator.resumeRecoverable(
                checkEligibility: allow,
                resolveExecutor: (p) => executor(p, hold: true));
            await wait(() => held?.entered.isCompleted == true);
            await db.update(
                dao.tableName,
                {
                  'updatedAt': original.updatedAt + 1,
                  'requestProfile': jsonEncode(profile(pair('B')).toJson())
                },
                where: 'id=?',
                whereArgs: [original.id]);
            held!.release.complete();
            await f;
            final t = (await dao.getTasks()).single;
            expect(t.attempts, 0);
            expect(
                jsonDecode(t.requestProfile)['backendSelection']
                    ['providerCode'],
                'B');
            expect(posts, isEmpty);
          }));
  test(
      'mismatched prepared transport refuses original task before attempt',
      () async => mocked(() async {
            await seed(profile(pair('A')));
            await initialize();
            await coordinator.resumeRecoverable(
                checkEligibility: allow,
                resolveExecutor: (p) => executor(p, wrong: pair('B')));
            expect((await dao.getTasks()).single.attempts, 0);
            expect((await dao.getTasks()).single.status,
                StoryTemplateTranslationTaskStatus.needsConfiguration);
            expect(posts, isEmpty);
          }));
  test(
      'continue provable modern task ignores current global B',
      () async => mocked(() async {
            await seed(profile(pair('A')),
                attempts: 1, status: StoryTemplateTranslationTaskStatus.failed);
            await initialize();
            settings.backendSelection = pair('B');
            await coordinator.retry(coordinator.tasks.single,
                checkEligibility: allow, resolveExecutor: executor);
            await settled();
            expect(posts, isNotEmpty);
            expect(posts.every((p) => p['providerCode'] == 'A'), true);
            expect((await dao.getTasks()).single.attempts, 2);
            expect(gets, 0);
          }));
  test(
      'replacement of backend history is rejected without writing it',
      () async => mocked(() async {
            final original = await seed(profile(pair('A')),
                attempts: 1, status: StoryTemplateTranslationTaskStatus.failed);
            await initialize();
            final before = await dao.backendBindingSnapshot(original.id!);
            await expectLater(
                coordinator.retry(coordinator.tasks.single,
                    replacementProfile: profile(pair('B')),
                    checkEligibility: allow,
                    resolveExecutor: executor),
                throwsA(isA<TranslationModelUnavailableException>()));
            expect(await dao.backendBindingSnapshot(original.id!), before);
            expect(posts, isEmpty);
          }));
  for (final kind in ['template', 'tavern']) {
    test(
        'completion last-await $kind callback rolls back actual SQLite output',
        () async => mocked(() async {
              final t = await seed(profile(pair('A')));
              if (kind == 'tavern') {
                await db.update(
                    dao.tableName,
                    {
                      'taskKind':
                          StoryTemplateTranslationTaskKind.tavernRoomImport
                    },
                    where: 'id=?',
                    whereArgs: [t.id]);
              }
              await dao.claimTask(t.id!,
                  leaseOwner: 'fixture',
                  leaseDuration: const Duration(minutes: 1),
                  expectedUpdatedAt: t.updatedAt);
              final claimed = (await dao.getTask(t.id!))!;
              var calls = 0;
              void verify() {
                calls++;
                if (calls == 2) throw StateError('synthetic restore change');
              }

              Future<Object?> complete() async {
                try {
                  if (kind == 'tavern') {
                    final bundle = TavernRoomImportFinalizer.build(
                        payload: payload,
                        title: 'fixture',
                        sourceTitle: 'fixture',
                        translated: true,
                        hasRetainedOriginal: false);
                    try {
                      return await Function.apply(dao.completeWithTavernRoom, [
                        claimed
                      ], {
                        #bundle: bundle,
                        #leaseOwner: 'fixture',
                        #verifyCompletion: verify
                      });
                    } on NoSuchMethodError {
                      return dao.completeWithTavernRoom(claimed,
                          bundle: bundle, leaseOwner: 'fixture');
                    }
                  }
                  return await Function.apply(dao.completeWithTemplate, [
                    claimed
                  ], {
                    #outputTemplate: template(),
                    #leaseOwner: 'fixture',
                    #verifyCompletion: verify
                  });
                } on NoSuchMethodError {
                  return dao.completeWithTemplate(claimed,
                      outputTemplate: template(), leaseOwner: 'fixture');
                }
              }

              await expectLater(complete(), throwsStateError);
              expect((await dao.getTasks()).single.status,
                  StoryTemplateTranslationTaskStatus.running);
              expect(await templates.getTemplates(), isEmpty);
              expect(posts, isEmpty);
            }));
  }
}
