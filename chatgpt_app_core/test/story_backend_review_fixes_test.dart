import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/story_backend_generation_snapshot.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late String oldHost;
  late bool oldHttps;
  late HttpOverrides? oldOverrides;
  final runs = <StoryBackendGenerationSnapshot>[];
  final handlers = <Future<void>>[];
  final delays = <Completer<void>>[];
  final timers = <Timer>[];
  final posts = <Map<String, dynamic>>[];
  final evidence = <Map<String, Object?>>[];
  int closed = 0;
  Duration responseDelay = Duration.zero;
  bool current = true;
  setUpAll(() {
    root = Directory(Platform.environment['R3B3A_ROOT']!);
    expect(root.path,
        '/tmp/chatai-r3b3a-p2-owned-${Platform.environment['R3B3A_NONCE']}');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': Platform.environment['R3B3A_NONCE']});
  });
  Future<void> respond(HttpRequest r) async {
    expect(r.method, 'POST');
    expect(r.uri.path, '/uapi/chat/completions');
    expect(r.headers.value(HttpHeaders.authorizationHeader),
        'Bearer synthetic-jwt');
    final body =
        jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
    posts.add(body);
    r.response.headers.contentType = ContentType.json;
    // 实际成功响应先到字节；timeout不能被自动重试掩盖。
    r.response.bufferOutput = false;
    r.response.write('{"code":0,"padding":"${'.' * 2048}",');
    if (responseDelay > Duration.zero) {
      final release = Completer<void>();
      delays.add(release);
      timers.add(Timer(responseDelay, () {
        if (!release.isCompleted) release.complete();
      }));
      await release.future;
    }
    try {
      r.response.write('"data":{"content":"SYNTHETIC",'
          '"usage":{"prompt_tokens":1,'
          '"completion_tokens":1}}}');
      await r.response.close();
    } on HttpException {
      // teardown只关闭本夹具连接，取消/timeout后的peer关闭属于预期。
    } on SocketException {
      // 同上，不把未知异常吞为测试通过。
    }
  }

  setUp(() async {
    current = true;
    responseDelay = Duration.zero;
    posts.clear();
    handlers.clear();
    delays.clear();
    timers.clear();
    oldOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) => handlers.add(respond(r)));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = '127.0.0.1:${server.port}';
    BackendConfig.useHttps = false;
    LoginDao.resetHooksForTest();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: BackendConfig.host,
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: PairTokens(),
        onLogoutNavigate: () {}));
    ModelCatalog.resetExecutionForTest();
  });
  tearDown(() async {
    for (final run in runs) {
      run.retire();
    }
    runs.clear();
    for (final timer in timers) {
      timer.cancel();
    }
    for (final release in delays) {
      if (!release.isCompleted) release.complete();
    }
    await Future.wait(handlers);
    await server.close(force: true);
    closed++;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    HttpOverrides.global = oldOverrides;
  });
  tearDownAll(() {
    File('${root.path}/cleanup.json').writeAsStringSync(
        jsonEncode({'httpServersClosed': closed, 'allClosed': true}));
    File('${root.path}/review-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
  });
  StoryBackendGenerationSnapshot capture() {
    final pair = BackendSelection.pair(
        providerCode: 'R/raw',
        modelId: ' same/raw ',
        accountHash: 'account-a',
        origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
    final run = StoryBackendGenerationSnapshot(
        global: AISettings.defaults()
          ..mode = AIMode.backend
          ..backendSelection = pair,
        room: StoryRoomModel(
            title: 'SYNTHETIC', backendSelection: BackendSelection.follow()),
        participants: [],
        isCurrent: () => current);
    runs.add(run);
    return run;
  }

  Future<Object?> cancelledAttempt(
      StoryBackendGenerationSnapshot run, Future<void> abort) async {
    try {
      final prepared = await run.prepareRoom(abortTrigger: abort);
      await prepared.chatWithUsage(prompt: 'CANCELLED', history: []);
      return null;
    } catch (error) {
      return error;
    }
  }

  void expectCancelled(Object? error) {
    expect(error, isA<ChatTransportException>());
    expect((error as ChatTransportException).safeCode, 'cancelled');
  }

  test('review P2 cached preparation rejects already-completed waiter abort',
      () async {
    final run = capture();
    final fixed = await run.prepareRoom();
    final abort = Completer<void>()..complete();
    final error = await cancelledAttempt(run, abort.future);
    final other = await run.prepareRoom();
    await other.chatWithUsage(prompt: 'OTHER', history: []);
    evidence.add({'case': 'precompleted', 'cancelledPosts': posts.length - 1});
    expectCancelled(error);
    expect(other.pair.pairKey, fixed.pair.pairKey);
    expect(posts.length, 1);
    expect(posts.single['messages'].toString(), contains('OTHER'));
  });
  test('review P2 cached completion boundary cancels only its original waiter',
      () async {
    final run = capture();
    await run.prepareRoom();
    final abort = Completer<void>();
    final cancelled = cancelledAttempt(run, abort.future);
    final other = run.prepareRoom();
    abort.complete();
    final error = await cancelled;
    await (await other).chatWithUsage(prompt: 'OTHER', history: []);
    evidence.add(
        {'case': 'completion-boundary', 'cancelledPosts': posts.length - 1});
    expectCancelled(error);
    expect(posts.length, 1);
  });
  for (final explicit in [true, false]) {
    test(
        'review P2 ${explicit ? 'explicit two-minute' : 'default chat'} '
        'deadline reaches guarded transport past 15 seconds', () async {
      final run = capture();
      final service = await run.prepareRoom();
      responseDelay = const Duration(seconds: 16);
      final watch = Stopwatch()..start();
      final value = await service.chat(
          prompt: 'SLOW',
          history: [],
          timeout: explicit ? const Duration(minutes: 2) : null);
      watch.stop();
      evidence.add({
        'case': explicit ? 'explicit-slow' : 'default-slow',
        'actualElapsedMs': watch.elapsedMilliseconds,
        'posts': posts.length,
        'responseDelayMs': responseDelay.inMilliseconds
      });
      expect(value, 'SYNTHETIC');
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(16000));
      expect(posts.length, 1);
      expect(posts.single['providerCode'], 'R/raw');
      expect(posts.single['model'], ' same/raw ');
    }, timeout: const Timeout(Duration(seconds: 25)));
  }
  test('review P2 short chat deadline still cancels actual guarded transport',
      () async {
    final run = capture();
    final service = await run.prepareRoom();
    responseDelay = const Duration(seconds: 16);
    Object? error;
    try {
      await service.chat(
          prompt: 'SHORT',
          history: [],
          timeout: const Duration(milliseconds: 100));
    } catch (e) {
      error = e;
    }
    expect(error, isA<ChatTransportException>());
    expect((error as ChatTransportException).safeCode, 'timeout');
    expect(posts.length, 1);
    expect(() => service.verify(), throwsA(isA<ChatTransportException>()));
    evidence.add({'case': 'short-timeout', 'posts': posts.length});
  });
}
