import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/application/legacy_backend_profile_binding.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'support/workflow_backend_consumer_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkflowBackendFixture f;
  final evidence = <Map<String, Object?>>[];
  setUp(() async {
    f = WorkflowBackendFixture('consumer');
    await f.setup();
  });
  tearDown(() async {
    await f.close();
    evidence.add(f.evidence());
  });
  tearDownAll(() {
    final root = Platform.environment['R3B4_ROOT']!;
    File('$root/consumer-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('$root/cleanup.json').writeAsStringSync(jsonEncode({
      'cases': evidence.length,
      'sqliteClosed': evidence.every((e) => e['sqlClosed'] == true),
      'syntheticHTTPOnly': true
    }));
  });
  test(
      'actual coordinator three same-model pairs -> role results, budget and costs',
      () async => f.synthetic(() async {
            final w = await f.create();
            await f.coordinator.start(f.dao, f.scope(), w);
            final current = (await f.dao.read(w.id))!;
            expect(current.state, WorkflowState.complete);
            expect(f.posts.map((p) => p['providerCode']), ['A', 'B', 'C']);
            expect(f.posts.every((p) => p['model'] == 'same'), true);
            expect(f.factoryPairs, ['A', 'B', 'C']);
            expect(f.resolverGets, 0);
            expect(current.dispatches, 3);
            final nodes = await f.dao.steps(w.id);
            final attempts = await f.dao.attemptHistory(w.id);
            expect(attempts.length, 3);
            expect(current.actualInputTokens, 30);
            expect(current.actualOutputTokens, 15);
            var cost = 0.0;
            for (final step in nodes) {
              expect(
                  step.profile.providerCode, ['A', 'B', 'C'][step.role.index]);
              final a = attempts.singleWhere((a) => a['stepId'] == step.id);
              expect(a['state'], 'succeeded');
              final rate = f.settings.usageCostConfig.rateFor(
                  providerId: 'backend:${jsonEncode([
                        step.profile.backendSelection!.origin,
                        step.profile.providerCode
                      ])}',
                  modelId: 'same',
                  at: DateTime.now());
              final estimate =
                  rate.costFor(promptTokens: 10, completionTokens: 5);
              expect(a['estimatedCost'], estimate);
              cost += estimate;
              if (step.role != WorkflowRole.review) {
                expect(step.result,
                    '${step.role.name}:${step.profile.providerCode}');
              }
            }
            expect(current.estimatedCost, closeTo(cost, 0.0000001));
            expect(current.reservedTokens,
                greaterThanOrEqualTo(3 * WorkflowBudget.outputTokens));
            expect(
                (await f.storage.db.query(AgentWorkflowDao.publications))
                    .length,
                1);
          }));
  test(
      'global switch during first response never replaces later role pairs',
      () async => f.synthetic(() async {
            f.switchGlobal = true;
            final w = await f.create();
            await f.coordinator.start(f.dao, f.scope(), w);
            expect((await f.dao.read(w.id))!.state, WorkflowState.complete);
            expect(f.settings.backendSelection!.providerCode, 'C');
            expect(f.posts.map((p) => p['providerCode']), ['A', 'B', 'C']);
            expect(f.creates, 3);
          }));
  test(
      'writing/review rework retains each fixed pair and shared transport',
      () async => f.synthetic(() async {
            f.revise = true;
            final w = await f.create();
            await f.coordinator.start(f.dao, f.scope(), w);
            expect((await f.dao.read(w.id))!.state, WorkflowState.complete);
            expect(f.posts.map((p) => p['providerCode']),
                ['A', 'B', 'C', 'B', 'C']);
            expect(f.creates, 3);
            expect((await f.dao.read(w.id))!.dispatches, 5);
          }));
  test(
      'tool rounds use only A capability/pair, B/C do not borrow tool bit',
      () async => f.synthetic(() async {
            f.tools = true;
            await ModelCatalog.refreshFromBackend();
            final w = await f.create(granted: {'list_files'});
            await f.coordinator.start(f.dao, f.scope(), w);
            expect((await f.dao.read(w.id))!.state, WorkflowState.complete);
            expect(f.posts.map((p) => p['providerCode']), ['A', 'A', 'B', 'C']);
            expect(f.streamRequests.where((stream) => stream).length, 2);
            expect(
                (f.posts[1]['messages'] as List)
                    .where((m) => m['role'] == 'tool')
                    .single['tool_call_id'],
                'synthetic-list');
            expect((await f.dao.read(w.id))!.dispatches, 4);
          }));
  test(
      'three-role budget max2 blocks review before POST, no refund or replacement',
      () async => f.synthetic(() async {
            final w =
                await f.create(budget: const WorkflowBudget(maxDispatches: 2));
            await f.coordinator.start(f.dao, f.scope(), w);
            expect(f.posts.map((p) => p['providerCode']), ['A', 'B']);
            final current = (await f.dao.read(w.id))!;
            expect(current.state, WorkflowState.budgetExhausted);
            expect(current.dispatches, 2);
            expect((await f.dao.attemptHistory(w.id)).length, 2);
            expect((await f.dao.steps(w.id)).last.profile.providerCode, 'C');
          }));
  for (final change in [
    'account',
    'token',
    'epoch',
    'origin',
    'restore',
    'cancel'
  ]) {
    test(
        'whole-parent preparation $change after await has zero claim/POST',
        () async => f.synthetic(() async {
              f.gateLoad = 2;
              f.loadGate = Completer();
              f.loadEntered = Completer();
              final w = await f.create();
              final run = f.coordinator.start(f.dao, f.scope(), w);
              final reached = await Future.any<bool>([
                f.loadEntered!.future.then((_) => true),
                run.then((_) => false)
              ]);
              expect(reached, true,
                  reason:
                      'actual second-role preparation entered before claim');
              switch (change) {
                case 'account':
                  f.tokens.account = 'account-b';
                case 'token':
                  f.tokens.token = 'changed';
                case 'epoch':
                  f.epoch++;
                case 'origin':
                  BackendConfig.host = 'changed.synthetic.invalid';
                case 'restore':
                  BackupService.agentExecutionRevision++;
                case 'cancel':
                  f.latestModels!.scope.cancel();
              }
              f.loadGate!.complete();
              await run;
              expect(f.posts, isEmpty);
              expect(f.resolverGets, 0);
              expect((await f.dao.read(w.id))!.toRow(), w.toRow());
              expect(await f.dao.attemptHistory(w.id), isEmpty);
            }));
  }
  test(
      'current success-empty catalog denies all before first claim',
      () async => f.synthetic(() async {
            f.emptyCatalog = true;
            await ModelCatalog.refreshFromBackend();
            final w = await f.create();
            await f.coordinator.start(f.dao, f.scope(), w);
            expect(f.posts, isEmpty);
            expect((await f.dao.read(w.id))!.toRow(), w.toRow());
          }));
  for (final change in ['account', 'token', 'origin', 'restore']) {
    test(
        'late $change response cannot save result or dispatch next role',
        () async => f.synthetic(() async {
              f.responseEntered = Completer();
              f.responseGate = Completer();
              final w = await f.create();
              final run = f.coordinator.start(f.dao, f.scope(), w);
              final reached = await Future.any<bool>([
                f.responseEntered!.future.then((_) => true),
                run.then((_) => false)
              ]);
              expect(reached, true, reason: 'actual first POST admitted');
              switch (change) {
                case 'account':
                  f.tokens.account = 'account-b';
                case 'token':
                  f.tokens.token = 'changed';
                case 'origin':
                  BackendConfig.host = 'changed.synthetic.invalid';
                case 'restore':
                  BackupService.agentExecutionRevision++;
              }
              f.responseGate!.complete();
              await run;
              expect(f.posts.length, 1);
              expect((await f.dao.read(w.id))!.dispatches, 1);
              expect((await f.dao.steps(w.id)).every((s) => s.result.isEmpty),
                  true);
              expect((await f.dao.attemptHistory(w.id)).single['result'], '');
            }));
  }
  test(
      'explicit stop cancels old run, original control identity persists pause',
      () async => f.synthetic(() async {
            f.responseEntered = Completer();
            f.responseGate = Completer();
            final w = await f.create();
            final s = f.scope();
            final run = f.coordinator.start(f.dao, s, w);
            expect(
                await Future.any<bool>([
                  f.responseEntered!.future.then((_) => true),
                  run.then((_) => false)
                ]),
                true);
            await f.coordinator.stop(f.dao, s, w);
            f.responseGate!.complete();
            await run;
            expect((await f.dao.read(w.id))!.state, WorkflowState.paused);
            expect(f.posts.length, 1);
            expect(
                (await f.dao.steps(w.id)).every((s) => s.result.isEmpty), true);
          }));
  test(
      'unknown attempt preserved; explicit resume cannot replay or rebind',
      () async => f.synthetic(() async {
            f.unknownNetwork = true;
            final w = await f.create();
            await f.coordinator.start(f.dao, f.scope(), w);
            expect(f.posts.length, 1);
            final current = (await f.dao.read(w.id))!;
            final history = await f.dao.attemptHistory(w.id);
            expect(history.single['state'], 'unknown');
            final profiles = (await f.dao.steps(w.id))
                .map((s) => s.toRow()['profile'])
                .toList();
            await f.coordinator.start(f.dao, f.scope(), current);
            expect(f.posts.length, 1);
            expect(await f.dao.attemptHistory(w.id), history);
            expect(
                (await f.dao.steps(w.id))
                    .map((s) => s.toRow()['profile'])
                    .toList(),
                profiles);
          }));
  test(
      'known failed request explicit new lease resumes original pair, no auto retry',
      () async => f.synthetic(() async {
            f.failed409 = true;
            final w = await f.create();
            await f.coordinator.start(f.dao, f.scope(), w);
            expect(f.posts.length, 1);
            final old = (await f.dao.attemptHistory(w.id)).single;
            expect(old['state'], 'failed');
            f.failed409 = false;
            f.settings.backendSelection = f.pair('C');
            await f.coordinator
                .start(f.dao, f.scope(), (await f.dao.read(w.id))!);
            expect(f.posts.map((p) => p['providerCode']), ['A', 'A', 'B', 'C']);
            final attempts = await f.dao.attemptHistory(w.id);
            expect(attempts.length, 4);
            expect(
                attempts.firstWhere((a) => a['attemptId'] == old['attemptId']),
                old);
            expect(attempts.map((a) => a['leaseId']).toSet().length, 2);
          }));
  test(
      'two guarded DAO handles compete exact revision, only one modern claim',
      () async => f.synthetic(() async {
            final w = await f.create();
            final m = f.models(f.scope());
            final steps = await f.prepareForClaim(w, m);
            final results = await Future.wait([
              for (final d in [f.guarded(m), f.guarded(m)])
                f.claim(d, m, w, steps).then<Object>((v) => v,
                    onError: (Object e, StackTrace _) => e)
            ]);
            expect(results.whereType<AgentWorkflow>().length, 1);
            expect(f.posts, isEmpty);
            await expectLater(f.dao.claim(f.scope(), w.id, w.revision),
                throwsA(isA<WorkflowStale>()));
          }));
  test(
      'node profile modified after preparation rejects complete snapshot claim',
      () async => f.synthetic(() async {
            final w = await f.create();
            final m = f.models(f.scope());
            final steps = await f.prepareForClaim(w, m);
            await f.raw.update(
                AgentWorkflowDao.stepTable,
                {
                  'profile': jsonEncode(
                      WorkflowModelProfile.backend(f.pair('B')).toJson())
                },
                where: 'stepId=?',
                whereArgs: [steps.first.id]);
            expect(await workflowError(f.claim(f.guarded(m), m, w, steps)),
                isNotNull);
            expect((await f.dao.read(w.id))!.state, WorkflowState.queued);
            expect(f.posts, isEmpty);
          }));
  for (final phase in ['claim', 'reserve', 'result']) {
    test(
        'actual last SQLite update $phase origin change rolls back writes',
        () async => f.synthetic(() async {
              final w = await f.create();
              final m = f.models(f.scope());
              final steps = await f.prepareForClaim(w, m);
              final d = f.guarded(m);
              AgentWorkflow current = w;
              String? attempt;
              if (phase != 'claim') {
                current = await f.claim(d, m, w, steps);
                current = await d.beginStep(
                    m.scope, WorkflowFence.of(current), steps.first.id,
                    inputHash: workflowHash('synthetic'));
                if (phase == 'result') {
                  final r = await f.reserve(d, m, current, steps.first);
                  current = r.workflow;
                  attempt = r.attemptId;
                }
              }
              final before = (await f.dao.read(w.id))!.toRow();
              final beforeSteps =
                  (await f.dao.steps(w.id)).map((s) => s.toRow()).toList();
              final beforeAttempts = await f.dao.attemptHistory(w.id);
              var reached = false;
              f.sql.afterUpdate = (table, values) async {
                if (table == AgentWorkflowDao.workflows) {
                  reached = true;
                  await Future<void>.value();
                  BackendConfig.host = 'changed.synthetic.invalid';
                }
              };
              final operation = phase == 'claim'
                  ? f.claim(d, m, w, steps)
                  : phase == 'reserve'
                      ? f.reserve(d, m, current, steps.first)
                      : d.finishAttempt(
                          m.scope, WorkflowFence.of(current), attempt!,
                          state: WorkflowAttemptState.succeeded,
                          result: 'synthetic late result',
                          promptTokens: 10,
                          completionTokens: 5);
              expect(await workflowError(operation), isNotNull);
              expect(reached, true);
              expect((await f.dao.read(w.id))!.toRow(), before);
              expect((await f.dao.steps(w.id)).map((s) => s.toRow()).toList(),
                  beforeSteps);
              expect(await f.dao.attemptHistory(w.id), beforeAttempts);
              expect(f.posts, isEmpty);
            }));
  }
  test(
      'reserve compares original role pair, does not borrow another prepared pair',
      () async => f.synthetic(() async {
            final w = await f.create();
            final m = f.models(f.scope());
            final steps = await f.prepareForClaim(w, m);
            final d = f.guarded(m);
            var current = await f.claim(d, m, w, steps);
            current = await d.beginStep(
                m.scope, WorkflowFence.of(current), steps.first.id,
                inputHash: workflowHash('synthetic'));
            await f.raw.update(
                AgentWorkflowDao.stepTable,
                {
                  'profile': jsonEncode(
                      WorkflowModelProfile.backend(f.pair('B')).toJson())
                },
                where: 'stepId=?',
                whereArgs: [steps.first.id]);
            expect(await workflowError(f.reserve(d, m, current, steps.first)),
                isNotNull);
            expect((await f.dao.read(w.id))!.dispatches, 0);
            expect(await f.dao.attemptHistory(w.id), isEmpty);
          }));
  for (final phase in ['claim', 'reserve']) {
    test(
        'actual COMMIT then $phase origin change rejects return, zero POST without fake rollback',
        () async => f.synthetic(() async {
              final w = await f.create();
              final m = f.models(f.scope());
              final steps = await f.prepareForClaim(w, m);
              final d = f.guarded(m);
              var current = w;
              if (phase == 'reserve') {
                current = await f.claim(d, m, w, steps);
                current = await d.beginStep(
                    m.scope, WorkflowFence.of(current), steps.first.id,
                    inputHash: workflowHash('synthetic'));
              }
              var committed = false;
              f.sql.afterCommit = () {
                committed = true;
                BackendConfig.host = 'changed.synthetic.invalid';
              };
              final operation = phase == 'claim'
                  ? f.claim(d, m, w, steps)
                  : f.reserve(d, m, current, steps.first);
              expect(await workflowError(operation), isNotNull);
              expect(committed, true);
              final row = (await f.dao.read(w.id))!;
              expect(row.state, WorkflowState.running);
              expect(row.dispatches, phase == 'reserve' ? 1 : 0);
              expect((await f.dao.attemptHistory(w.id)).length,
                  phase == 'reserve' ? 1 : 0);
              expect(f.posts, isEmpty);
            }));
  }
  test(
      'source edit while response pending denies all late results',
      () async => f.synthetic(() async {
            f.responseEntered = Completer();
            f.responseGate = Completer();
            final w = await f.create();
            final run = f.coordinator.start(f.dao, f.scope(), w);
            expect(
                await Future.any<bool>([
                  f.responseEntered!.future.then((_) => true),
                  run.then((_) => false)
                ]),
                true);
            await f.raw.update('tb_messages', {'content': 'changed source'},
                where: 'id=?', whereArgs: [f.userId]);
            f.responseGate!.complete();
            await run;
            expect(f.posts.length, 1);
            expect(
                (await f.dao.steps(w.id)).every((s) => s.result.isEmpty), true);
          }));
  test(
      'fresh original scope R2 binds all legacy steps before any modern dispatch',
      () async => f.synthetic(() async {
            final original = BackendSelectionBindingScope.capture(f.scope());
            final w = await f.create(selected: {
              for (final role in WorkflowRole.values)
                role: WorkflowModelProfile('backend', 'backend', role.name)
            });
            final bound = await LegacyBackendProfileBinding(
                    probe: BackendSelectionProbeClient(
                        headers: () =>
                            {'Authorization': 'Bearer synthetic-jwt'}).resolve)
                .workflow(f.dao, original, w.id);
            expect(f.resolverGets, 3);
            expect(f.posts, isEmpty);
            expect(bound.revision, w.revision + 1);
            expect(
                (await f.dao.steps(w.id)).every((s) =>
                    s.profile.backendSelection != null && s.revision == 2),
                true);
            await f.coordinator.start(f.dao, f.scope(), bound);
            expect(f.posts.map((p) => p['providerCode']), ['A', 'B', 'C']);
            expect(f.posts.map((p) => p['model']),
                ['analysis', 'writing', 'review']);
          }));
  for (final attempted in [false, true]) {
    test(
        'persisted legacy ${attempted ? 'unknown' : 'zero-attempt'} without provenance never re-signs',
        () async => f.synthetic(() async {
              final w = await f.create(selected: {
                for (final role in WorkflowRole.values)
                  role: const WorkflowModelProfile('backend', 'backend', 'same')
              });
              if (attempted) {
                await f.raw.insert(AgentWorkflowDao.attempts, {
                  'attemptId': 'synthetic-old',
                  'parentId': w.id,
                  'stepId': (await f.dao.steps(w.id)).first.id,
                  'leaseId': 'synthetic-old',
                  'state': 'unknown',
                  'inputHash': workflowHash('old'),
                  'estimatedInput': 1,
                  'reservedOutput': 1,
                  'createdAt': 1
                });
              }
              final rows =
                  (await f.dao.steps(w.id)).map((s) => s.toRow()).toList();
              final attempts = await f.dao.attemptHistory(w.id);
              await f.coordinator.start(f.dao, f.scope(), w);
              expect(f.resolverGets, 0);
              expect(f.posts, isEmpty);
              expect((await f.dao.read(w.id))!.toRow(), w.toRow());
              expect((await f.dao.steps(w.id)).map((s) => s.toRow()).toList(),
                  rows);
              expect(await f.dao.attemptHistory(w.id), attempts);
            }));
  }
  test(
      'foreign modern origin refuses without changing stored original pair',
      () async => f.synthetic(() async {
            final selected = {
              for (final role in WorkflowRole.values)
                role: WorkflowModelProfile.backend(
                    f.pair('A', origin: 'https://foreign.synthetic.invalid'))
            };
            final w = await f.create(selected: selected);
            final before = await f.dao.steps(w.id);
            await f.coordinator.start(f.dao, f.scope(), w);
            expect(f.posts, isEmpty);
            expect(f.resolverGets, 0);
            expect((await f.dao.steps(w.id)).map((s) => s.toRow()).toList(),
                before.map((s) => s.toRow()).toList());
            expect((await f.dao.read(w.id))!.toRow(), w.toRow());
          }));
}
