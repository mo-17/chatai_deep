import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/story_backend_generation_snapshot.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer server;
  late HttpOverrides? oldOverrides;
  late String oldHost;
  late bool oldHttps;
  late HiDBManager storage;
  late StoryRoomDao dao;
  late AISettings global;
  late StoryRoomModel room;
  late StoryParticipantModel speaker;
  final runs = <StoryBackendGenerationSnapshot>[];
  final posts = <Map<String, dynamic>>[];
  int probes = 0, serial = 0, closed = 0;
  bool current = true;
  Completer<void>? probeEntered, probeRelease;
  String probeCode = 'L';
  int probeStatus = 200;
  BackendSelection pair(String code, {String account = 'account-a'}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: 'same',
          accountHash: account,
          origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
  setUpAll(() {
    root = Directory(Platform.environment['R3B3A_ROOT']!);
    final nonce = Platform.environment['R3B3A_NONCE']!;
    expect(root.path, '/tmp/chatai-r3b3a-owned-$nonce');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    sqfliteFfiInit();
  });
  setUp(() async {
    current = true;
    posts.clear();
    probes = 0;
    probeEntered = null;
    probeRelease = null;
    probeCode = 'L';
    probeStatus = 200;
    oldOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      expect(r.headers.value(HttpHeaders.authorizationHeader),
          'Bearer synthetic-jwt');
      if (r.uri.path == '/uapi/ai/model-selection') {
        probes++;
        probeEntered?.complete();
        if (probeRelease != null) await probeRelease!.future;
        r.response.statusCode = probeStatus;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(probeStatus == 200
            ? {
                'code': 0,
                'data': {
                  'providerCode': probeCode,
                  'modelId': r.uri.queryParameters['modelId']
                }
              }
            : {
                'code': 409,
                'safeCode': 'model_ambiguous',
                'message': '后端模型名称不唯一，请明确选择服务商'
              }));
      } else {
        expect(r.uri.path,
            anyOf('/uapi/chat/completions', '/uapi/chat/completions/stream'));
        expect(r.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, dynamic>;
        posts.add(body);
        if (r.uri.path.endsWith('/stream')) {
          r.response.headers.contentType = ContentType('text', 'event-stream');
          r.response.write('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'SYNTHETIC'}
                  }
                ]
              })}\n\ndata: [DONE]\n\n');
        } else {
          r.response.headers.contentType = ContentType.json;
          r.response.write(jsonEncode({
            'code': 0,
            'data': {
              'content': 'SYNTHETIC',
              'usage': {'prompt_tokens': 1, 'completion_tokens': 1}
            }
          }));
        }
      }
      await r.response.close();
    });
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
    global = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = pair('G');
    room = StoryRoomModel(
        title: 'SYNTHETIC',
        backendSelection: pair('R'),
        modelId: ' old local ',
        modelProviderId: ' local-id ');
    speaker = StoryParticipantModel(
        id: 1,
        roomId: 1,
        participantKey: 'p/one',
        role: 'assistant',
        name: 'S',
        backendSelection: pair('P'),
        modelId: ' old role ',
        modelProviderId: ' other-local ',
        topP: 0.4);
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        '${root.path}/case-${serial++}.sqlite',
        options: OpenDatabaseOptions(singleInstance: false)));
    dao = await StoryRoomDao.create(storage);
  });
  tearDown(() async {
    for (final run in runs) {
      run.retire();
    }
    runs.clear();
    if (probeRelease?.isCompleted == false) probeRelease!.complete();
    await server.close(force: true);
    await storage.db.close();
    expect(storage.db.isOpen, isFalse);
    closed++;
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    HttpOverrides.global = oldOverrides;
  });
  tearDownAll(() => File('${root.path}/cleanup.json').writeAsStringSync(
          jsonEncode({
        'sqliteClosed': closed,
        'allClosed': true,
        'httpServersClosed': closed
      })));
  StoryBackendGenerationSnapshot capture() {
    final r = StoryBackendGenerationSnapshot(
        global: global,
        room: room,
        participants: [speaker],
        isCurrent: () => current);
    runs.add(r);
    return r;
  }

  Future<ChatTransportException> failure(Future<Object?> f) async {
    try {
      await f;
      fail('must refuse');
    } catch (e) {
      expect(e, isA<ChatTransportException>());
      return e as ChatTransportException;
    }
  }

  void check() {
    if (!current) throw StateError('synthetic original scope lost');
  }

  // 相同fixture在旧DAO只退回旧实际整实体save；不把缺API编译当功能red。
  Future<dynamic> snapshot(String kind) async {
    try {
      final dynamic actual = dao;
      return kind == 'room'
          ? await actual.roomBackendSnapshot(room, validate: check)
          : await actual.participantBackendSnapshot(speaker, validate: check);
    } on NoSuchMethodError {
      return null;
    }
  }

  Future<Object> save(
      String kind, BackendSelection value, dynamic expected) async {
    try {
      final dynamic actual = dao;
      return kind == 'room'
          ? await actual.saveRoomBackendChecked(room, value, expected,
              validate: check)
          : await actual.saveParticipantBackendChecked(speaker, value, expected,
              validate: check);
    } on NoSuchMethodError {
      if (kind == 'room') {
        room.backendSelection = value;
        await dao.saveRoom(room);
        return room;
      }
      speaker.backendSelection = value;
      await dao.saveParticipant(speaker);
      return speaker;
    }
  }

  for (final r in ['pair', 'follow', 'legacy', 'invalid', 'foreign']) {
    for (final s in ['pair', 'follow', 'legacy']) {
      test('layer $s -> $r -> global preserves declarations and raw IDs', () {
        BackendSelection? layer(String type, String code) => switch (type) {
              'pair' => pair(code),
              'follow' => BackendSelection.follow(),
              'invalid' => BackendSelection.fromStorage('unknown'),
              'foreign' => pair(code, account: 'foreign'),
              _ => null
            };
        room.backendSelection = layer(r, 'R');
        room.modelId = r == 'legacy' ? ' raw room / ' : 'ignored';
        speaker.backendSelection = layer(s, 'P');
        speaker.modelId = s == 'legacy' ? ' raw role / ' : 'ignored';
        final before =
            jsonEncode([global.toJson(), room.toJson(), speaker.toJson()]);
        final next = storyBackendLayer(
            storyBackendLayer(global, room.backendSelection, room.modelId),
            speaker.backendSelection,
            speaker.modelId);
        expect(jsonEncode([global.toJson(), room.toJson(), speaker.toJson()]),
            before);
        if (s == 'pair') {
          expect(next.backendSelection!.providerCode, 'P');
        } else if (s == 'legacy') {
          expect(next.backendSelection, isNull);
          expect(next.backendModel, ' raw role / ');
        } else if (r == 'legacy') {
          expect(next.backendSelection, isNull);
          expect(next.backendModel, ' raw room / ');
        } else if (r == 'follow') {
          expect(next.backendSelection!.providerCode, 'G');
        } else {
          expect(next.backendSelection!.toSqlText(),
              room.backendSelection!.toSqlText());
        }
      });
    }
  }
  test(
      'exact room/speaker same-name two transports and settings mutations cannot change pair',
      () async {
    final run = capture();
    global.backendSelection = pair('OTHER');
    room.backendSelection = pair('OTHER');
    speaker.backendSelection = pair('OTHER');
    speaker.topP = 0.9;
    final r = await run.prepareRoom();
    final s = await run.prepareParticipant(speaker);
    expect(r.pair.providerCode, 'R');
    expect(s.pair.providerCode, 'P');
    expect(s.settings.topP, 0.4);
    expect(probes, 0);
    await r.chatWithUsage(prompt: 'X', history: []);
    await s.chatStreamEvents(prompt: 'Y', history: []).toList();
    expect(posts.map((p) => p['providerCode']), ['R', 'P']);
    expect(posts.every((p) => p['model'] == 'same'), isTrue);
    expect(r.usageProviderId, isNot(s.usageProviderId));
  });
  test(
      'legacy room plus follow resolves once then fixes inherited child, options and later rounds',
      () async {
    room.backendSelection = null;
    room.modelId = ' raw / room ';
    speaker.backendSelection = BackendSelection.follow();
    speaker.modelId = 'ignored';
    final run = capture();
    final r = await run.prepareRoom();
    probeCode = 'OTHER';
    final s = await run.prepareParticipant(speaker);
    expect(probes, 1);
    expect(s.pair.pairKey, r.pair.pairKey);
    expect(s.settings.topP, 0.4);
    await s.chatWithUsage(prompt: 'X', history: []);
    await s.chatStreamEvents(prompt: 'Y', history: [], extraMessages: [
      {'role': 'assistant', 'content': 'TOOL ROUND'}
    ]).toList();
    expect(
        posts.every(
            (p) => p['providerCode'] == 'L' && p['model'] == ' raw / room '),
        isTrue);
    expect(probes, 1);
  });
  test(
      'one cancelled waiter does not cancel same-run shared legacy preparation',
      () async {
    room.backendSelection = null;
    room.modelId = 'legacy';
    probeEntered = Completer();
    probeRelease = Completer();
    final run = capture();
    final abort = Completer<void>();
    final a = run.prepareRoom(abortTrigger: abort.future);
    final b = run.prepareRoom();
    final stopped = failure(a);
    await probeEntered!.future;
    abort.complete();
    expect((await stopped).safeCode, 'cancelled');
    probeRelease!.complete();
    expect((await b).pair.providerCode, 'L');
    expect(probes, 1);
    expect(posts, isEmpty);
  });
  for (final change in ['origin', 'epoch', 'restore', 'retire', 'current']) {
    test('original $change during legacy GET produces zero POST and no rebound',
        () async {
      room.backendSelection = null;
      room.modelId = 'legacy';
      probeEntered = Completer();
      probeRelease = Completer();
      final run = capture();
      final pending = failure(run.prepareRoom());
      await probeEntered!.future;
      if (change == 'origin') {
        BackendConfig.host = '127.0.0.1:1';
      }
      if (change == 'epoch') {
        await LoginDao.saveAuthToken('synthetic-jwt',
            userName: 'S', extras: {'accountHash': 'account-a'});
      }
      if (change == 'restore') BackupService.restoreTick.value++;
      if (change == 'retire') run.retire();
      if (change == 'current') current = false;
      probeRelease!.complete();
      await pending;
      expect(posts, isEmpty);
      expect(probes, 1);
    });
  }
  test(
      'last caller beforeDispatch await expires run: zero POST and no password/direct fallback',
      () async {
    final run = capture();
    final s = await run.prepareParticipant(speaker);
    final entered = Completer<void>(), release = Completer<void>();
    final pending = failure(s.chatWithUsageWithOptions(
        prompt: 'X',
        history: [],
        options: ChatRequestOptions(beforeDispatch: (_) async {
          entered.complete();
          await release.future;
        })));
    await entered.future;
    current = false;
    release.complete();
    await pending;
    expect(posts, isEmpty);
  });
  test('ambiguous failure memoized and modern foreign never becomes global',
      () async {
    room.backendSelection = null;
    room.modelId = 'legacy';
    probeStatus = 409;
    final run = capture();
    expect((await failure(run.prepareRoom())).safeCode, 'model_ambiguous');
    await failure(run.prepareRoom());
    expect(probes, 1);
    expect(posts, isEmpty);
    room.backendSelection = pair('FOREIGN', account: 'other');
    final foreign = capture();
    await failure(foreign.prepareRoom());
    expect(probes, 1);
    expect(posts, isEmpty);
  });
  for (final kind in ['room', 'participant']) {
    test(
        'CAS $kind pair/follow only selection/time and committed row, local fields kept',
        () async {
      room.id = await dao.saveRoom(room);
      speaker.roomId = room.id!;
      speaker.id = null;
      speaker.id = await dao.saveParticipant(speaker);
      final expected = await snapshot(kind);
      final table = kind == 'room'
          ? StoryRoomDao.roomTable
          : StoryRoomDao.participantTable;
      final before = (await storage.db.query(table)).single;
      final result = await save(kind, BackendSelection.follow(), expected);
      final row = (await storage.db.query(table)).single;
      expect(
          Map.of(row)
            ..remove('backendSelection')
            ..remove('updatedAt'),
          Map.of(before)
            ..remove('backendSelection')
            ..remove('updatedAt'));
      expect(BackendSelection.fromStorage(row['backendSelection'])!.isFollow,
          isTrue);
      expect(
          result is StoryRoomModel
              ? result.backendSelection!.isFollow
              : (result as StoryParticipantModel).backendSelection!.isFollow,
          isTrue);
    });
    test('CAS $kind final query guard rolls actual SQL back', () async {
      room.id = await dao.saveRoom(room);
      speaker.roomId = room.id!;
      speaker.id = null;
      speaker.id = await dao.saveParticipant(speaker);
      final table = kind == 'room'
          ? StoryRoomDao.roomTable
          : StoryRoomDao.participantTable;
      final expected = await snapshot(kind);
      final before = (await storage.db.query(table)).single;
      var guards = 0;
      void finalCheck() {
        if (++guards == 4) current = false;
        check();
      }

      final dynamic actual = dao;
      // 旧实际API没有guard；不以缺API报错充当事务回滚证据。
      Future<Object> publish() async {
        try {
          return kind == 'room'
              ? await actual.saveRoomBackendChecked(room, pair('NEW'), expected,
                  validate: finalCheck)
              : await actual.saveParticipantBackendChecked(
                  speaker, pair('NEW'), expected,
                  validate: finalCheck);
        } on NoSuchMethodError {
          return save(kind, pair('NEW'), expected);
        }
      }

      await expectLater(publish(), throwsA(isA<StateError>()));
      expect((await storage.db.query(table)).single, before);
    });
    for (final change in ['row', 'memory', 'scope', 'delete']) {
      test('CAS $kind $change rejects without changing selection', () async {
        room.id = await dao.saveRoom(room);
        speaker.roomId = room.id!;
        speaker.id = null;
        speaker.id = await dao.saveParticipant(speaker);
        final expected = await snapshot(kind);
        final table = kind == 'room'
            ? StoryRoomDao.roomTable
            : StoryRoomDao.participantTable;
        if (change == 'row') {
          await storage.db.update(table, {'updatedAt': 999},
              where: 'id=?',
              whereArgs: [kind == 'room' ? room.id : speaker.id]);
        }
        if (change == 'memory') {
          if (kind == 'room') {
            room.modelId = 'changed';
          } else {
            speaker.roomId = 99;
          }
        }
        if (change == 'scope') current = false;
        if (change == 'delete') await storage.db.delete(table);
        await expectLater(save(kind, pair('NEW'), expected), throwsA(anything));
        final rows = await storage.db.query(table);
        if (rows.isNotEmpty) {
          expect(
              BackendSelection.fromStorage(rows.single['backendSelection'])!
                  .providerCode,
              kind == 'room' ? 'R' : 'P');
        }
      });
    }
  }
}
