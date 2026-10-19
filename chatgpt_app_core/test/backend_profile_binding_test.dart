import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/application/legacy_backend_profile_binding.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final databases = <Database>[];
  final resources = <Map<String, Object?>>[];
  late Directory root;
  late String account, origin;
  late int epoch, restore, clock;
  late bool identity, permit;
  int gets = 0;
  final network = _NoNetwork();
  AgentWorkflowScope lifecycle() => AgentWorkflowScope(
      accountHash: 'account-a',
      currentAccount: () => account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => restore,
      stableOperation: (action) async {
        expect(permit, isFalse);
        permit = true;
        try {
          await action();
        } finally {
          permit = false;
        }
      });
  BackendSelectionBindingScope scope() =>
      BackendSelectionBindingScope.test(lifecycle(),
          origin: origin,
          currentOrigin: () => origin,
          identityCurrent: () => identity);
  BackendSelection pair(String model, [String provider = 'a']) =>
      BackendSelection.pair(
          providerCode: provider,
          modelId: model,
          accountHash: 'account-a',
          origin: 'http://127.0.0.1:39991');
  Future<BackendSelection> probe(
      BackendSelectionBindingScope s, String model) async {
    expect(permit, isFalse);
    s.verify();
    gets++;
    return pair(model);
  }

  setUpAll(() {
    sqfliteFfiInit();
    final nonce = Platform.environment['R2C_SQLITE_NONCE']!;
    root = Directory(Platform.environment['R2C_SQLITE_ROOT']!);
    expect(root.path, '/tmp/chatai-r2c-sqlite-$nonce');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    HttpOverrides.global = network;
  });
  setUp(() {
    account = 'account-a';
    origin = 'http://127.0.0.1:39991';
    epoch = 1;
    restore = 0;
    clock = 1000;
    identity = true;
    permit = false;
    gets = 0;
  });
  tearDownAll(() async {
    for (final db in databases) {
      if (db.isOpen) await db.close();
    }
    for (final r in resources) {
      r['closed'] = true;
    }
    expect(network.calls, 0);
    HttpOverrides.global = null;
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'databases': resources,
      'sutHttpClientCalls': network.calls,
      'httpEvidence':
          'MockClient GET only; no real HTTP/JWT verification; lifecycle mutations injected',
    }));
  });
  Future<HiDBManager> open({Database Function(Database)? wrap}) async {
    final path = '${root.path}/binding-${databases.length}.db';
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    databases.add(db);
    resources.add({'path': path, 'closed': false});
    await db.execute('PRAGMA foreign_keys=ON');
    return HiDBManager.test(wrap?.call(db) ?? db);
  }

  Map<String, dynamic> oldProfile() => {
        'version': 1,
        'mode': 'backend',
        'providerId': null,
        'modelId': 'same',
        'reasoningPolicy': 'offIfSupported',
        'reasoningControlSuppressed': false
      };
  Future<(StoryTemplateTranslationTaskDao, StoryTemplateTranslationTaskModel)>
      translation({HiDBManager? storage}) async {
    final dao = await StoryTemplateTranslationTaskDao.create(
        storage ?? await open(),
        accountHash: 'account-a');
    final t = StoryTemplateTranslationTaskModel(
        sourceTitle: 'fixture',
        sourcePayload: '{}',
        requestProfile: jsonEncode(oldProfile()),
        checkpointVersion: 1,
        roleTotal: 4,
        fieldTotal: 6,
        log: '已创建中文副本任务',
        createdAt: 1000,
        updatedAt: 1000);
    await dao.saveTask(t);
    await dao.storage.db.update(dao.tableName, {'updatedAt': 1000},
        where: 'id=?', whereArgs: [t.id]);
    t.updatedAt = 1000;
    return (dao, t);
  }

  Future<(AgentWorkflowDao, AgentWorkflow)> workflow(
      {HiDBManager? storage}) async {
    final db = storage ?? await open();
    await (await ConversationListDao.create(db)).saveConversation(
        ConversationModel(cid: 1, title: 'fixture', icon: ''));
    final user = await (await MessageDao.create(db, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: 'synthetic source',
            ownerType: OwnerType.sender,
            createdAt: 123));
    final dao = await AgentWorkflowDao.create(db,
        accountHash: 'account-a', now: () => clock);
    final parent = await dao.createFromSource(lifecycle(),
        cid: 1,
        userRowId: user,
        profiles: {
          for (final role in WorkflowRole.values)
            role: const WorkflowModelProfile('backend', 'backend', 'same')
        },
        acceptance: const TaskAcceptanceCriteria(requireFullRead: false));
    return (dao, parent);
  }

  Future<StoryTemplateTranslationTaskDao> secondConnection(
      StoryTemplateTranslationTaskDao original) async {
    final path = original.storage.db.path;
    expect(path, startsWith('${root.path}/'));
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    databases.add(db);
    resources.add({'path': path, 'reopen': true, 'closed': false});
    return StoryTemplateTranslationTaskDao.create(HiDBManager.test(db));
  }

  Future<String> workflowRows(AgentWorkflowDao dao) async => jsonEncode([
        for (final table in [
          AgentWorkflowDao.workflows,
          AgentWorkflowDao.stepTable,
          AgentWorkflowDao.attempts,
          AgentWorkflowDao.publications,
          AgentWorkflowDao.outputPublications
        ])
          await dao.storage.db.query(table),
      ]);

  test(
      'workflow probes all steps outside permit then one transaction fixes whole parent',
      () async {
    final (dao, w) = await workflow();
    final old = await dao.steps(w.id);
    final bound = await LegacyBackendProfileBinding(probe: probe)
        .workflow(dao, scope(), w.id);
    expect(gets, 3);
    expect(bound.revision, w.revision + 1);
    expect(bound.toRow()['updatedAt'], 1001);
    final steps = await dao.steps(w.id);
    for (var i = 0; i < 3; i++) {
      expect(steps[i].profile.backendSelection?.toSafeJson(),
          pair('same').toSafeJson());
      expect(steps[i].revision, old[i].revision + 1);
      expect(steps[i].toRow()['inputHash'], isNull);
      expect(steps[i].checkpoint, isNull);
      expect(steps[i].result, '');
    }
    expect(await dao.attemptHistory(w.id), isEmpty);
    await expectLater(dao.claim(lifecycle(), w.id, bound.revision),
        throwsA(isA<WorkflowStale>()));
    expect((await dao.read(w.id))!.dispatches, 0);
  });
  test(
      'one workflow probe fails: zero parent/step writes and no partial binding',
      () async {
    final (dao, w) = await workflow();
    final before = await workflowRows(dao);
    var n = 0;
    await expectLater(
        LegacyBackendProfileBinding(probe: (s, m) async {
          expect(permit, isFalse);
          if (++n == 2) {
            throw const BackendSelectionProbeFailure('catalogForbidden');
          }
          return pair(m);
        }).workflow(dao, scope(), w.id),
        throwsA(isA<BackendSelectionProbeFailure>()));
    expect(await workflowRows(dao), before);
  });
  test('mismatched workflow DAO account rejects before probe', () async {
    final (dao, w) = await workflow();
    final before = await workflowRows(dao);
    final other = await AgentWorkflowDao.create(dao.storage,
        accountHash: 'account-b', now: () => clock);
    await expectLater(
        LegacyBackendProfileBinding(probe: probe)
            .workflow(other, scope(), w.id),
        throwsA(isA<WorkflowStale>()));
    expect(gets, 0);
    expect(await workflowRows(dao), before);
  });
  for (final field in [
    'dispatches',
    'reservedTokens',
    'reworks',
    'leaseId',
    'deadlineAt'
  ]) {
    test('workflow parent $field evidence refuses before GET', () async {
      final (dao, w) = await workflow();
      await dao.storage.db.update(AgentWorkflowDao.workflows,
          {field: field == 'leaseId' ? 'old-lease' : 1},
          where: 'parentId=?', whereArgs: [w.id]);
      final before = await workflowRows(dao);
      await expectLater(
          LegacyBackendProfileBinding(probe: probe)
              .workflow(dao, scope(), w.id),
          throwsA(isA<WorkflowStale>()));
      expect(gets, 0);
      expect(await workflowRows(dao), before);
    });
  }
  for (final field in [
    'inputHash',
    'checkpoint',
    'result',
    'resultHash',
    'cycles'
  ]) {
    test('workflow step $field evidence refuses unchanged', () async {
      final (dao, w) = await workflow();
      await dao.storage.db.update(AgentWorkflowDao.stepTable,
          {field: field == 'cycles' ? 1 : 'historical'},
          where: 'parentId=?', whereArgs: [w.id]);
      final before = await workflowRows(dao);
      await expectLater(
          LegacyBackendProfileBinding(probe: probe)
              .workflow(dao, scope(), w.id),
          throwsA(isA<WorkflowStale>()));
      expect(gets, 0);
      expect(await workflowRows(dao), before);
    });
  }
  test('workflow any attempt history refuses even if counters were zero',
      () async {
    final (dao, w) = await workflow();
    final step = (await dao.steps(w.id)).first;
    await dao.storage.db.insert(AgentWorkflowDao.attempts, {
      'attemptId': 'history',
      'parentId': w.id,
      'stepId': step.id,
      'leaseId': 'old',
      'state': 'unknown',
      'inputHash': workflowHash('old'),
      'estimatedInput': 1,
      'reservedOutput': 1,
      'createdAt': 1
    });
    final before = await workflowRows(dao);
    await expectLater(
        LegacyBackendProfileBinding(probe: probe).workflow(dao, scope(), w.id),
        throwsA(isA<WorkflowStale>()));
    expect(gets, 0);
    expect(await workflowRows(dao), before);
  });
  for (final change in [
    'source',
    'profile',
    'claim',
    'epoch',
    'restore',
    'origin',
    'token',
    'account'
  ]) {
    test('workflow change during GET $change refuses entire binding', () async {
      final (dao, w) = await workflow();
      var once = false;
      String? after;
      await expectLater(
          LegacyBackendProfileBinding(probe: (s, m) async {
            expect(permit, isFalse);
            if (!once) {
              once = true;
              switch (change) {
                case 'source':
                  await dao.storage.db
                      .update('tb_messages', {'content': 'changed'});
                case 'profile':
                  await dao.storage.db.update(
                      AgentWorkflowDao.stepTable,
                      {
                        'profile': jsonEncode(const WorkflowModelProfile(
                                'backend', 'backend', 'other')
                            .toJson())
                      },
                      where: 'stepId=?',
                      whereArgs: [(await dao.steps(w.id)).first.id]);
                case 'claim':
                  await dao.claim(lifecycle(), w.id, w.revision);
                case 'epoch':
                  epoch++;
                case 'restore':
                  restore++;
                case 'origin':
                  origin = 'http://127.0.0.1:39992';
                case 'token':
                  identity = false;
                case 'account':
                  account = 'account-b';
              }
              after = await workflowRows(dao);
            }
            return pair(m);
          }).workflow(dao, scope(), w.id),
          throwsA(isA<WorkflowStale>()));
      expect(await workflowRows(dao), after);
    });
  }
  test('workflow partial resolved set rejected without writes', () async {
    final (dao, w) = await workflow();
    final steps = await dao.steps(w.id);
    final before = await workflowRows(dao);
    await expectLater(
        dao.bindLegacyBackendProfiles(scope(),
            expected: w,
            expectedSteps: steps,
            resolved: {steps.first.id: pair('same')}),
        throwsA(isA<WorkflowStale>()));
    expect(await workflowRows(dao), before);
  });
  test('modern running step is refused before reserve attempt metadata',
      () async {
    final (dao, w) = await workflow();
    final first = (await dao.steps(w.id)).first;
    final claimed = await dao.claim(lifecycle(), w.id, w.revision);
    final begun = await dao.beginStep(
        lifecycle(), WorkflowFence.of(claimed), first.id,
        inputHash: workflowHash('synthetic'));
    await dao.storage.db.update(
        AgentWorkflowDao.stepTable,
        {
          'profile':
              jsonEncode(WorkflowModelProfile.backend(pair('same')).toJson())
        },
        where: 'stepId=?',
        whereArgs: [first.id]);
    final before = await workflowRows(dao);
    await expectLater(
        dao.reserveDispatch(lifecycle(), WorkflowFence.of(begun), first.id,
            inputHash: workflowHash('synthetic'), estimatedInput: 1),
        throwsA(isA<WorkflowStale>()));
    expect(await workflowRows(dao), before);
  });
  test('workflow actual constraint failure rolls back all step rewrites',
      () async {
    final (dao, w) = await workflow();
    final before = await workflowRows(dao);
    await dao.storage.db.execute(
        "CREATE TRIGGER block_binding BEFORE UPDATE ON ${AgentWorkflowDao.workflows} BEGIN SELECT RAISE(ABORT,'synthetic constraint'); END");
    await expectLater(
        LegacyBackendProfileBinding(probe: probe).workflow(dao, scope(), w.id),
        throwsA(isA<DatabaseException>()));
    expect(await workflowRows(dao), before);
  });
  test(
      'translation binding keeps plan metadata and increments version at fixed/backward clock',
      () async {
    final (dao, t) = await translation();
    final bound = await LegacyBackendProfileBinding(probe: probe).translation(
        dao, scope(), t.id!,
        now: DateTime.fromMillisecondsSinceEpoch(1000));
    expect(bound.updatedAt, 1001);
    expect(bound.roleTotal, 4);
    expect(bound.fieldTotal, 6);
    expect(bound.checkpointVersion, 1);
    expect(jsonDecode(bound.requestProfile)['backendSelection'],
        pair('same').toSafeJson());
    final before = (await dao.backendBindingSnapshot(t.id!))!;
    final other = await secondConnection(dao);
    expect(
        await other.claimTask(t.id!,
            leaseOwner: 'plain', leaseDuration: const Duration(seconds: 5)),
        isFalse);
    expect(
        await other.claimTask(t.id!,
            leaseOwner: 'old',
            leaseDuration: const Duration(seconds: 5),
            expectedUpdatedAt: 1000,
            now: DateTime.fromMillisecondsSinceEpoch(1000)),
        isFalse);
    expect(await dao.backendBindingSnapshot(t.id!), before);
    expect(
        await other.claimTask(t.id!,
            leaseOwner: 'current',
            leaseDuration: const Duration(seconds: 5),
            expectedUpdatedAt: 1001,
            now: DateTime.fromMillisecondsSinceEpoch(999)),
        isTrue);
    final claimed = (await dao.getTask(t.id!))!;
    expect(claimed.updatedAt, 1002);
    expect(claimed.attempts, 1);
    expect(claimed.requestProfile, bound.requestProfile);
  });
  test(
      'legacy claim wins while translation GET waits: binding fails, no profile rewrite',
      () async {
    final (dao, t) = await translation();
    final entered = Completer<void>();
    final returned = Completer<BackendSelection>();
    final binding = LegacyBackendProfileBinding(probe: (s, m) {
      expect(permit, isFalse);
      entered.complete();
      return returned.future;
    }).translation(dao, scope(), t.id!);
    final failure = expectLater(binding, throwsA(isA<WorkflowStale>()));
    await entered.future;
    final other = await secondConnection(dao);
    expect(
        await other.claimTask(t.id!,
            leaseOwner: 'first',
            leaseDuration: const Duration(seconds: 5),
            now: DateTime.fromMillisecondsSinceEpoch(1000)),
        isTrue);
    final after = await dao.backendBindingSnapshot(t.id!);
    returned.complete(pair('same'));
    await failure;
    expect(await dao.backendBindingSnapshot(t.id!), after);
    expect(jsonDecode(after!['requestProfile'] as String)['version'], 1);
  });
  for (final update in <String, Map<String, Object?>>{
    'attempt': {'attempts': 1},
    'expired lease': {'leaseOwner': 'old', 'leaseUntil': 1},
    'partial': {'partialPayload': '{}'},
    'field': {'fieldPayload': '{}'},
    'chunk': {'chunkPayload': '{}'},
    'output': {'outputTemplateId': 71},
    'error': {'error': 'old failure'},
    'index': {'roleIndex': 1},
    'progress': {'progress': 0.1},
    'retry': {'log': '用户请求重试'},
    'recovered': {'status': 'retryable'},
  }.entries) {
    test('translation ${update.key} evidence refuses without probe/write',
        () async {
      final (dao, t) = await translation();
      await dao.storage.db.update(dao.tableName, update.value,
          where: 'id=?', whereArgs: [t.id]);
      final before = await dao.backendBindingSnapshot(t.id!);
      await expectLater(
          LegacyBackendProfileBinding(probe: probe)
              .translation(dao, scope(), t.id!),
          throwsA(isA<WorkflowStale>()));
      expect(gets, 0);
      expect(await dao.backendBindingSnapshot(t.id!), before);
    });
  }
  test(
      'translation profile/source mutation while probe waits does not overwrite',
      () async {
    final (dao, t) = await translation();
    Map<String, Object?>? after;
    await expectLater(
        LegacyBackendProfileBinding(probe: (s, m) async {
          await dao.storage.db.update(
              dao.tableName, {'sourcePayload': 'changed'},
              where: 'id=?', whereArgs: [t.id]);
          after = await dao.backendBindingSnapshot(t.id!);
          return pair(m);
        }).translation(dao, scope(), t.id!),
        throwsA(isA<WorkflowStale>()));
    expect(await dao.backendBindingSnapshot(t.id!), after);
  });
  test('scope change after final async row read rolls back binding', () async {
    late _HookDatabase wrapper;
    final storage = await open(wrap: (db) => wrapper = _HookDatabase(db));
    final (dao, t) = await translation(storage: storage);
    final before = await dao.backendBindingSnapshot(t.id!);
    wrapper.hook = () => origin = 'http://127.0.0.1:39992';
    await expectLater(
        LegacyBackendProfileBinding(probe: probe)
            .translation(dao, scope(), t.id!),
        throwsA(isA<WorkflowStale>()));
    expect(await dao.backendBindingSnapshot(t.id!), before);
  });
  test(
      'workflow origin change after final async row read rolls back every profile',
      () async {
    late _HookDatabase wrapper;
    final storage = await open(wrap: (db) => wrapper = _HookDatabase(db));
    final (dao, w) = await workflow(storage: storage);
    final before = await workflowRows(dao);
    wrapper.hook = () => origin = 'http://127.0.0.1:39992';
    await expectLater(
        LegacyBackendProfileBinding(probe: probe).workflow(dao, scope(), w.id),
        throwsA(isA<WorkflowStale>()));
    expect(await workflowRows(dao), before);
  });
  test('probe wrong model or foreign scope cannot bind translation', () async {
    final (dao, t) = await translation();
    final before = await dao.backendBindingSnapshot(t.id!);
    for (final bad in [
      pair('other'),
      BackendSelection.pair(
          providerCode: 'a',
          modelId: 'same',
          accountHash: 'account-b',
          origin: origin)
    ]) {
      await expectLater(
          LegacyBackendProfileBinding(probe: (s, m) async => bad)
              .translation(dao, scope(), t.id!),
          throwsA(isA<WorkflowStale>()));
      expect(await dao.backendBindingSnapshot(t.id!), before);
    }
  });
  test(
      'injected failure before SQLite COMMIT preserves profile/version and zero send',
      () async {
    late _HookDatabase wrapper;
    final storage = await open(wrap: (db) => wrapper = _HookDatabase(db));
    final (dao, t) = await translation(storage: storage);
    final before = await dao.backendBindingSnapshot(t.id!);
    wrapper.beforeCommit =
        () => throw StateError('synthetic failure before COMMIT');
    await expectLater(
        LegacyBackendProfileBinding(probe: probe)
            .translation(dao, scope(), t.id!),
        throwsStateError);
    expect(await dao.backendBindingSnapshot(t.id!), before);
  });
  test(
      'MockClient R1 GET uses original model/origin and synthetic JWT; zero POST',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'providerCode': 'a', 'modelId': ' same/model '}
          }),
          200);
    });
    final resolved = await BackendSelectionProbeClient(
            client: client,
            headers: () => {'Authorization': 'Bearer synthetic'})
        .resolve(scope(), ' same/model ');
    expect(resolved.modelId, ' same/model ');
    expect(requests.single.method, 'GET');
    expect(requests.single.url.origin, origin);
    expect(requests.single.url.path, '/uapi/ai/model-selection');
    expect(requests.single.url.queryParameters, {'modelId': ' same/model '});
    expect(requests.single.headers['Authorization'], 'Bearer synthetic');
    client.close();
  });
  for (final code in [401, 403, 409, 500]) {
    // MockClient 是合成 GET，不是真实后端/JWT 验证。
    test('probe status $code safe failure never writes/echoes response',
        () async {
      final (dao, t) = await translation();
      final before = await dao.backendBindingSnapshot(t.id!);
      var n = 0;
      final client = MockClient((r) async {
        n++;
        expect(r.method, 'GET');
        return http.Response(
            '{"safeCode":"model_ambiguous","token":"synthetic-secret","message":"SQL synthetic"}',
            code);
      });
      final api =
          BackendSelectionProbeClient(client: client, headers: () => {});
      try {
        await LegacyBackendProfileBinding(probe: api.resolve)
            .translation(dao, scope(), t.id!);
        fail('must refuse');
      } on BackendSelectionProbeFailure catch (e) {
        expect(e.toString(), isNot(contains('synthetic-secret')));
        expect(e.toString(), isNot(contains('SQL')));
      }
      expect(n, 1);
      expect(await dao.backendBindingSnapshot(t.id!), before);
      client.close();
    });
  }
  test('scope switch in header callback refuses before GET', () async {
    var n = 0;
    final client = MockClient((r) async {
      n++;
      return http.Response('{}', 200);
    });
    await expectLater(
        BackendSelectionProbeClient(
            client: client,
            headers: () {
              epoch++;
              return {};
            }).resolve(scope(), 'same'),
        throwsA(isA<WorkflowStale>()));
    expect(n, 0);
    client.close();
  });
  test('controlled 5ms timeout of injected GET gives zero binding writes',
      () async {
    final (dao, t) = await translation();
    final before = await dao.backendBindingSnapshot(t.id!);
    await expectLater(
        LegacyBackendProfileBinding(
                probe: (s, m) => Completer<BackendSelection>().future,
                probeTimeout: const Duration(milliseconds: 5))
            .translation(dao, scope(), t.id!),
        throwsA(isA<BackendSelectionProbeFailure>()));
    expect(await dao.backendBindingSnapshot(t.id!), before);
  });
  test(
      'production scope captures same original account/token and rejects changed token',
      () async {
    final oldHost = BackendConfig.host, oldHttps = BackendConfig.useHttps;
    LoginDao.resetHooksForTest();
    final auth = _Account('account-a')..install();
    BackendConfig.host = '127.0.0.1:39991';
    BackendConfig.useHttps = false;
    try {
      final captured = BackendSelectionBindingScope.capture(lifecycle());
      captured.verify();
      auth.token = 'synthetic-new';
      expect(captured.verify, throwsA(isA<WorkflowStale>()));
      account = 'account-b';
      expect(() => BackendSelectionBindingScope.capture(lifecycle()),
          throwsA(isA<WorkflowStale>()));
    } finally {
      BackendConfig.host = oldHost;
      BackendConfig.useHttps = oldHttps;
      LoginDao.resetHooksForTest();
    }
  });
}

class _Account extends PersonalMemoryTestAccount {
  String token = 'synthetic-old';
  _Account(super.account);
  @override
  String? readTokenSync() => token;
}

class _NoNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('SUT real HTTP forbidden');
  }
}

class _HookDatabase implements Database {
  final Database inner;
  void Function()? hook;
  void Function()? beforeCommit;
  _HookDatabase(this.inner);
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
          {bool? exclusive}) =>
      inner.transaction((tx) async {
        final result = await action(_HookTransaction(tx, () {
          final f = hook;
          hook = null;
          f?.call();
        }));
        beforeCommit?.call();
        return result;
      }, exclusive: exclusive);
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      inner.execute(sql, arguments);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      inner.rawUpdate(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      inner.rawQuery(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      inner.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      inner.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      inner.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HookTransaction implements Transaction {
  final Transaction inner;
  final void Function() hook;
  bool written = false;
  _HookTransaction(this.inner, this.hook);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      inner.rawQuery(sql, arguments);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      inner.rawUpdate(sql, arguments);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      inner.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    final rows = await inner.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    if (written) hook();
    return rows;
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    final n = await inner.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
    written = true;
    return n;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
