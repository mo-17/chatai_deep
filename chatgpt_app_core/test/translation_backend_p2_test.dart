import 'support/owned_test_directory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 已安装的传递平台接口仅用于合成持久化等待，不改生产依赖。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'backend_pair_transport_test.dart' show PairTokens;
import 'support/fake_translation_chat_service.dart';

Future<Object?> errorOf(Future<Object?> f) async {
  try {
    await f;
    return null;
  } catch (e) {
    return e;
  }
}

// 实际 BackendChatService 承担原身份/pair验证；仅替换模型流为受控合成 stream。
class _PreparedSynthetic
    implements
        ChatService,
        BackendSelectionPreparingChatService,
        OptionsAwareChatService {
  final BackendChatService guard;
  final FakeTranslationChatService stream;
  final void Function()? onTerminalAbort;
  _PreparedSynthetic(AISettings settings, this.stream, {this.onTerminalAbort})
      : guard = BackendChatService(settings);
  @override
  Future<BackendSelection> prepareBackendSelection(
          {Future<void>? abortTrigger}) =>
      guard.prepareBackendSelection(abortTrigger: abortTrigger);
  @override
  void verifyPreparedBackendSelection(BackendSelection pair) =>
      guard.verifyPreparedBackendSelection(pair);
  @override
  ModelCapabilities get capabilities => guard.capabilities;
  @override
  Future<String?> chat(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          Duration? timeout}) =>
      throw UnsupportedError('synthetic typed stream only');
  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      throw UnsupportedError('synthetic typed stream only');
  @override
  Stream<String> chatStream(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      throw UnsupportedError('synthetic typed stream only');
  @override
  Stream<StreamEvent> chatStreamEvents(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const []}) =>
      throw UnsupportedError('options required');
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) {
    final result = stream.chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: options);
    // finish() 的 abort 已触发，身份变更发生在它末次 await 恢复之前。
    options.abortTrigger?.then<void>((_) => onTerminalAbort?.call());
    return result;
  }
}

// 注入 preference 平台持久化边界；生产 cache 的真正 per-key 队列/乐观值/回滚照常执行。
class _GatePreferences extends SharedPreferencesStorePlatform {
  final Map<String, Object> values = {};
  final List<String> sets = [];
  Completer<void>? started, release;
  String? heldKey;
  void hold(String key) {
    heldKey = 'flutter.$key';
    started = Completer();
    release = Completer();
  }

