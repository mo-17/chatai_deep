import 'support/owned_test_directory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/direct_failure_recovery.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

class _OwnedLoopbackHTTP extends HttpOverrides {}

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B4_ROOT',
    nonceKey: 'R3B4_NONCE',
    legacyPrefix: '/tmp/chatai-r3b4-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database db;
  late StoryTemplateTranslationTaskDao dao;
  late StoryTemplateTranslationCoordinator coordinator;
  late AISettings settings;
  late PairTokens tokens;
  late HttpServer server;
  late Completer<void> accepted;
  HttpOverrides? previousHttp;
  int serial = 0;
  final posts = <String>[], evidence = <Map<String, Object?>>[];
  final payload = StoryRoomTemplatePayload(results: [
    AssistantRoleCardImportResult(
        assistant: AssistantModel(name: 'English', prompt: 'English prompt'))
  ]);
  TranslationRequestProfile profile(String p) => TranslationRequestProfile(
      mode: TranslationExecutionMode.local,
      providerId: p,
      modelId: 'plain',
      reasoningPolicy: ChatReasoningPolicy.providerDefault,
      reasoningControlSuppressed: false);
  TranslationEligibilityResult allow(TranslationRequestProfile p) =>
      const TranslationEligibilityResult();
  TranslationStreamExecutor executor(TranslationRequestProfile p) {
    final selected = settings.clone()
      ..mode = AIMode.local
      ..activeProviderId = p.providerId!;
    selected.setLocalModelOverride(p.modelId);
    return TranslationStreamExecutor(
        service: ChatService.from(selected),
        profile: p,
        // 冷启动和真实 HTTP 握手不能占用用来验证已受理请求的闲置期限。
        firstEventTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(milliseconds: 40),
        totalTimeout: const Duration(seconds: 10));
  }

  Future<void> wait(bool Function() done) async {
    for (var i = 0; i < 1000 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), true, reason: 'bounded coordinator settlement');
  }

  Future<StoryTemplateTranslationTaskModel> seed() async {
    final old = StoryTemplateTranslationTaskModel(
        sourceTitle: 'old',
        sourcePayload: jsonEncode(payload.toJson()),
        outputTitle: 'old copy',
        requestProfile: jsonEncode(profile('A').toJson()),
        status: StoryTemplateTranslationTaskStatus.retryable,
        attempts: 1,
        partialPayload: '{"kept":"old partial"}',
        error: 'timeout');
    await dao.saveTask(old);
    await coordinator.initialize(HiDBManager.test(db),
        accountHash: 'account-a');
    return coordinator.tasks.single;
  }

  DirectRetryPermit permit(String p) {
    final scope = ConversationGenerationScope(account: 'account-a');
    final r = DirectFailureRecovery(
        original: settings,
        scope: scope,
        currentSettings: () => settings,
        sourceCurrent: () => true,
        requiredInput: const ModelCapabilities.none(),
        mayHaveBeenProcessed: true,
        failureCode: 'timeout');
    final permit = r.confirm(DirectFailureRecovery.key(p, 'plain'))!;
    expect(permit.claim(), isNotNull);
    return permit;
  }

  setUpAll(() {
    root = ownedFixture.directory;
    sqfliteFfiInit();
  });
  setUp(() async {
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = _OwnedLoopbackHTTP();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    LoginDao.resetHooksForTest();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'translation.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    db = await databaseFactoryFfi
        .openDatabase('${root.path}/case-${serial++}.sqlite');
    final storage = HiDBManager.test(db);
    dao = await StoryTemplateTranslationTaskDao.create(storage,
        accountHash: 'account-a');
    await StoryTemplateDao.create(storage);
    coordinator = StoryTemplateTranslationCoordinator();
    posts.clear();
    accepted = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      expect(r.method, 'POST');
      if (r.uri.path.contains('/A/')) {
        // 明确覆盖慢于旧 40ms 窗口的握手，随后才验证部分响应后的闲置超时。
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await r.drain<void>();
      posts.add(r.uri.path);
      if (!accepted.isCompleted) accepted.complete();
      if (r.uri.path.contains('/A/')) {
        r.response.bufferOutput = false;
        r.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        r.response.writeln('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '{"partial":'}
                }
              ]
            })}');
        r.response.writeln();
        await r.response.flush();
        return;
      }
      r.response.statusCode = 503;
      r.response.write('{"error":{"message":"synthetic secret"}}');
      await r.response.close();
    });
    settings = AISettings.defaults()
      ..mode = AIMode.local
      ..activeProviderId = 'A'
      ..providers = [
        for (final p in ['A', 'B'])
          AiProvider(
              id: p,
              name: p,
              type: 'openai',
              enabled: true,
              apiKey: 'synthetic-$p',
              apiHost: 'http://127.0.0.1:${server.port}/$p/v1',
              models: [AiModel(id: 'plain')],
              selectedModelId: 'plain')
      ];
  });
  tearDown(() async {
    await coordinator.detachForLifecycle();
    coordinator.dispose();
    await server.close(force: true);
    await db.close();
    HttpOverrides.global = previousHttp;
    evidence.add({
      'posts': posts.length,
      'sqliteClosed': !db.isOpen,
      'serverClosed': true,
      'logout': tokens.clears
    });
    expect(tokens.clears, 0);
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
  });
  tearDownAll(() => File('${root.path}/cleanup.json')
      .writeAsStringSync(jsonEncode({'cases': evidence, 'allClosed': true})));
  test(
      'new local task accepted timeout pauses with one POST; plain resume and scheduler cannot retry',
      () async {
    await coordinator.initialize(HiDBManager.test(db),
        accountHash: 'account-a');
    await coordinator.start(
        payload.toTemplate(title: 'new', sourceTitle: 'fixture'),
        requestProfile: profile('A'),
        checkEligibility: allow,
        resolveExecutor: executor);
    await accepted.future.timeout(const Duration(seconds: 10));
    await wait(() =>
        coordinator.tasks.isNotEmpty &&
        coordinator.tasks.single.status ==
            StoryTemplateTranslationTaskStatus.failed);
    expect(posts.length, 1);
    expect(coordinator.tasks.single.error, 'idle_timeout');
    final before = (await dao.getTasks()).single.toJson();
    await coordinator.resumeRecoverable(
        checkEligibility: allow, resolveExecutor: executor);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(posts.length, 1);
    expect((await dao.getTasks()).single.toJson(), before);
  });
  test(
      'attempted local retry without confirmation changes no row and sends nothing',
      () async {
    final old = await seed(), before = (await dao.getTasks()).single.toJson();
    await expectLater(
        coordinator.retry(old,
            checkEligibility: allow, resolveExecutor: executor),
        throwsA(isA<StateError>()));
    expect((await dao.getTasks()).single.toJson(), before);
    expect(posts, isEmpty);
  });
  test(
      'explicit B creates independent task and retains original partial/profile/attempt',
      () async {
    final old = await seed(), before = (await dao.getTask(old.id!))!.toJson();
    await coordinator.startConfirmedDirectCopy(old,
        requestProfile: profile('B'),
        directPermit: permit('B'),
        checkEligibility: allow,
        resolveExecutor: executor);
    await wait(() =>
        posts.isNotEmpty &&
        coordinator.tasks.first.status ==
            StoryTemplateTranslationTaskStatus.failed);
    final rows = await dao.getTasks();
    expect(rows.length, 2);
    expect((await dao.getTask(old.id!))!.toJson(), before);
    expect(rows.first.id, isNot(old.id));
    expect(rows.first.attempts, 1);
    expect(posts.length, 1);
    expect(posts.single, contains('/B/'));
    expect(settings.activeProviderId, 'A');
  });
  for (final change in ['configuration', 'source']) {
    test('late $change after confirmation writes no copy and sends nothing',
        () async {
      final old = await seed();
      final allowed = permit('B');
      if (change == 'configuration') {
        settings.providers.first.enabled = false;
      } else {
        final changed = StoryTemplateTranslationTaskModel.fromJson(old.toJson())
          ..sourcePayload = 'changed';
        await dao.saveTask(changed);
      }
      await expectLater(
          coordinator.startConfirmedDirectCopy(old,
              requestProfile: profile('B'),
              directPermit: allowed,
              checkEligibility: allow,
              resolveExecutor: executor),
          throwsA(anything));
      expect((await dao.getTasks()).length, 1);
      expect(posts, isEmpty);
    });
  }
  test(
      'committed confirmed copy cannot recover after permit loss and coordinator reconstruction',
      () async {
    final old = await seed();
    final original = (await dao.getTask(old.id!))!.toJson();
    void revokeAfterCommit() {
      if (coordinator.tasks.length == 2) {
        settings.providers.first.enabled = false;
      }
    }

    coordinator.addListener(revokeAfterCommit);
    await coordinator.startConfirmedDirectCopy(old,
        requestProfile: profile('B'),
        directPermit: permit('B'),
        checkEligibility: allow,
        resolveExecutor: executor);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final copy = (await dao.getTasks()).first;
    expect(copy.id, isNot(old.id));
    expect(copy.attempts, 0);
    expect(copy.leaseOwner, isNull);
    expect(posts, isEmpty);
    // 显示文案与确认许可无关，模拟其它展示更新。
    await db.update(dao.tableName, {'stage': '任意展示文字'},
        where: 'id=?', whereArgs: [copy.id]);
    final before = (await dao.getTask(copy.id!))!.toJson();
    await coordinator.detachForLifecycle();
    coordinator.dispose();
    settings.providers.first.enabled = true;
    coordinator = StoryTemplateTranslationCoordinator();
    await coordinator.initialize(HiDBManager.test(db),
        accountHash: 'account-a');
    final resumed = await coordinator.resumeRecoverable(
        checkEligibility: allow, resolveExecutor: executor);
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(resumed, 0);
    expect(posts, isEmpty);
    expect((await dao.getTask(copy.id!))!.toJson(), before);
    expect((await dao.getTask(old.id!))!.toJson(), original);
    final claimed = await dao.claimTask(copy.id!,
        leaseOwner: 'without-permit',
        leaseDuration: const Duration(seconds: 5));
    expect(claimed, false);
    expect((await dao.getTask(copy.id!))!.toJson(), before);
    // 原确认不可恢复，但同页新的明确确认可以领取一次，仍保留旧输出。
    await coordinator.retry(coordinator.tasks.first,
        directPermit: permit('B'),
        checkEligibility: allow,
        resolveExecutor: executor);
    await wait(() =>
        posts.length == 1 &&
        coordinator.tasks.first.status ==
            StoryTemplateTranslationTaskStatus.failed);
    expect((await dao.getTask(copy.id!))!.attempts, 1);
    expect((await dao.getTask(copy.id!))!.requestProfile, copy.requestProfile);
    expect((await dao.getTask(old.id!))!.toJson(), original);
  });
}
