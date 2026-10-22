import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_usage_identity.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../backend_pair_transport_test.dart' show PairTokens;
import '../agent_workflow_foundation_test.dart' show FakeWorkflowBackground;

Future<Object?> workflowError(Future<Object?> operation) async {
  try {
    await operation;
    return null;
  } catch (e) {
    return e;
  }
}

/// 真 SQLite 执行器，只在真实 update 完成后、其 await 返回前注入同步身份变化。
class WorkflowSqlForwarder implements DatabaseExecutor {
  final DatabaseExecutor actual;
  WorkflowSqlForwarder(this.actual);
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      actual.execute(sql, arguments);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      actual.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      actual.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
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
      actual.query(table,
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
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      actual.delete(table, where: where, whereArgs: whereArgs);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      actual.rawUpdate(sql, arguments);
  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      actual.rawInsert(sql, arguments);
  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      actual.rawDelete(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      actual.rawQuery(sql, arguments);
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('unused SQL method');
}

class WorkflowSqlTransaction extends WorkflowSqlForwarder
    implements Transaction {
  final WorkflowSqlDatabase owner;
  WorkflowSqlTransaction(super.actual, this.owner);
  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    final result = await super.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
    final hook = owner.afterUpdate;
    if (hook != null) await hook(table, values);
    return result;
  }
}

class WorkflowSqlDatabase extends WorkflowSqlForwarder implements Database {
  @override
  final Database database;
  int activeTransactions = 0;
  Future<void> Function(String, Map<String, Object?>)? afterUpdate;
  void Function()? afterCommit;
  WorkflowSqlDatabase(this.database) : super(database);
  @override
  String get path => database.path;
  @override
  bool get isOpen => database.isOpen;
  @override
  Future<void> close() => database.close();
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    final result = await database.transaction((tx) async {
      activeTransactions++;
      try {
        return await action(WorkflowSqlTransaction(tx, this));
      } finally {
        activeTransactions--;
      }
    }, exclusive: exclusive);
    afterCommit?.call();
    return result;
  }
}

