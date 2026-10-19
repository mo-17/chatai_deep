// 真实Flutter consumer→自有Nest→合成upstream；只用私有SQLite。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens, PairHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory(Platform.environment['FINAL_OWNED']!);
  final meta =
      jsonDecode(File('${root.path}/nest-ready.json').readAsStringSync())
          as Map<String, dynamic>;
  final nonce = Platform.environment['FINAL_NONCE']!;
  late PairTokens tokens;
  final records = <Object>[];
  final previous = HttpOverrides.current;
  late String oldHost;
  late bool oldHttps;
  Future<Map<String, dynamic>> control(Map<String, Object> body) async {
    final client = HttpClient();
    try {
      final req = await client
          .postUrl(Uri.parse('${meta['origin']}/__fixture/control'));
      req.headers.set('x-fixture-nonce', nonce);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      expect(res.statusCode, 200);
      return jsonDecode(await utf8.decoder.bind(res).join())
          as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> stats() => control({});
  Future<void> awaitProbe() async {
    for (var i = 0; i < 100; i++) {
      if (((await stats())['counts'] as Map)['probes'] as int > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('owned probe barrier not reached');
  }

  BackendSelection pair(String provider, {String model = 'shared'}) =>
      BackendSelection.pair(
          providerCode: provider,
          modelId: model,
          accountHash: 'account-a',
          origin: meta['origin'] as String);
  AISettings selected(String? provider, {String model = 'shared'}) =>
      AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = model
        ..backendSelection =
            provider == null ? null : pair(provider, model: model);
  Future<Object?> errorOf(Future<Object?> future) async {
    try {
      await future;
      return null;
    } catch (e) {
      return e;
    }
  }

  setUpAll(() async {
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    HttpOverrides.global = PairHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    sqfliteFfiInit();
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
  });
  setUp(() async {
    await HiCache.getInstance().prefs?.clear();
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    tokens = PairTokens()..token = meta['tokenA'] as String;
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: meta['origin'] as String,
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    BackendConfig.host = Uri.parse(meta['origin'] as String).authority;
    BackendConfig.useHttps = false;
    await control({'op': 'reset', 'phase': 'flutter'});
    await ModelCatalog.refreshFromBackend();
  });
  tearDown(() async {
    await control({'releaseProbe': true, 'releaseUpstream': true});
    records.add(await stats());
    expect(tokens.clears, 0);
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
  });
  tearDownAll(() {
    HttpOverrides.global = previous;
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    File('${root.path}/flutter-live-evidence.json')
        .writeAsStringSync(jsonEncode(records));
  });
  test('F1 same model A/B stream and nonstream go to exact own upstream',
      () async {
    expect(
        await BackendChatService(selected('alpha'))
            .chat(prompt: 'A', history: []),
        'alpha:answer');
    final events = await BackendChatService(selected('beta'))
        .chatStreamEvents(prompt: 'B', history: []).toList();
    expect(
        events
            .where((e) => e.type == StreamEventType.text)
            .map((e) => e.delta)
            .join(),
        'beta:answer');
    final seen = (await stats())['upstreamRequests'] as List;
    expect(seen.map((e) => e['provider']).toList(), ['alpha', 'beta']);
    expect(seen.every((e) => !(e['fields'] as List).contains('providerCode')),
        true);
  });
  test(
      'F2 fixed run pair survives changing settings and invalid global; legacy ambiguity does not fall back',
      () async {
    final settings = selected('beta');
    final service = BackendChatService(settings);
    await service.prepareBackendSelection();
    settings.backendSelection = pair('alpha');
    await control({'invalidDefault': true});
    expect(
        await service.chat(prompt: 'original B', history: []), 'beta:answer');
    final err = await errorOf(BackendChatService(selected(null))
        .chat(prompt: 'legacy shared', history: []));
    expect(err, isA<ChatTransportException>());
    expect((err as ChatTransportException).safeCode, 'model_ambiguous');
    expect(((await stats())['counts'] as Map)['upstream'], 1);
    expect(tokens.clears, 0);
  });
  for (final kind in ['account', 'token', 'origin']) {
    test('F3 $kind changes during real Nest legacy GET prohibit model dispatch',
        () async {
      await control({'holdProbe': true});
      final service = BackendChatService(selected(null, model: 'unique-beta'));
      final pending = errorOf(service.chat(prompt: 'old scope', history: []));
      await awaitProbe();
      if (kind == 'account') {
        tokens.account = 'account-b';
        tokens.token = meta['tokenB'] as String;
      } else if (kind == 'token') {
        tokens.token = meta['tokenB'] as String;
      } else {
        BackendConfig.host = Uri.parse(meta['originB'] as String).authority;
      }
      await control({'releaseProbe': true});
      expect(await pending, isA<ChatTransportException>());
      expect(((await stats())['counts'] as Map)['upstream'], 0);
      expect(((await stats())['counts'] as Map)['backendCompletion'], 0);
    });
  }
  test(
      'F4 provider disabled after snapshot refuses without upstream fallback or logout',
      () async {
    final service = BackendChatService(selected('alpha'));
    await service.prepareBackendSelection();
    await control({'disableProvider': 'alpha'});
    final err = await errorOf(service.chat(prompt: 'disabled', history: []));
    expect(err, isA<ChatTransportException>());
    expect((err as ChatTransportException).safeCode, 'provider_unavailable');
    expect(((await stats())['counts'] as Map)['upstream'], 0);
  });
  test(
      'F5 actual Nest HTTP/SSE errors remain finite and each sends one synthetic upstream request',
      () async {
    await control({'mode': 'http-error'});
    final httpError = await errorOf(BackendChatService(selected('alpha'))
        .chat(prompt: 'bad parameter', history: []));
    expect(httpError, isA<ChatTransportException>());
    expect(httpError.toString(), isNot(contains('synthetic-secret')));
    expect(((await stats())['counts'] as Map)['upstream'], 1);
    await control({'mode': 'sse-error'});
    final streamError = await errorOf(BackendChatService(selected('beta'))
        .chatStreamEvents(prompt: 'upstream error', history: []).toList());
    expect(streamError, isA<ChatTransportException>());
    expect(streamError.toString(), isNot(contains('synthetic-secret')));
    expect(((await stats())['counts'] as Map)['upstream'], 2);
    expect(tokens.clears, 0);
  });
  test(
      'F6 private SQLite cold reopen keeps explicit pair and subsequent Nest send',
      () async {
    final filename = '${root.path}/cold-pair.db';
    var db = await databaseFactoryFfi.openDatabase(filename);
    var storage = HiDBManager.test(db);
    var dao = await ConversationListDao.create(storage);
    await dao.saveConversation(ConversationModel(
        cid: 777, title: 'cold', icon: 'x', backendSelection: pair('beta')));
    await db.close();
    db = await databaseFactoryFfi.openDatabase(filename);
    storage = HiDBManager.test(db);
    dao = await ConversationListDao.create(storage);
    try {
      final rows = await dao.getConversationList();
      expect(rows.single.backendSelection!.providerCode, 'beta');
      final settings = selected('beta')
        ..backendSelection = rows.single.backendSelection;
      expect(
          await BackendChatService(settings).chat(prompt: 'cold', history: []),
          'beta:answer');
    } finally {
      await db.close();
      expect(db.isOpen, false);
      File('${root.path}/sqlite-cleanup.json')
          .writeAsStringSync(jsonEncode({'file': filename, 'closed': true}));
    }
  });
}