  void open() {
    if (release?.isCompleted == false) release!.complete();
  }

  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    sets.add(key);
    if (key == heldKey) {
      heldKey = null;
      started!.complete();
      await release!.future;
    }
    values[key] = value;
    return true;
  }
}

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B4_ROOT',
    nonceKey: 'R3B4_NONCE',
    legacyPrefix: '/tmp/chatai-r3b4-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _GatePreferences store;
  late PairTokens tokens;
  late String oldHost;
  late bool oldHttps;
  final streams = <FakeTranslationChatService>[];
  final evidence = <Map<String, Object?>>[];
  final now = DateTime.utc(2026, 10, 18, 12);
  BackendSelection pair() => BackendSelection.pair(
      providerCode: 'A',
      modelId: 'same',
      accountHash: 'account-a',
      origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
  TranslationRequestProfile profile() => TranslationRequestProfile(
      mode: TranslationExecutionMode.backend,
      modelId: 'same',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      reasoningControlSuppressed: false,
      backendSelection: pair());
  AISettings settings() => AISettings.defaults()
    ..mode = AIMode.backend
    ..backendModel = 'same'
    ..backendSelection = pair();
  void change(String type) {
    switch (type) {
      case 'account':
        tokens.account = 'account-b';
      case 'origin':
        BackendConfig.host = 'synthetic.invalid:18485';
      case 'epoch':
        ModelCatalog.resetExecutionForTest();
      case 'restoreTick':
        BackupService.restoreTick.value++;
      case 'restoreRevision':
        BackupService.agentExecutionRevision++;
    }
  }

  FakeTranslationChatService fake(
      {Future<void> Function()? cleanup, bool fail = false}) {
    final f = FakeTranslationChatService([
      (r) {
        if (fail) {
          r.errorNow(const ChatTransportException(
              safeCode: 'model_unavailable',
              safeMessage: '所选模型不可用',
              statusCode: 409));
        } else {
          r.addNow(StreamEvent.text('{"translation":"早上好"}'));
        }
        r.closeNow();
      }
    ], cancelCleanup: cleanup);
    streams.add(f);
    return f;
  }

  TranslationStreamExecutor executor(
          FakeTranslationChatService f, TranslationRequestProfile p,
          {void Function()? onTerminalAbort}) =>
      TranslationStreamExecutor(
          service: _PreparedSynthetic(settings(), f,
              onTerminalAbort: onTerminalAbort),
          profile: p);
  TranslationModelProbeService probe(
          FakeTranslationChatService f, TranslationModelProbeCache cache) =>
      TranslationModelProbeService(
          cache: cache,
          now: () => now,
          executorFactory: (
                  {required settings,
                  required profile,
                  required onProfileChanged}) =>
              TranslationStreamExecutor(
                  service: _PreparedSynthetic(settings, f),
                  profile: profile,
                  onProfileChanged: onProfileChanged));
  TranslationModelProbeRecord sentinel() => TranslationModelProbeRecord(
      fingerprint: 'e' * 64,
      status: TranslationModelProbeStatus.verified,
      checkedAt: now,
      reasoningControlSuppressed: false);
  setUpAll(() {
    root = ownedFixture.directory;
  });
  setUp(() async {
    streams.clear();
    SharedPreferences.setMockInitialValues({});
    store = _GatePreferences();
    SharedPreferencesStorePlatform.instance = store;
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'synthetic.invalid:18484';
    BackendConfig.useHttps = false;
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'http://${BackendConfig.host}',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    ModelCatalog.resetExecutionForTest();
  });
  tearDown(() async {
    store.open();
    await Future<void>.delayed(Duration.zero);
    expect(streams.every((s) => s.activeSubscriptions == 0), isTrue);
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    ModelCatalog.resetExecutionForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  tearDownAll(() {
    File('${root.path}/p2-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'allSyntheticStreamsClosed': true,
      'modelHTTP': 0,
      'servers': 0,
      'sqlite': 0,
      'injectedPreferenceStoreOnly': true
    }));
  });
  for (final type in [
    'account',
    'origin',
    'epoch',
    'restoreTick',
    'restoreRevision'
  ]) {
    test(
        'successful public return rejects $type loss during finish final microtask yield',
        () async {
      var duringLastYield = false;
      final f = fake();
      final e = executor(f, profile(), onTerminalAbort: () {
        duringLastYield = true;
        change(type);
      });
      final c = TranslationCancellationController();
      await e.prepare(cancellation: c);
      final error = await errorOf(e.complete('x', cancellation: c));
      evidence.add({
        'path': 'finish-final-yield',
        'change': type,
        'duringLastYield': duringLastYield,
        'oldSuccess': error == null,
        'calls': f.requestAttempts
      });
      expect(duringLastYield, isTrue);
      expect(
          error,
          isA<TranslationRequestFailure>()
              .having((e) => e.safeCode, 'code', 'backend_scope_changed'));
      expect(f.requestAttempts, 1);
      expect(tokens.clears, 0);
    });
  }
  for (final type in ['origin', 'epoch', 'restoreTick', 'restoreRevision']) {
    test(
        'cached prepare $type failure remains finite typed rather than raw transport',
        () async {
      final f = fake();
      final e = executor(f, profile());
      final c = TranslationCancellationController();
      await e.prepare(cancellation: c);
      change(type);
      final error = await errorOf(e.prepare(cancellation: c));
      evidence.add({
        'path': 'cached-prepare',
        'change': type,
        'errorType': error.runtimeType.toString(),
        'calls': f.requestAttempts
      });
      expect(
          error,
          isA<TranslationRequestFailure>()
              .having((e) => e.safeCode, 'code', 'backend_scope_changed'));
      expect(f.requestAttempts, 0);
      expect(tokens.clears, 0);
    });
  }
  test(
      'already determined configuration failure is not replaced by final identity loss',
      () async {
    final f = fake(fail: true);
    final e = executor(f, profile(), onTerminalAbort: () => change('origin'));
    final c = TranslationCancellationController();
    await e.prepare(cancellation: c);
    final error = await errorOf(e.complete('x', cancellation: c));
    expect(
        error,
        isA<TranslationRequestFailure>()
            .having((e) => e.safeCode, 'code', 'model_unavailable'));
    expect(f.requestAttempts, 1);
  });
  test('unchanged identity success remains successful exactly once', () async {
    final f = fake();
    final e = executor(f, profile());
    final c = TranslationCancellationController();
    await e.prepare(cancellation: c);
    expect(await e.complete('x', cancellation: c), contains('早上好'));
    expect(f.requestAttempts, 1);
  });
  for (final type in ['origin', 'epoch', 'restoreTick', 'restoreRevision']) {
    test(
        'actual cache queue $type loss skips stale put before execution and result delivery',
        () async {
      final cache = TranslationModelProbeCache(now: () => now);
      final key = TranslationModelProbeCache.keyFor('account-a');
      store.hold(key);
      final block = cache.put(sentinel(),
          expectedAccountHash: 'account-a',
          providerId: null,
          expectedToken:
              cache.tokenFor(accountHash: 'account-a', providerId: null));
      await store.started!.future.timeout(const Duration(seconds: 2));
      final expectedRaw = HiCache.getInstance().prefs!.getString(key);
      final f = fake();
      final service = probe(f, cache);
      final p = profile();
      final s = settings();
      final identity =
          service.identify(accountHash: 'account-a', settings: s, profile: p);
      final handle = service.start(
          accountHash: 'account-a',
          settings: s,
          profile: p,
          isConfigurationCurrent: () => true);
      final result = errorOf(handle.result);
      // 真正尾队列被上述 put/native await 占用；event turn 排空网络终态 microtasks。
      await Future<void>.delayed(Duration.zero);
      expect(f.requestAttempts, 1);
      expect(f.activeSubscriptions, 0);
      change(type);
      store.open();
      await block;
      final error = await result.timeout(const Duration(seconds: 2));
      final raw = HiCache.getInstance().prefs!.getString(key);
      evidence.add({
        'path': 'actual-cache-queue',
        'change': type,
        'staleDelivered': error == null,
        'bytePreserved': raw == expectedRaw,
        'nativeSets': store.sets.length,
        'staleRecord': cache.lookup(
                accountHash: 'account-a', fingerprint: identity.fingerprint) !=
            null
      });
      expect(
          error,
          isA<TranslationRequestFailure>()
              .having((e) => e.safeCode, 'code', 'backend_scope_changed'));
      expect(raw, expectedRaw);
      expect(store.values['flutter.$key'], expectedRaw);
      expect(store.sets.length, 1);
      expect(
          cache.lookup(
              accountHash: 'account-a', fingerprint: identity.fingerprint),
          isNull);
    });
    test(
        'actual setString $type loss rolls back bytes and rejects stale delivered result',
        () async {
      final cache = TranslationModelProbeCache(now: () => now);
      final key = TranslationModelProbeCache.keyFor('account-a');
      await cache.put(sentinel(),
          expectedAccountHash: 'account-a',
          providerId: null,
          expectedToken:
              cache.tokenFor(accountHash: 'account-a', providerId: null));
      final expectedRaw = HiCache.getInstance().prefs!.getString(key);
      store.sets.clear();
      store.hold(key);
      final f = fake();
      final service = probe(f, cache);
      final p = profile();
      final s = settings();
      final identity =
          service.identify(accountHash: 'account-a', settings: s, profile: p);
      final handle = service.start(
          accountHash: 'account-a',
          settings: s,
          profile: p,
          isConfigurationCurrent: () => true);
      final result = errorOf(handle.result);
      await store.started!.future.timeout(const Duration(seconds: 2));
      change(type);
      handle.cancel();
      store.open();
      final error = await result.timeout(const Duration(seconds: 2));
      final raw = HiCache.getInstance().prefs!.getString(key);
      evidence.add({
        'path': 'actual-platform-persistence',
        'change': type,
        'staleDelivered': error == null,
        'byteRestored': raw == expectedRaw,
        'nativeSets': store.sets.length,
        'staleRecord': cache.lookup(
                accountHash: 'account-a', fingerprint: identity.fingerprint) !=
            null
      });
      expect(
          error,
          isA<TranslationRequestFailure>()
              .having((e) => e.safeCode, 'code', 'backend_scope_changed'));
      expect(raw, expectedRaw);
      expect(store.values['flutter.$key'], expectedRaw);
      expect(store.sets.length, 2);
      expect(
          cache.lookup(
              accountHash: 'account-a', fingerprint: identity.fingerprint),
          isNull);
    });
  }
  test(
      'per-subscriber guard rejects expired caller while valid subscriber retains same result/cache',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final key = TranslationModelProbeCache.keyFor('account-a');
    store.hold(key);
    final f = fake();
    final service = probe(f, cache);
    final p = profile();
    final s = settings();
    var firstCurrent = true;
    final first = service.start(
        accountHash: 'account-a',
        settings: s,
        profile: p,
        isConfigurationCurrent: () => firstCurrent);
    final firstResult = errorOf(first.result);
    final second = service.start(
        accountHash: 'account-a',
        settings: s,
        profile: p,
        isConfigurationCurrent: () => true);
    await store.started!.future.timeout(const Duration(seconds: 2));
    firstCurrent = false;
    store.open();
    final a = await firstResult;
    final b = await second.result;
    evidence.add({
      'path': 'per-subscriber-delivery',
      'expiredDelivered': a == null,
      'calls': f.requestAttempts
    });
    expect(
        a,
        isA<TranslationRequestFailure>()
            .having((e) => e.kind, 'kind', TranslationFailureKind.cancelled));
    expect(b.record.status, TranslationModelProbeStatus.verified);
    expect(f.requestAttempts, 1);
  });
  test(
      'terminal ordinary cancel remains ignored when original identity is current',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final key = TranslationModelProbeCache.keyFor('account-a');
    store.hold(key);
    final f = fake();
    final service = probe(f, cache);
    final p = profile();
    final s = settings();
    final handle = service.start(
        accountHash: 'account-a',
        settings: s,
        profile: p,
        isConfigurationCurrent: () => true);
    await store.started!.future.timeout(const Duration(seconds: 2));
    handle.cancel();
    store.open();
    expect((await handle.result).record.status,
        TranslationModelProbeStatus.verified);
    expect(f.requestAttempts, 1);
  });
}