class WorkflowBackendFixture {
  static int serial = 0;
  final String label;
  final Directory baseRoot;
  WorkflowBackendFixture(this.label, {required this.baseRoot});
  late Database raw;
  late WorkflowSqlDatabase sql;
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late AgentWorkflowCoordinator coordinator;
  late PairTokens tokens;
  late AISettings settings;
  late String oldHost;
  late bool oldHttps;
  late Directory root;
  late int userId;
  int epoch = 1, loads = 0, creates = 0, resolverGets = 0, reviewCalls = 0;
  int postsAtLastClose = 0;
  bool revise = false,
      tools = false,
      emptyCatalog = false,
      failed409 = false,
      unknownNetwork = false;
  bool switchGlobal = false;
  Completer<void>? loadGate, loadEntered, responseGate, responseEntered;
  int gateLoad = 1;
  AgentWorkflowModels? latestModels;
  final posts = <Map<String, dynamic>>[];
  final streamRequests = <bool>[];
  final factoryPairs = <String?>[];
  final resolverModels = <String>[];
  final conversation =
      ConversationModel(cid: 1, title: 'synthetic workflow', icon: '');
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'account-a',
      currentAccount: () => tokens.account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => BackupService.agentExecutionRevision,
      stableOperation: (action) => action());
  BackendSelection pair(String code, {String model = 'same', String? origin}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: model,
          accountHash: 'account-a',
          origin: origin ?? BackendConfig.buildUri('/uapi/ai/catalog').origin);
  Map<WorkflowRole, WorkflowModelProfile> get profiles => {
        WorkflowRole.analysis: WorkflowModelProfile.backend(pair('A')),
        WorkflowRole.writing: WorkflowModelProfile.backend(pair('B')),
        WorkflowRole.review: WorkflowModelProfile.backend(pair('C')),
      };
  Future<AISettings> load() async {
    loads++;
    if (loads == gateLoad && loadEntered?.isCompleted == false) {
      loadEntered!.complete();
    }
    if (loads == gateLoad && loadGate != null) await loadGate!.future;
    return settings.clone();
  }

  AgentWorkflowModels models(AgentWorkflowScope s) {
    latestModels = AgentWorkflowModels(s,
        settings: load,
        visibleSettings: () => settings,
        createService: (fixed) {
          creates++;
          factoryPairs.add(fixed.backendSelection?.providerCode);
          return BackendChatService(fixed);
        });
    return latestModels!;
  }

  AgentWorkflowCoordinator makeCoordinator() {
    final arguments = <Symbol, dynamic>{
      #channel: AgentExecutionChannel(),
      #background: FakeWorkflowBackground(),
      #foreground: () => true,
      #observeApplication: false,
      // 旧基线不能进入 model-only/凭据加载；新后端入口必须忽略此旧 resolver。
      #profileAvailable: (WorkflowModelProfile _) async => false,
      #modelsFactory: models
    };
    try {
      return Function.apply(AgentWorkflowCoordinator.new, [], arguments)
          as AgentWorkflowCoordinator;
    } on NoSuchMethodError {
      arguments.remove(#modelsFactory);
      return Function.apply(AgentWorkflowCoordinator.new, [], arguments)
          as AgentWorkflowCoordinator;
    }
  }

  Future<void> setup() async {
    root = baseRoot;
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'workflow-consumer.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'workflow-consumer.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
    sqfliteFfiInit();
    raw = await databaseFactoryFfi
        .openDatabase('${root.path}/$label-${serial++}.sqlite');
    sql = WorkflowSqlDatabase(raw);
    storage = HiDBManager.test(sql);
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel.fromJson(conversation.toJson()));
    userId = await (await MessageDao.create(storage, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: 'synthetic bounded task',
            ownerType: OwnerType.sender,
            createdAt: 123));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'account-a');
    settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..providers = []
      ..backendSelection = pair('A')
      ..backendModel = 'same';
    settings.usageCostConfig = UsageCostConfig(overrides: {
      for (final c in ['A', 'B', 'C'])
        '${backendUsageProviderId(pair(c))}/*': UsageCostRate(
            inputCostPer1K: c == 'A'
                ? 1
                : c == 'B'
                    ? 2
                    : 3,
            outputCostPer1K: 1),
      'deepseek/*':
          const UsageCostRate(inputCostPer1K: 999, outputCostPer1K: 999)
    });
    coordinator = makeCoordinator();
  }

  Future<AgentWorkflow> create(
          {WorkflowBudget budget = const WorkflowBudget(),
          Map<WorkflowRole, WorkflowModelProfile>? selected,
          Set<String> granted = const {}}) =>
      dao.createFromSource(scope(),
          cid: 1,
          userRowId: userId,
          profiles: selected ?? profiles,
          budget: budget,
          acceptance: const TaskAcceptanceCriteria(requireFullRead: false),
          grantedTools: granted);
  Future<T> synthetic<T>(Future<T> Function() body) =>
      http.runWithClient(body, () => MockClient(handle));
  Future<http.Response> handle(http.Request r) async {
    expect(r.url.host, 'workflow-consumer.synthetic.invalid');
    expect(r.headers['Authorization'], 'Bearer synthetic-jwt');
    expect(sql.activeTransactions, 0,
        reason: 'network only after short SQLite transaction released');
    if (r.method == 'GET' && r.url.path == '/uapi/ai/catalog') {
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'providers': [
                for (final c in emptyCatalog ? <String>[] : ['A', 'B', 'C'])
                  {'code': c, 'displayName': 'Synthetic $c'}
              ],
              'models': [
                for (final c in emptyCatalog ? <String>[] : ['A', 'B', 'C'])
                  {
                    'providerCode': c,
                    'modelId': 'same',
                    'displayName': 'same',
                    'supportsTool': tools && c == 'A',
                    'supportsVision': false,
                    'supportsReasoning': false,
                    'supportsPdf': false
                  }
              ]
            }
          }),
          200);
    }
    if (r.method == 'GET' && r.url.path == '/uapi/ai/model-selection') {
      resolverGets++;
      final model = r.url.queryParameters['modelId']!;
      resolverModels.add(model);
      final c = model == 'analysis'
          ? 'A'
          : model == 'writing'
              ? 'B'
              : 'C';
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'providerCode': c, 'modelId': model}
          }),
          200);
    }
    expect(r.method, 'POST');
    expect(r.followRedirects, false);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    posts.add(body);
    streamRequests.add(r.url.path.endsWith('/stream'));
    if (posts.length == 1 && responseEntered?.isCompleted == false) {
      responseEntered!.complete();
    }
    if (posts.length == 1 && responseGate != null) await responseGate!.future;
    if (posts.length == 1 && switchGlobal) {
      settings.backendSelection = pair('C');
    }
    if (posts.length == 1 && unknownNetwork) {
      throw http.ClientException('synthetic unknown');
    }
    if (posts.length == 1 && failed409) {
      return http.Response(
          jsonEncode({
            'safeCode': 'provider_unavailable',
            'message': 'synthetic unsafe provider detail'
          }),
          409);
    }
    final system =
        ((body['messages'] as List).first as Map)['content'] as String;
    final role = system.contains('职责：分析')
        ? 'analysis'
        : system.contains('职责：根据')
            ? 'writing'
            : 'review';
    if (role == 'review') reviewCalls++;
    final content = role == 'review'
        ? jsonEncode({
            'decision': revise && reviewCalls == 1 ? 'revise' : 'accept',
            'feedback': 'synthetic:${body['providerCode']}'
          })
        : '$role:${body['providerCode']}';
    final usage = {'prompt_tokens': 10, 'completion_tokens': 5};
    if (r.url.path.endsWith('/stream')) {
      final toolRequest =
          posts.where((p) => p['providerCode'] == 'A').length == 1;
      final delta = toolRequest
          ? {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'synthetic-list',
                  'type': 'function',
                  'function': {'name': 'list_files', 'arguments': '{}'}
                }
              ]
            }
          : {'content': content};
      return http.Response(
          'data: ${jsonEncode({
                'choices': [
                  {'delta': delta}
                ],
                'usage': usage
              })}\n\ndata: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'});
    }
    return http.Response(
        jsonEncode({
          'code': 0,
          'data': {'content': content, 'usage': usage}
        }),
        200);
  }

  Future<List<WorkflowStep>> prepareForClaim(
      AgentWorkflow task, AgentWorkflowModels m) async {
    final steps = await dao.steps(task.id);
    try {
      await (m as dynamic).prepareWorkflow(steps);
    } on NoSuchMethodError {
      for (final step in steps) {
        await m.prepareBackend(step.profile);
      }
    }
    return steps;
  }

  AgentWorkflowDao guarded(AgentWorkflowModels m) {
    void original() {
      try {
        (m as dynamic).verifyOriginalScope();
      } on NoSuchMethodError {
        m.scope.verify();
      }
    }

    void selected(WorkflowModelProfile p) {
      try {
        (m as dynamic).verifyRunProfile(p);
      } on NoSuchMethodError {
        m.scope.verify();
      }
    }

    try {
      return (dao as dynamic).forExecution(
          guard: original, verifyProfile: selected) as AgentWorkflowDao;
    } on NoSuchMethodError {
      return dao;
    }
  }

  Future<AgentWorkflow> claim(AgentWorkflowDao d, AgentWorkflowModels m,
      AgentWorkflow task, List<WorkflowStep> steps) async {
    try {
      return await Function.apply(d.claim, [m.scope, task.id, task.revision],
          {#expectedSteps: steps}) as AgentWorkflow;
    } on NoSuchMethodError {
      return d.claim(m.scope, task.id, task.revision);
    }
  }

  Future<WorkflowReservation> reserve(AgentWorkflowDao d, AgentWorkflowModels m,
      AgentWorkflow task, WorkflowStep step) async {
    final args = <Symbol, dynamic>{
      #inputHash: workflowHash('synthetic'),
      #estimatedInput: 10,
      #expectedProfile: step.profile
    };
    try {
      return await Function.apply(
          d.reserveDispatch,
          [m.scope, WorkflowFence.of(task), step.id],
          args) as WorkflowReservation;
    } on NoSuchMethodError {
      args.remove(#expectedProfile);
      return await Function.apply(
          d.reserveDispatch,
          [m.scope, WorkflowFence.of(task), step.id],
          args) as WorkflowReservation;
    }
  }

  Future<void> close() async {
    for (final c in [loadGate, responseGate]) {
      if (c?.isCompleted == false) c!.complete();
    }
    final tasks = await dao.list(1);
    for (final task in tasks) {
      if (coordinator.busy('account-a', task.id)) {
        await coordinator
            .lookup('account-a', task.id)
            ?.pause('synthetic cleanup');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(tokens.clears, 0);
    expect(sql.activeTransactions, 0);
    await raw.close();
    coordinator.dispose();
    LoginSdkConfig.reset();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  }

  Map<String, Object?> evidence() => {
        'posts': List.generate(
            posts.length,
            (i) => {
                  'providerCode': posts[i]['providerCode'],
                  'model': posts[i]['model'],
                  'stream': streamRequests[i]
                }),
        'resolverGets': resolverGets,
        'loads': loads,
        'factoryPairs': factoryPairs,
        'sqlClosed': !raw.isOpen,
        'logout': tokens.clears
      };
}
