import 'support/owned_test_directory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_fingerprint.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

Future<Object?> failureOf(Future<Object?> f) async {
  try {
    await f;
    return null;
  } catch (e) {
    return e;
  }
}

// 最终同字节 fixture 可在旧实现运行；缺新增接点明确返回 null，不伪造旧成功。
Future<TranslationRequestProfile?> prepareOf(
    TranslationStreamExecutor e, TranslationCancellationController c) async {
  try {
    return await (e as dynamic).prepare(cancellation: c)
        as TranslationRequestProfile;
  } on NoSuchMethodError {
    return null;
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
  late HttpServer server;
  late HttpOverrides? overrides;
  late PairTokens tokens;
  late String oldHost;
  late bool oldHttps;
  int opens = 0, closed = 0, probes = 0, catalogGets = 0;
  final posts = <Map<String, dynamic>>[];
  final evidence = <Map<String, Object?>>[];
  String resolved = 'A', responseCode = 'model_unavailable';
  int probeStatus = 200, failureStatus = 409;
  String wire = 'ok';
  Completer<void>? entered, gate;
  final gates = <Completer<void>>[];
  BackendSelection pair(String p,
          {String model = 'same',
          String account = 'account-a',
          String? origin}) =>
      BackendSelection.pair(
          providerCode: p,
          modelId: model,
          accountHash: account,
          origin: origin ??
              BackendConfig.buildUri('/uapi/chat/completions').origin);
  TranslationModelPreference pref(String p) => TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'same',
      backendSelection: pair(p),
      reasoningPolicy: ChatReasoningPolicy.offIfSupported);
  TranslationRequestProfile profile(BackendSelection? p) =>
      TranslationRequestProfile(
          mode: TranslationExecutionMode.backend,
          modelId: 'same',
          backendSelection: p,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported,
          reasoningControlSuppressed: false);
  TranslationStreamExecutor executor(AISettings s, TranslationRequestProfile p,
          {Duration first = const Duration(seconds: 2)}) =>
      TranslationStreamExecutor(
          service: BackendChatService(TranslationModelResolver.apply(s, p)),
          profile: p,
          firstEventTimeout: first,
          idleTimeout: const Duration(seconds: 2),
          totalTimeout: const Duration(seconds: 3));
  setUpAll(() async {
    root = ownedFixture.directory;
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  setUp(() async {
    probes = 0;
    catalogGets = 0;
    posts.clear();
    resolved = 'A';
    wire = 'ok';
    probeStatus = 200;
    failureStatus = 409;
    responseCode = 'model_unavailable';
    entered = null;
    gate = null;
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    opens++;
    server.listen((r) async {
      expect(r.headers.value(HttpHeaders.authorizationHeader),
          'Bearer synthetic-jwt');
      if (r.uri.path == '/uapi/ai/catalog') {
        catalogGets++;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode({
          'code': 0,
          'data': {'models': []}
        }));
      } else if (r.uri.path == '/uapi/ai/model-selection') {
        probes++;
        entered?.complete();
        if (gate != null) await gate!.future;
        r.response.statusCode = probeStatus;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(probeStatus == 200
            ? {
                'code': 0,
                'data': {
                  'providerCode': resolved,
                  'modelId': r.uri.queryParameters['modelId']
                }
              }
            : {
                'code': probeStatus,
                'safeCode': responseCode,
                'message': 'synthetic-secret SQL token'
              }));
      } else {
        expect(r.uri.path, '/uapi/chat/completions/stream');
        expect(r.method, 'POST');
        posts.add(jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, dynamic>);
        entered?.complete();
        if (gate != null) await gate!.future;
        if (wire == 'http') {
          r.response.statusCode = failureStatus;
          r.response.headers.contentType = ContentType.json;
          r.response.write(jsonEncode({
            'safeCode': responseCode,
            'message': 'synthetic-secret SQL token'
          }));
        } else {
          r.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          if (wire == 'sse') {
            r.response.write('event: error\ndata: ${jsonEncode({
                  'safeCode': responseCode,
                  'statusCode': failureStatus,
                  'message': 'synthetic-secret SQL token'
                })}\n\n');
          } else {
            r.response.write('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': '{"translation":"你好"}'}
                    }
                  ]
                })}\n\ndata: [DONE]\n\n');
          }
        }
      }
      try {
        await r.response.close();
      } catch (_) {/* cancelled synthetic socket */}
    });
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = '127.0.0.1:${server.port}';
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
    for (final g in gates) {
      if (!g.isCompleted) g.complete();
    }
    gates.clear();
    await server.close(force: true);
    closed++;
    evidence.add({
      'probes': probes,
      'posts': posts.map((p) => [p['providerCode'], p['model']]).toList(),
      'catalogGets': catalogGets,
      'logout': tokens.clears
    });
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
    ModelCatalog.resetExecutionForTest();
    HttpOverrides.global = overrides;
  });
  tearDownAll(() {
    File('${root.path}/foundation-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'serversOpened': opens,
      'serversClosed': closed,
      'allClosed': opens == closed,
      'sqlite': 0
    }));
  });
  test(
      'modern explicit pair and follow snapshot/apply preserve raw IDs and JSON v2',
      () {
    final s = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendModel = 'old';
    final a = TranslationModelResolver.snapshot(s, pref(' A/原文 '));
    expect(a.backendSelection?.providerCode, ' A/原文 ');
    expect(a.version, 2);
    expect(a.modelId, 'same');
    final restored = TranslationRequestProfile.fromJson(
        jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
    s.backendSelection = pair('B');
    expect(
        TranslationModelResolver.legacyFallbackOrNull(
            s,
            const TranslationModelPreference(
                mode: TranslationModelPreferenceMode.followGlobal,
                reasoningPolicy: ChatReasoningPolicy.offIfSupported)),
        isNull);
    final applied = TranslationModelResolver.apply(s, restored);
    expect(applied.backendSelection?.pairKey, a.backendSelection?.pairKey);
    final follow = TranslationModelResolver.snapshot(
        s,
        const TranslationModelPreference(
            mode: TranslationModelPreferenceMode.followGlobal,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported));
    expect(follow.backendSelection?.providerCode, 'B');
    expect(posts, isEmpty);
  });
  test('foreign explicit scope fails without fallback, raw selection unchanged',
      () {
    final original = pair('A', account: 'other');
    final s = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendModel = 'same'
      ..backendSelection = original;
    expect(() => TranslationModelResolver.apply(s, profile(original)),
        throwsA(isA<TranslationModelUnavailableException>()));
    expect(s.backendSelection?.pairKey, original.pairKey);
    expect(probes, 0);
    expect(posts, isEmpty);
  });
  test(
      'pair fingerprints isolate provider and origin and legacy remains legacy',
      () {
    final s = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendModel = 'same';
    final a = TranslationModelProbeFingerprint.build(
        settings: s, profile: profile(pair('A')));
    final b = TranslationModelProbeFingerprint.build(
        settings: s, profile: profile(pair('B')));
    expect(a, isNot(b));
    final legacy = TranslationModelProbeFingerprint.build(
        settings: s, profile: profile(null));
    expect(a, isNot(legacy));
  });
  test(
      'legacy prepare once fixed v2 then multiple chunks use same pair after global switch',
      () async {
    final s = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendModel = 'same';
    final e = executor(s, profile(null));
    final c = TranslationCancellationController();
    final fixed = await prepareOf(e, c);
    expect(fixed?.backendSelection?.providerCode, 'A');
    expect(fixed?.version, 2);
    s.backendSelection = pair('B');
    resolved = 'B';
    expect(await e.complete('one', cancellation: c), contains('你好'));
    expect(await e.complete('two', cancellation: c), contains('你好'));
    expect(probes, 1);
    expect(posts.map((p) => p['providerCode']), ['A', 'A']);
    expect(tokens.clears, 0);
  });
  test('two explicit same-name transports stay separate with no GET', () async {
    final c = TranslationCancellationController();
    final s = AISettings.defaults()..mode = AIMode.backend;
    for (final code in ['A', 'B']) {
      final e = executor(s, profile(pair(code)));
      final fixed = await prepareOf(e, c);
      expect(fixed?.backendSelection?.providerCode, code);
      await e.complete(code, cancellation: c);
    }
    expect(probes, 0);
    expect(posts.map((p) => p['providerCode']), ['A', 'B']);
  });
  test(
      'preparation cannot retroactively upgrade an already started legacy executor',
      () async {
    final c = TranslationCancellationController();
    final e = executor(AISettings.defaults(), profile(null));
    await e.complete('old logical attempt', cancellation: c);
    final error = await failureOf(prepareOf(e, c));
    expect(
        error,
        isA<TranslationRequestFailure>()
            .having((e) => e.safeCode, 'code', 'invalid_backend_selection'));
    expect(posts.length, 1);
    expect(probes, 1);
  });
  test(
      'unknown synthetic provider payload remains generic in translation failure',
      () async {
    wire = 'http';
    responseCode = 'synthetic-secret SQL token';
    final e = executor(AISettings.defaults(), profile(null));
    final error = await failureOf(
        e.complete('x', cancellation: TranslationCancellationController()));
    expect(
        error,
        isA<TranslationRequestFailure>()
            .having((e) => e.safeCode, 'code', 'request_failed'));
    expect(error.toString(), isNot(contains('synthetic-secret')));
    expect(posts.length, 1);
  });
  test(
      'reasoning negotiation checks original scope between asynchronous profile callbacks',
      () async {
    wire = 'http';
    failureStatus = 400;
    responseCode = 'unsupported_reasoning_control';
    var secondCallback = 0;
    final p = profile(pair('A'));
    final e = TranslationStreamExecutor(
        service: BackendChatService(
            TranslationModelResolver.apply(AISettings.defaults(), p)),
        profile: p,
        onProfileChanged: (_) async {
          secondCallback++;
        });
    final c = TranslationCancellationController();
    expect((await prepareOf(e, c))?.version, 2);
    final error = await failureOf(
        e.complete('x', cancellation: c, onProfileChanged: (_) async {
      tokens.account = 'account-b';
      await Future<void>.value();
    }));
    expect(
        error,
        isA<TranslationRequestFailure>()
            .having((e) => e.safeCode, 'code', 'backend_scope_changed'));
    expect(secondCallback, 0);
    expect(posts.length, 1);
    expect(probes, 0);
  });
  test('modern executor must be explicitly prepared before any POST', () async {
    final e = executor(AISettings.defaults(), profile(pair('A')));
    final error = await failureOf(
        e.complete('x', cancellation: TranslationCancellationController()));
    expect(
        error,
        isA<TranslationRequestFailure>()
            .having((e) => e.safeCode, 'code', 'invalid_backend_selection'));
    expect(posts, isEmpty);
  });
  for (final code in [
    'model_ambiguous',
    'model_unavailable',
    'catalog_not_public'
  ]) {
    test(
        'legacy $code preparation fails memoized zero POST and never logout/retry',
        () async {
      probeStatus = code == 'catalog_not_public' ? 403 : 409;
      responseCode = code;
      final e =
          executor(AISettings.defaults()..mode = AIMode.backend, profile(null));
      final c = TranslationCancellationController();
      final a = await failureOf(prepareOf(e, c));
      final b = await failureOf(prepareOf(e, c));
      expect(
          a,
          isA<TranslationRequestFailure>()
              .having((e) => e.safeCode, 'code', code));
      expect(b, isA<TranslationRequestFailure>());
      expect(probes, 1);
      expect(posts, isEmpty);
      expect(tokens.clears, 0);
    });
  }
  for (final route in ['http', 'sse']) {
    for (final code in ['model_unavailable', 'catalog_not_public']) {
      test(
          '$route configuration safe code pauses regardless status and raw body absent',
          () async {
        wire = route;
        responseCode = code;
        failureStatus = code == 'catalog_not_public' ? 403 : 409;
        final e = executor(
            AISettings.defaults()..mode = AIMode.backend, profile(null));
        final error = await failureOf(
            e.complete('x', cancellation: TranslationCancellationController()));
        expect(
            error,
            isA<TranslationRequestFailure>()
                .having((e) => e.safeCode, 'code', code)
                .having((e) => e.kind, 'kind',
                    TranslationFailureKind.invalidRequest));
        final failure = error as TranslationRequestFailure;
        expect(
            const TranslationRetryPolicy()
                .decide(
                    failure: failure,
                    categoryAttempt: 0,
                    chunkRunes: 10000,
                    minimumSplitRunes: 100,
                    now: DateTime(2026))
                .action,
            TranslationRetryAction.pause);
        expect(error.toString(), isNot(contains('synthetic-secret')));
        expect(posts.length, 1);
        expect(tokens.clears, 0);
      });
    }
  }
  test(
      'one cancelled prepare waiter does not cancel another original-scope waiter',
      () async {
    entered = Completer();
    gate = Completer();
    gates.add(gate!);
    final e =
        executor(AISettings.defaults()..mode = AIMode.backend, profile(null));
    final cancelled = TranslationCancellationController(),
        valid = TranslationCancellationController();
    final first = failureOf(prepareOf(e, cancelled));
    final second = prepareOf(e, valid);
    // red missing method must not hang waiting for a nonexistent GET.
    await Future.any([
      entered!.future,
      Future<void>.delayed(const Duration(milliseconds: 100))
    ]);
    cancelled.cancel();
    gate!.complete();
    expect(
        await first,
        isA<TranslationRequestFailure>()
            .having((e) => e.kind, 'kind', TranslationFailureKind.cancelled));
    final fixed = await second;
    expect(fixed?.backendSelection?.providerCode, 'A');
    expect(probes, 1);
    expect(posts, isEmpty);
  });
  for (final change in ['account', 'origin', 'epoch', 'restore']) {
    test('scope $change during preparation no successful bind or POST',
        () async {
      entered = Completer();
      gate = Completer();
      gates.add(gate!);
      final e =
          executor(AISettings.defaults()..mode = AIMode.backend, profile(null));
      final pending =
          failureOf(prepareOf(e, TranslationCancellationController()));
      await Future.any([
        entered!.future,
        Future<void>.delayed(const Duration(milliseconds: 100))
      ]);
      switch (change) {
        case 'account':
          tokens.account = 'account-b';
        case 'origin':
          BackendConfig.host = '127.0.0.1:9';
        case 'epoch':
          ModelCatalog.resetExecutionForTest();
        case 'restore':
          BackupService.agentExecutionRevision++;
      }
      gate!.complete();
      final error = await pending;
      expect(
          error,
          isA<TranslationRequestFailure>()
              .having((e) => e.safeCode, 'code', 'backend_scope_changed'));
      expect(posts, isEmpty);
      expect(tokens.clears, 0);
    });
  }
  test(
      'prepared modern probe identity rejects same-account login ABA and restore generation',
      () {
    final s = AISettings.defaults();
    final p = profile(pair('A'));
    final service = TranslationModelProbeService();
    final a =
        service.identify(accountHash: 'account-a', settings: s, profile: p);
    expect(
        () => service.identify(accountHash: 'other', settings: s, profile: p),
        throwsA(isA<TranslationModelUnavailableException>()));
    expect(
        service.isIdentityCurrent(a,
            accountHash: 'account-a', settings: s, profile: p),
        isTrue);
    ModelCatalog.resetExecutionForTest();
    expect(
        service.isIdentityCurrent(a,
            accountHash: 'account-a', settings: s, profile: p),
        isFalse);
    final b =
        service.identify(accountHash: 'account-a', settings: s, profile: p);
    BackupService.agentExecutionRevision++;
    expect(
        service.isIdentityCurrent(b,
            accountHash: 'account-a', settings: s, profile: p),
        isFalse);
  });
  test(
      'production probe factory prepares modern pair and keeps provider-specific safe evidence',
      () async {
    final s = AISettings.defaults();
    final service = TranslationModelProbeService();
    for (final code in ['A', 'B']) {
      final p = profile(pair(code));
      final result = await service
          .start(
              accountHash: 'account-a',
              settings: s,
              profile: p,
              isConfigurationCurrent: () => true)
          .result;
      expect(result.record.status, TranslationModelProbeStatus.verified);
      expect(
          service
              .lookup(accountHash: 'account-a', settings: s, profile: p)
              ?.fingerprint,
          result.record.fingerprint);
    }
    expect(posts.map((p) => p['providerCode']), ['A', 'B']);
    expect(probes, 0);
    wire = 'http';
    failureStatus = 403;
    responseCode = 'catalog_not_public';
    final p = profile(pair('A'));
    final failed = await service
        .start(
            accountHash: 'account-a',
            settings: s,
            profile: p,
            isConfigurationCurrent: () => true)
        .result;
    expect(failed.record.status, TranslationModelProbeStatus.failed);
    expect(failed.record.safeErrorCode, 'catalog_not_public');
    expect(
        TranslationModelProbeRecord.fromJson(failed.record.toJson())
            .safeErrorCode,
        'catalog_not_public');
    expect(posts.length, 3);
    expect(tokens.clears, 0);
  });
  test(
      'exact directory revocation between chunks prevents next POST without swapping',
      () async {
    final c = TranslationCancellationController();
    final e = executor(AISettings.defaults(), profile(pair('A')));
    expect((await prepareOf(e, c))?.backendSelection?.providerCode, 'A');
    await e.complete('first', cancellation: c);
    await ModelCatalog.refreshFromBackend();
    expect(posts.length, 1);
    final error = await failureOf(e.complete('second', cancellation: c));
    expect(
        error,
        isA<TranslationRequestFailure>()
            .having((e) => e.safeCode, 'code', 'model_unavailable'));
    expect(posts.length, 1);
    expect(probes, 0);
  });
  test(
      'controlled short first-event deadline and cancellation retain fixed pair, no resend',
      () async {
    final e = executor(AISettings.defaults(), profile(pair('A')),
        first: const Duration(milliseconds: 30));
    final c = TranslationCancellationController();
    expect((await prepareOf(e, c))?.version, 2);
    entered = Completer();
    gate = Completer();
    gates.add(gate!);
    final error = await failureOf(e.complete('slow', cancellation: c));
    expect(
        error,
        isA<TranslationRequestFailure>().having(
            (e) => e.kind, 'kind', TranslationFailureKind.firstEventTimeout));
    expect(posts.length, 1);
    expect(posts.single['providerCode'], 'A');
    expect(probes, 0);
    gate!.complete();
  });
}
