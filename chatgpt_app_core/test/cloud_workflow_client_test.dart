import 'dart:async';
import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_api.dart';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_client.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/cloud_workflow_fixture.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager db;
  late CloudWorkflowDao dao;
  late PersonalMemoryTestAccount auth;
  late CloudSourceSnapshot source;
  late CloudConfirmedPayload payload;
  late CloudFixtureResult cloud;
  late List<http.Request> requests;
  late bool created;
  late int epoch;
  late String currentOrigin;
  late Future<http.Response> Function(http.Request)? special;
  final clients = <CloudWorkflowClient>[];
  AgentWorkflowScope scope() =>
      AgentWorkflowScope(accountHash: 'a', currentLoginEpoch: () => epoch);
  http.Response response(Object? json, [int status = 200]) =>
      http.Response(jsonEncode(json), status,
          headers: {'content-type': 'application/json'});
  Future<http.Response> handle(http.Request req) async {
    requests.add(req);
    if (special != null) {
      return special!(req);
    }
    final path = req.url.path;
    if (path.endsWith('/capability')) {
      return response({
        'ownerId': 7,
        'available': true,
        'destination': 'cloud',
        'consentVersion': cloudConsentVersion
      });
    }
    if (path.endsWith('/profiles')) {
      return response([
        {
          'providerId': 1,
          'modelRowId': 2,
          'modelId': 'synthetic',
          'providerName': '合成',
          'modelName': '合成'
        }
      ]);
    }
    if (path.contains('/by-idempotency/')) {
      return created
          ? response(cloud.receipt())
          : response({'message': 'not found'}, 404);
    }
    if (req.method == 'POST' && path.endsWith('/cloud-workflows')) {
      expect(await db.db.query(dao.tableName), hasLength(1));
      expect(jsonDecode(req.body), payload.toJson());
      created = true;
      return response(cloud.detail()['parent']);
    }
    if (path.endsWith('/stop')) {
      return response({'state': 'cancelling'});
    }
    if (path.endsWith('/result')) {
      return response([cloud.result()]);
    }
    if (path.endsWith(cloud.taskId)) {
      return response(cloud.detail());
    }
    return response({'items': [], 'nextCursor': null});
  }

  CloudWorkflowClient client(
      {CloudSubmissionPolicy policy =
          const CloudSubmissionPolicy.synthetic()}) {
    final c = CloudWorkflowClient(
        api: CloudWorkflowApi(
            scope: scope(),
            origin: cloudFixtureOrigin,
            token: 'fixed-synthetic-token',
            currentOrigin: () => currentOrigin,
            policy: policy,
            client: MockClient(handle)),
        dao: dao);
    clients.add(c);
    return c;
  }

  // 除分页合同用例外，定向边界不让旧分页错误遮住其它独立问题。
  CloudWorkflowClient reviewClient() => client()
    ..capability = const CloudCapability(7, true)
    ..profiles = [cloudFixtureProfile];

  CloudConfirmedPayload changedPayload(String field) {
    final original = payload.toJson();
    final acceptance = Map<String, dynamic>.from(original['acceptance']);
    final budget = Map<String, dynamic>.from(original['budget']);
    final profiles = {for (final r in cloudRoles) r: cloudFixtureProfile};
    if (field == 'acceptance') acceptance['minChars'] = 1;
    if (field == 'budget') budget['attempts'] = 7;
    if (field == 'profile') {
      profiles['review'] = const CloudProfileChoice(1, 3, 'other', '合成', '另模型');
    }
    return CloudConfirmedPayload(
        key: payload.key,
        clientInstanceId: original['clientInstanceId'],
        source: source.source,
        task: source.task,
        inputs: source.inputs,
        profiles: profiles,
        acceptance: acceptance,
        budget: budget);
  }

  setUp(() async {
    auth = PersonalMemoryTestAccount('a')..install();
    sqfliteFfiInit();
    epoch = 1;
    currentOrigin = cloudFixtureOrigin;
    requests = [];
    created = false;
    special = null;
    db = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(db))
        .saveConversation(ConversationModel(cid: 1, title: '合成', icon: ''));
    final id = await (await MessageDao.create(db, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: '显式本人任务', ownerType: OwnerType.sender, createdAt: 1));
    dao = await CloudWorkflowDao.create(db, accountHash: 'a');
    source = await dao.capture(scope(), cid: 1, messageId: id);
    payload = cloudFixturePayload(source);
    cloud = CloudFixtureResult(payload);
  });
  tearDown(() async {
    for (final c in clients) {
      c.dispose();
    }
    clients.clear();
    await db.db.close();
    LoginSdkConfig.reset();
  });
  test('生产固定关闭即便服务返回true也零POST/零receipt；GET与stop仍可用', () async {
    final c = client(policy: const CloudSubmissionPolicy.production());
    await c.initialize();
    expect(c.canCreate, false);
    expect(() => c.submit(source, payload), throwsStateError);
    expect(await db.db.query(dao.tableName), isEmpty);
    await c.open(cloud.taskId);
    await c.stop();
    expect(
        requests
            .where((r) => r.method == 'POST' && !r.url.path.endsWith('/stop')),
        isEmpty);
  });
  test('游客/缺凭据在首次HTTP前拒绝', () async {
    auth.account = 'guest';
    expect(
        () => CloudWorkflowApi.capture(
            scope: AgentWorkflowScope(accountHash: 'guest')),
        throwsStateError);
    expect(
        () => CloudWorkflowApi(
            scope: scope(),
            origin: cloudFixtureOrigin,
            token: '',
            currentOrigin: () => currentOrigin,
            client: MockClient(handle)),
        throwsStateError);
    expect(requests, isEmpty);
  });
  test('双点击同一确认仅一POST，完整白名单body，没有记忆/key/history/path', () async {
    final c = client();
    await c.initialize();
    final result = await Future.wait(
        [c.submit(source, payload), c.submit(source, payload)]);
    expect(result[0].taskId, result[1].taskId);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    final sent =
        jsonDecode(requests.singleWhere((r) => r.method == 'POST').body) as Map;
    expect(sent.keys.toSet(), {
      'version',
      'consentVersion',
      'idempotencyKey',
      'clientInstanceId',
      'source',
      'task',
      'acceptance',
      'inputs',
      'profiles',
      'budget',
      'grantDurationMs'
    });
    expect(sent['profiles'], {
      for (final r in cloudRoles) r: {'providerId': 1, 'modelRowId': 2}
    });
    expect(sent['task'], '显式本人任务');
    expect(sent['inputs'], isEmpty);
  });
  test('POST ack丢失/404保持同key未知，page switch/reopen/resume只能GET', () async {
    // 先正常初始化，再注入丢ack；无需延迟或清理替代结算。
    special = null;
    final c = client();
    await c.initialize();
    special = (req) async {
      if (req.method == 'POST') {
        throw http.ClientException('synthetic disconnected');
      }
      return response({}, 404);
    };
    final r = await c.submit(source, payload);
    expect(r.status, 'submission_unknown');
    c.dispose();
    special = null;
    final next = client();
    await next.initialize();
    await expectLater(
        next.resolve(next.receipts.single), throwsA(isA<CloudHttpFailure>()));
    await next.submit(source, payload);
    next.visible(false);
    next.visible(true);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    expect((await db.db.query(dao.tableName)).single['idempotencyKey'],
        payload.key);
  });
  test('迟到成功/迟到401在账号epoch或origin变更后丢弃，不写新会话', () async {
    final c = client();
    await c.initialize();
    final entered = Completer<void>(), gate = Completer<http.Response>();
    special = (r) async {
      entered.complete();
      return gate.future;
    };
    final reading = c.open(cloud.taskId);
    final assertion = expectLater(reading, throwsA(anything));
    await entered.future;
    ++epoch;
    auth.account = 'b';
    gate.complete(response({}, 401));
    await assertion;
    expect(c.detail, null);
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
  });
  test('review receipt 原key后来查询200同步内存回执，查询不发布且保存幂等', () async {
    final first = client();
    await first.initialize();
    special = (req) async {
      if (req.method == 'POST') {
        created = true;
        throw http.ClientException('synthetic received POST but ack lost');
      }
      return response({}, 404);
    };
    final unknown = await first.submit(source, payload);
    expect(unknown.status, 'submission_unknown');
    first.dispose();
    special = null;
    dao = await CloudWorkflowDao.create(db, accountHash: 'a');
    final next = client();
    await next.initialize();
    var notifications = 0;
    next.addListener(() => notifications++);
    final accepted = await next.resolve(next.receipts.single);
    expect(accepted.status, 'accepted');
    expect(next.receipts.single.status, 'accepted');
    expect(next.receipts.single.key, payload.key);
    expect(next.receipts.single.taskId, cloud.taskId);
    expect(next.receipts.single.publicationId, cloud.publicationId);
    expect(notifications, greaterThan(0));
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
    await next.open(cloud.taskId);
    expect(next.localReceipt?.bindingId, unknown.bindingId);
    expect(await db.db.query('tb_messages'), hasLength(1));
    await next.saveToConversation();
    await next.saveToConversation();
    expect(await db.db.query('tb_messages'), hasLength(2));
    expect(await db.db.query('tb_cloud_publications'), hasLength(1));
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
  });
  for (final invalidate in ['epoch', 'origin']) {
    test('review receipt 迟到200在$invalidate失效后不改DAO或内存', () async {
      await dao.recordSubmission(scope(),
          origin: cloudFixtureOrigin,
          ownerId: 7,
          snapshot: source,
          payload: payload);
      final c = client();
      await c.initialize();
      final entered = Completer<void>(), held = Completer<http.Response>();
      special = (req) async {
        expect(req.url.path.endsWith('/by-idempotency/${payload.key}'), true);
        entered.complete();
        return held.future;
      };
      var notifications = 0;
      c.addListener(() => notifications++);
      final resolving = c.resolve(c.receipts.single);
      final rejected = expectLater(resolving, throwsA(anything));
      await entered.future;
      if (invalidate == 'epoch') {
        ++epoch;
      } else {
        currentOrigin = 'https://changed-receipt.synthetic.invalid';
      }
      held.complete(response(cloud.receipt()));
      await rejected;
      expect(c.receipts.single.status, 'submission_unknown');
      expect((await db.db.query(dao.tableName)).single['status'],
          'submission_unknown');
      expect(notifications, 0);
      expect(await db.db.query('tb_cloud_publications'), isEmpty);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
    });
  }
  test('真实同账号重登录的迟到401不注销新身份', () async {
    final old = AgentWorkflowScope(accountHash: 'a');
    final api = CloudWorkflowApi(
        scope: old,
        origin: cloudFixtureOrigin,
        token: 'old-synthetic',
        currentOrigin: () => currentOrigin,
        client: MockClient(handle));
    final entered = Completer<void>(), gate = Completer<http.Response>();
    special = (r) async {
      entered.complete();
      return gate.future;
    };
    final reading = api.capability();
    final assertion = expectLater(reading, throwsA(anything));
    await entered.future;
    await LoginDao.saveAuthToken('new-synthetic', extras: {'accountHash': 'a'});
    gate.complete(response({}, 401));
    await assertion;
    expect(LoginDao.getAccountHash(), 'a');
    expect(old.identityCurrent, false);
    api.close();
  });
  test('origin在本地最终许可等待中变化也零publication', () async {
    final c = client();
    await c.initialize();
    await c.submit(source, payload);
    await c.open(cloud.taskId);
    final entered = Completer<void>(), release = Completer<void>();
    final holder = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          entered.complete();
          await release.future;
        });
    await entered.future;
    final saving = c.saveToConversation();
    final assertion = expectLater(saving, throwsStateError);
    currentOrigin = 'https://new-origin.invalid';
    release.complete();
    await holder;
    await assertion;
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
  });
  test('固定headers/JWT，不因await后新token补到旧请求', () async {
    final c = client();
    await c.initialize();
    expect(
        requests.every((r) =>
            r.headers['Authorization'] == 'Bearer fixed-synthetic-token'),
        true);
    currentOrigin = 'https://another.invalid';
    await expectLater(c.api.capability(), throwsStateError);
    expect(requests.length, 3);
  });
  test('最终手动保存前source改回拒绝；读成果从不自动发布', () async {
    final c = client();
    await c.initialize();
    await c.submit(source, payload);
    await c.open(cloud.taskId);
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
    await db.db.update('tb_messages', {'content': '修改'});
    await db.db.update('tb_messages', {'content': source.task});
    await expectLater(c.saveToConversation(), throwsStateError);
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
  });
  test('stop响应未知明确重试复用原op，409只刷新，不暗换revision', () async {
    final c = client();
    await c.initialize();
    await c.open(cloud.taskId);
    special = (req) async {
      if (req.method == 'POST') {
        throw http.ClientException('synthetic stop unknown');
      }
      if (req.url.path.endsWith('/result')) {
        return response([cloud.result()]);
      }
      return response(cloud.detail());
    };
    await c.stop();
    await c.stop();
    final bodies =
        requests.where((r) => r.method == 'POST').map((r) => r.body).toList();
    expect(bodies, hasLength(2));
    expect(bodies[0], bodies[1]);
    special = (req) async => req.method == 'POST'
        ? response({}, 409)
        : req.url.path.endsWith('/result')
            ? response([cloud.result()])
            : response(cloud.detail(revision: 5));
    await c.stop();
    expect(c.detail!.revision, 5);
    expect(requests.last.method, 'GET');
    expect(
        (await db.db.query('tb_cloud_stop_intents')).single['expectedRevision'],
        4);
  });
  test('乱序revision丢弃/隐藏停止poll，读取不会调用执行', () async {
    final c = client();
    await c.initialize();
    await c.open(cloud.taskId);
    c.visible(false);
    special = (req) async => response(cloud.detail(revision: 2));
    await c.refresh();
    expect(c.detail!.revision, 4);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
  test('response未知state、错误hash、超限body、redirect/error保持可辨识失败', () async {
    final c = client();
    await c.initialize();
    special = (req) async => response(cloud.detail(state: 'made_up'));
    await expectLater(c.open(cloud.taskId), throwsFormatException);
    special = (req) async => http.Response('a' * (512 * 1024 + 1), 200);
    await expectLater(c.api.capability(), throwsFormatException);
    special = (req) async => response({}, 503);
    await expectLater(
        c.api.capability(),
        throwsA(
            isA<CloudHttpFailure>().having((e) => e.status, 'status', 503)));
  });
  test('strict payload限额/Unicode/hash/输出名/未知字段不偷偷截断', () {
    expect(
        () => CloudConfirmedPayload(
            key: generateUuidV4(),
            clientInstanceId: generateUuidV4(),
            source: source.source,
            task: '另一个任务',
            inputs: [],
            profiles: {for (final r in cloudRoles) r: cloudFixtureProfile}),
        throwsFormatException);
    expect(
        () => CloudProfileChoice.fromJson({
              'providerId': 1,
              'modelRowId': 2,
              'modelId': 'm',
              'providerName': 'p',
              'modelName': 'm',
              'apiKey': '禁止'
            }),
        throwsFormatException);
    expect(
        () => CloudConfirmedPayload(
            key: generateUuidV4(),
            clientInstanceId: generateUuidV4(),
            source: source.source,
            task: source.task,
            inputs: List.filled(5, const CloudTextSnapshot('x', 'y')),
            profiles: {for (final r in cloudRoles) r: cloudFixtureProfile}),
        throwsFormatException);
    expect(() => cloudText('\ud800', 100), throwsFormatException);
    expect(utf8.encode('😀').length, 4);
    expect('😀'.runes.length, 1);
  });

  test('review list 实际空页合同可初始化且保留cursor', () async {
    final c = client();
    await c.initialize();
    expect(c.tasks, isEmpty);
    final dynamic page = await c.api.list();
    expect(page.items, isEmpty);
    expect(page.nextCursor, isNull);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('review list 大合法payload小页与显式下一页，不自动拉完', () async {
    final task = '汉' * 4000;
    final large = CloudConfirmedPayload(
        key: generateUuidV4(),
        clientInstanceId: generateUuidV4(),
        source: CloudLocalSource(1, generateUuidV4(), 1, cloudHash(task)),
        task: task,
        inputs: [CloudTextSnapshot('一', task), CloudTextSnapshot('二', task)],
        profiles: {for (final r in cloudRoles) r: cloudFixtureProfile});
    final rows = List.generate(
        4,
        (_) => {
              ...cloud.detail()['parent'] as Map<String, dynamic>,
              'id': generateUuidV4(),
              'payload': large.toJson(),
              'payload_hash': large.digest
            });
    final cursor = rows.last['id'];
    special = (req) async {
      expect(req.url.queryParameters['limit'], '4');
      if (req.url.queryParameters['cursor'] == cursor) {
        return response({'items': [], 'nextCursor': null});
      }
      return response({'items': rows, 'nextCursor': cursor});
    };
    final c = reviewClient();
    final dynamic page = await c.api.list();
    expect(page.items, hasLength(4));
    expect(page.nextCursor, cursor);
    expect(utf8.encode(jsonEncode(rows)).length, greaterThan(140000));
    expect(requests, hasLength(1));
    final dynamic controller = c;
    c.tasks = List<Map<String, dynamic>>.from(page.items);
    controller.nextCursor = page.nextCursor;
    await controller.loadNextPage();
    expect(c.tasks, hasLength(4));
    expect(controller.nextCursor, isNull);
    expect(requests, hasLength(2));
  });

  test('review list 非合同形状与超页及cursor不匹配拒绝', () async {
    final c = reviewClient();
    for (final bad in [
      [],
      {'items': [], 'nextCursor': 'wrong'},
      {'items': [], 'nextCursor': generateUuidV4()},
      {'items': [], 'nextCursor': null, 'future': true},
      {
        'items': List.generate(5, (_) => cloud.detail()['parent']),
        'nextCursor': null
      }
    ]) {
      special = (_) async => response(bad);
      await expectLater(c.api.list(), throwsFormatException);
    }
  });

  for (final count in [6, 7, 8]) {
    test('review results 合法$count历史成果只发布final writing', () async {
      final c = reviewClient();
      await c.submit(source, payload);
      final history = List.generate(
          count - 1,
          (i) => {
                ...cloud.result(),
                'id': generateUuidV4(),
                'step_id': cloud.steps[i == 0 ? 'writing' : 'review'],
                'version': i + 2,
                'content': '历史结果$i',
                'content_hash': cloudHash('历史结果$i')
              });
      special = (req) async => req.url.path.endsWith('/result')
          ? response([...history, cloud.result()])
          : response(cloud.detail());
      await c.open(cloud.taskId);
      expect(c.results, hasLength(count));
      expect(c.finalResult!.resultId, cloud.resultId);
      expect(
          () => c.results.first.verifyFinal(c.detail!), throwsFormatException);
      await c.saveToConversation();
      expect((await db.db.query('tb_cloud_publications')).single['resultId'],
          cloud.resultId);
      expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    });
  }
  test('review results 超过8次硬合同仍拒绝', () async {
    final c = reviewClient();
    special = (_) async => response(List.generate(9, (_) => cloud.result()));
    await expectLater(c.api.results(cloud.taskId), throwsFormatException);
  });

  for (final field in ['acceptance', 'profile', 'budget', 'binding']) {
    test('review submit 同key改$field并发与完成后均拒绝且零追加POST', () async {
      final c = reviewClient();
      final entered = Completer<void>(), gate = Completer<void>();
      special = (req) async {
        if (req.method == 'POST') {
          entered.complete();
          await gate.future;
          return response({});
        }
        return response(cloud.receipt());
      };
      final sending = c.submit(source, payload);
      await entered.future;
      final otherSource = field == 'binding'
          ? CloudSourceSnapshot(
              generateUuidV4(), source.task, source.source, source.inputs)
          : source;
      final other = field == 'binding' ? payload : changedPayload(field);
      // 保证红断言失败时也能释放合成HTTP；不以清理代替最终判定。
      Object? rejected;
      try {
        c.submit(otherSource, other);
      } catch (e) {
        rejected = e;
      }
      gate.complete();
      await sending;
      expect(rejected, isA<StateError>());
      expect(() => c.submit(otherSource, other), throwsStateError);
      expect(identical(c.submit(source, payload), sending), true);
      expect(requests.where((r) => r.method == 'POST'), hasLength(1));
      expect(await db.db.query(dao.tableName), hasLength(1));
    });
  }

  for (final invalidate in ['epoch', 'origin']) {
    testWidgets('review timer $invalidate变化无Zone异常无新请求无续排', (tester) async {
      final c = reviewClient();
      special = (_) async => response(cloud.detail(state: 'running'));
      await tester.runAsync(() => c.open(cloud.taskId));
      c.visible(false);
      c.visible(true);
      await tester.pump();
      final count = requests.length;
      if (invalidate == 'epoch') {
        ++epoch;
      } else {
        currentOrigin = 'https://changed.invalid';
      }
      await tester.pump(const Duration(seconds: 20));
      expect(tester.takeException(), isNull);
      expect(requests.length, count);
      await tester.pump(const Duration(seconds: 40));
      expect(tester.takeException(), isNull);
      expect(requests.length, count);
      c.dispose();
    });
  }
  testWidgets('review timer 在途GET后origin变化再失败不notify/续排', (tester) async {
    final c = reviewClient();
    special = (_) async => response(cloud.detail(state: 'running'));
    await tester.runAsync(() => c.open(cloud.taskId));
    c.visible(false);
    final gate = Completer<http.Response>();
    special = (_) => gate.future;
    var notifications = 0;
    c.addListener(() => notifications++);
    c.visible(true);
    await tester.pump();
    final count = requests.length;
    currentOrigin = 'https://changed.invalid';
    gate.completeError(http.ClientException('synthetic held failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(notifications, 0);
    await tester.pump(const Duration(seconds: 60));
    expect(tester.takeException(), isNull);
    expect(requests.length, count);
    c.dispose();
  });

  for (final status in [200, 409]) {
    test('review stop A迟到$status在B详情不污染UI也不刷新B', () async {
      final c = reviewClient();
      await c.open(cloud.taskId);
      final b = CloudFixtureResult(payload);
      final entered = Completer<void>(), gate = Completer<http.Response>();
      special = (req) async {
        if (req.method == 'POST') {
          entered.complete();
          return gate.future;
        }
        if (req.url.path.endsWith('/result')) return response([b.result()]);
        return response(b.detail());
      };
      final stopping = c.stop();
      await entered.future;
      await c.open(b.taskId);
      c.notice = 'B独立观察';
      c.stopNeedsNewIntent = false;
      final bRequests =
          requests.where((r) => r.url.path.contains(b.taskId)).length;
      gate.complete(response({}, status));
      await stopping;
      expect(c.detail!.taskId, b.taskId);
      expect(c.notice, 'B独立观察');
      expect(c.stopNeedsNewIntent, false);
      expect(requests.where((r) => r.url.path.contains(b.taskId)),
          hasLength(bRequests));
      expect((await db.db.query('tb_cloud_stop_intents')).single['status'],
          status == 409 ? 'conflict' : 'acknowledged');
      expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    });
  }
}
