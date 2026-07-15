import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/sync/cloud_sync_client.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  setUp(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.install(_testLoginConfig(_MemoryTokenStorage()));
  });

  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });

  Future<HiDBManager> newDb() async {
    final dir =
        await Directory.systemTemp.createTemp('cloud_sync_client_test_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${dir.path}/db.sqlite'),
    );
  }

  test('pullRemoteChanges 解析服务端变更并推进游标', () async {
    final client = CloudSyncClient(
      localSync: LocalSyncService(await newDb()),
      cursorStore: MemorySyncCursorStore(),
      headersBuilder: () => const {},
      client: MockClient((request) async {
        expect(request.url.path, '/uapi/sync/pull');
        expect(request.url.queryParameters['cursor'], '9');
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'cursor': 10,
              'hasMore': false,
              'changes': [
                {
                  'entity': 'conversation',
                  'entityId': '1',
                  'op': 'upsert',
                  'updatedAt': 20,
                  'payload': {
                    'cid': 1,
                    'title': '远端标题',
                    'icon': '',
                    'stickTime': 0,
                    'updateAt': 20,
                  },
                }
              ],
            },
          })),
          200,
        );
      }),
    );

    final result = await client.pullRemoteChanges(cursor: 9);

    expect(result.cursor, 10);
    expect(result.changes.single.key, 'conversation:1');
    expect(result.changes.single.payload['title'], '远端标题');
  });

  test('pushLocalChanges 上传实体和 deviceId，解析冲突', () async {
    final store = MemorySyncCursorStore(deviceId: 'phone-a');
    final client = CloudSyncClient(
      localSync: LocalSyncService(await newDb()),
      cursorStore: store,
      headersBuilder: () => const {},
      client: MockClient((request) async {
        expect(request.url.path, '/uapi/sync/push');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['deviceId'], 'phone-a');
        expect((body['changes'] as List).single, {
          'entity': 'assistant',
          'entityId': 'a1',
          'op': 'upsert',
          'updatedAt': 100,
          'payload': {'name': 'A'},
        });
        return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'cursor': 12,
                'accepted': [],
                'conflicts': [
                  {
                    'entity': 'assistant',
                    'entityId': 'a1',
                    'reason': 'same_timestamp',
                  }
                ],
              },
            }),
            200);
      }),
    );

    final result = await client.pushLocalChanges([
      const SyncChange(
        entity: 'assistant',
        id: 'a1',
        op: SyncOp.upsert,
        updatedAt: 100,
        payload: {'name': 'A'},
      ),
    ]);

    expect(result.cursor, 12);
    expect(result.conflicts, ['assistant:a1']);
    expect(result.conflictDetails.single.reason, 'same_timestamp');
  });

  test('syncOnce 拉取远端、应用本地、上传增量并记录游标', () async {
    final storage = await newDb();
    final dao = await ConversationListDao.create(storage);
    await dao.saveConversation(ConversationModel(cid: 1, icon: '')
      ..title = '本地旧标题'
      ..stickTime = 0
      ..updateAt = 10);
    await dao.saveConversation(ConversationModel(cid: 2, icon: '')
      ..title = '本地待上传'
      ..stickTime = 0
      ..updateAt = 30);

    final store = MemorySyncCursorStore(cursor: 3, lastPushAt: 20);
    final now = DateTime(2026, 7, 1, 12, 30);
    final requests = <String>[];
    final client = CloudSyncClient(
      localSync: LocalSyncService(storage),
      cursorStore: store,
      headersBuilder: () => const {},
      nowProvider: () => now,
      client: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.endsWith('/pull')) {
          expect(request.url.queryParameters['cursor'], '3');
          return http.Response.bytes(
              utf8.encode(jsonEncode({
                'code': 0,
                'data': {
                  'cursor': 4,
                  'hasMore': false,
                  'changes': [
                    {
                      'entity': 'conversation',
                      'entityId': '1',
                      'op': 'upsert',
                      'updatedAt': 25,
                      'payload': {
                        'cid': 1,
                        'title': '远端新标题',
                        'icon': '',
                        'stickTime': 0,
                        'updateAt': 25,
                      },
                    }
                  ],
                },
              })),
              200);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final changes = (body['changes'] as List).cast<Map<String, dynamic>>();
        expect(changes.map((c) => c['entityId']), contains('2'));
        return http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {
                'cursor': 5,
                'accepted': changes,
                'conflicts': [],
              },
            })),
            200);
      }),
    );

    expect(LoginDao.getAccountHash(), isNull);
    final result = await client.syncOnce();

    expect(requests, ['/uapi/sync/pull', '/uapi/sync/push']);
    expect(result.pulled, 1);
    expect(result.pushed, 1);
    expect(store.cursor, 4);
    expect(store.lastPushAt, 30);
    expect(store.lastSyncAt, now.millisecondsSinceEpoch);
    expect(result.finishedAt, now.millisecondsSinceEpoch);
    final rows = await storage.db.query(
      'tb_conversation_list',
      columns: ['cid', 'title'],
      orderBy: 'cid',
    );
    expect(rows.firstWhere((row) => row['cid'] == 1)['title'], '远端新标题');
  });

  test('syncOnce 拉取期间切换账号后应在合并和上传前中止', () async {
    final storage = await newDb();
    final dao = await ConversationListDao.create(storage);
    await dao.saveConversation(ConversationModel(cid: 7, icon: '')
      ..title = 'A 的本地数据'
      ..stickTime = 0
      ..updateAt = 30);
    final localSync = LocalSyncService(storage);
    await localSync.exportChanges(updatedAfter: 20);
    final authStorage = await _installTestAccount();

    final cursorStore = MemorySyncCursorStore(
      cursor: 3,
      lastPushAt: 20,
      lastSyncAt: 11,
    );
    final pullStarted = Completer<void>();
    final releasePull = Completer<void>();
    final pushRequests = <http.Request>[];
    final client = CloudSyncClient(
      localSync: localSync,
      cursorStore: cursorStore,
      headersBuilder: () => {
        'authorization': 'Bearer ${authStorage.readTokenSync()}',
      },
      client: MockClient((request) async {
        if (request.url.path.endsWith('/pull')) {
          pullStarted.complete();
          expect(request.headers['authorization'], 'Bearer token-a');
          await releasePull.future;
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'code': 0,
              'data': {
                'cursor': 4,
                'hasMore': false,
                'changes': [
                  {
                    'entity': 'conversation',
                    'entityId': '99',
                    'op': 'upsert',
                    'updatedAt': 40,
                    'payload': {
                      'cid': 99,
                      'title': 'A 的远端数据',
                      'icon': '',
                      'stickTime': 0,
                      'updateAt': 40,
                    },
                  },
                ],
              },
            })),
            200,
          );
        }

        pushRequests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'cursor': 5,
              'accepted': body['changes'],
              'conflicts': [],
            },
          })),
          200,
        );
      }),
    );

    final outcome = client.syncOnce().then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
    await pullStarted.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('拉取请求未及时开始'),
    );
    await authStorage.writeProfile(
      token: 'token-b',
      userName: 'user-b',
      extras: const {'accountHash': 'account-b'},
    );
    releasePull.complete();

    final error = await outcome.timeout(
      const Duration(seconds: 3),
      onTimeout: () => TimeoutException('同步未在切号后及时中止'),
    );
    final leakedRemoteRows = await storage.db.query(
      'tb_conversation_list',
      where: 'cid = ?',
      whereArgs: [99],
    );

    expect(error, isA<LoginAccountChangedException>());
    expect(error.toString(), isNot(contains('account-a')));
    expect(error.toString(), isNot(contains('account-b')));
    expect(error.toString(), isNot(contains('token-a')));
    expect(error.toString(), isNot(contains('token-b')));
    expect(pushRequests, isEmpty);
    expect(leakedRemoteRows, isEmpty);
    expect(cursorStore.cursor, 3);
    expect(cursorStore.lastPushAt, 20);
    expect(cursorStore.lastSyncAt, 11);
  });

  test('syncOnce 切号后不应继续请求下一页', () async {
    final storage = await newDb();
    final localSync = LocalSyncService(storage);
    await localSync.exportChanges(updatedAfter: 100);
    final authStorage = await _installTestAccount();
    final cursorStore = MemorySyncCursorStore(
      cursor: 3,
      lastPushAt: 100,
      lastSyncAt: 11,
    );
    final firstPullStarted = Completer<void>();
    final releaseFirstPull = Completer<void>();
    var pullRequests = 0;
    final client = CloudSyncClient(
      localSync: localSync,
      cursorStore: cursorStore,
      headersBuilder: () => {
        'authorization': 'Bearer ${authStorage.readTokenSync()}',
      },
      client: MockClient((request) async {
        expect(request.url.path, '/uapi/sync/pull');
        pullRequests++;
        if (pullRequests == 1) {
          firstPullStarted.complete();
          await releaseFirstPull.future;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'cursor': 4,
                'hasMore': true,
                'changes': const [],
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'cursor': 5,
              'hasMore': false,
              'changes': const [],
            },
          }),
          200,
        );
      }),
    );

    final outcome = client.syncOnce().then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
    await firstPullStarted.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('拉取请求未及时开始'),
    );
    await authStorage.writeProfile(
      token: 'token-b',
      userName: 'user-b',
      extras: const {'accountHash': 'account-b'},
    );
    releaseFirstPull.complete();

    final error = await outcome.timeout(
      const Duration(seconds: 3),
      onTimeout: () => TimeoutException('同步未在切号后及时中止'),
    );

    expect(error, isA<LoginAccountChangedException>());
    expect(pullRequests, 1);
    expect(cursorStore.cursor, 3);
    expect(cursorStore.lastPushAt, 100);
    expect(cursorStore.lastSyncAt, 11);
  });

  test('syncOnce 按 hasMore 分页拉取直到服务端返回完成', () async {
    final storage = await newDb();
    final store = MemorySyncCursorStore(cursor: 0, lastPushAt: 1000);
    final cursors = <String?>[];
    final client = CloudSyncClient(
      localSync: LocalSyncService(storage),
      cursorStore: store,
      headersBuilder: () => const {},
      client: MockClient((request) async {
        expect(request.url.path, '/uapi/sync/pull');
        cursors.add(request.url.queryParameters['cursor']);
        final firstPage = request.url.queryParameters['cursor'] == '0';
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': {
              'cursor': firstPage ? 1 : 2,
              'hasMore': firstPage,
              'changes': [
                {
                  'entity': 'conversation',
                  'entityId': firstPage ? '1' : '2',
                  'op': 'upsert',
                  'updatedAt': firstPage ? 10 : 20,
                  'payload': {
                    'cid': firstPage ? 1 : 2,
                    'title': firstPage ? '第一页' : '第二页',
                    'icon': '',
                    'stickTime': 0,
                    'updateAt': firstPage ? 10 : 20,
                  },
                }
              ],
            },
          })),
          200,
        );
      }),
    );

    final result = await client.syncOnce();

    expect(cursors, ['0', '1']);
    expect(result.pulled, 2);
    expect(result.cursor, 2);
    expect(store.cursor, 2);
    final rows = await storage.db.query(
      'tb_conversation_list',
      columns: ['cid', 'title'],
      orderBy: 'cid',
    );
    expect(rows.map((row) => row['title']), ['第一页', '第二页']);
  });

  test('非 200 或 code 非 0 返回清晰异常', () async {
    final client = CloudSyncClient(
      localSync: LocalSyncService(await newDb()),
      cursorStore: MemorySyncCursorStore(),
      headersBuilder: () => const {},
      client: MockClient((_) async => http.Response('no', 401)),
    );

    expect(
      () => client.pullRemoteChanges(),
      throwsA(isA<CloudSyncException>()),
    );
  });

  test('pushLocalChanges 按请求体积自动分批并聚合结果', () async {
    final requestSizes = <int>[];
    var cursor = 20;
    final client = CloudSyncClient(
      localSync: LocalSyncService(await newDb()),
      cursorStore: MemorySyncCursorStore(deviceId: 'phone-b'),
      headersBuilder: () => const {},
      maxPushBodyBytes: 360,
      client: MockClient((request) async {
        requestSizes.add(request.bodyBytes.length);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final changes = (body['changes'] as List).cast<Map<String, dynamic>>();
        cursor++;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'cursor': cursor,
              'accepted': [
                for (final change in changes)
                  {
                    'entity': change['entity'],
                    'entityId': change['entityId'],
                    'op': change['op'],
                    'updatedAt': change['updatedAt'],
                  },
              ],
              'conflicts': [],
            },
          }),
          200,
        );
      }),
    );
    final changes = [
      for (var i = 0; i < 3; i++)
        SyncChange(
          entity: 'assistant_role_asset_chunk',
          id: '1:0:$i',
          op: SyncOp.upsert,
          updatedAt: 100,
          payload: {'data': 'x' * 100},
        ),
    ];

    final result = await client.pushLocalChanges(changes);

    expect(requestSizes.length, greaterThan(1));
    expect(requestSizes.every((size) => size <= 360), isTrue);
    expect(result.accepted.map((change) => change.id),
        ['1:0:0', '1:0:1', '1:0:2']);
    expect(result.cursor, cursor);
  });

  test('pushLocalChanges 拒绝无法单独装入请求的变更', () async {
    final client = CloudSyncClient(
      localSync: LocalSyncService(await newDb()),
      cursorStore: MemorySyncCursorStore(),
      headersBuilder: () => const {},
      maxPushBodyBytes: 100,
      client: MockClient((_) async => fail('不应发起请求')),
    );

    expect(
      () => client.pushLocalChanges([
        SyncChange(
          entity: 'assistant_role_asset_chunk',
          id: '1:0:0',
          op: SyncOp.upsert,
          updatedAt: 100,
          payload: {'data': 'x' * 200},
        ),
      ]),
      throwsA(isA<CloudSyncException>()),
    );
  });

  test('登录自动同步按上次同步时间节流', () {
    final now = DateTime(2026, 7, 1, 12).millisecondsSinceEpoch;

    expect(CloudSyncCoordinator.shouldAutoSync(0, now), isTrue);
    expect(
      CloudSyncCoordinator.shouldAutoSync(
        now - const Duration(minutes: 9).inMilliseconds,
        now,
      ),
      isFalse,
    );
    expect(
      CloudSyncCoordinator.shouldAutoSync(
        now - const Duration(minutes: 10).inMilliseconds,
        now,
      ),
      isTrue,
    );
  });
}

Future<_MemoryTokenStorage> _installTestAccount() async {
  final authStorage = _MemoryTokenStorage();
  await authStorage.writeProfile(
    token: 'token-a',
    userName: 'user-a',
    extras: const {'accountHash': 'account-a'},
  );
  LoginSdkConfig.install(_testLoginConfig(authStorage));
  return authStorage;
}

LoginSdkConfig _testLoginConfig(TokenStorage storage) => LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: storage,
      onLogoutNavigate: () {},
    );

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  @override
  Future<void> clear() async => _profile = null;

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  Map<String, dynamic>? readProfileSync() =>
      _profile == null ? null : Map<String, dynamic>.from(_profile!);

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode,
      ...extras,
    };
  }
}
