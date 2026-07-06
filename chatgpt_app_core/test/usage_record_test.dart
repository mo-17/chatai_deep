import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<UsageDao> openDao() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final dao = await UsageDao.create(HiDBManager.test(db));
    return dao;
  }

  Future<void> seed(
    UsageDao dao, {
    required String modelId,
    required int cid,
    required int createdAt,
    required int promptTokens,
    required int completionTokens,
    int cachedPromptTokens = 0,
    String? providerId,
    int? projectId,
    double cost = 0,
    bool estimated = false,
  }) {
    return dao.insert(UsageRecord(
      modelId: modelId,
      providerId: providerId,
      projectId: projectId,
      cid: cid,
      promptTokens: promptTokens,
      cachedPromptTokens: cachedPromptTokens,
      completionTokens: completionTokens,
      cost: cost,
      estimated: estimated,
      createdAt: createdAt,
    ));
  }

  group('UsageCostConfig', () {
    test('旧配置缺省时保留 0 默认价并补齐 DeepSeek V4 预设', () {
      final settings = AISettings.fromJson(const {
        'providers': [],
        'activeProviderId': 'openai',
      });

      final rate = settings.usageCostConfig
          .rateFor(providerId: 'openai', modelId: 'gpt-4o');

      expect(rate.isZero, isTrue);
      final v4Pro = settings.usageCostConfig
          .rateFor(providerId: 'deepseek', modelId: 'deepseek-v4-pro');
      final v4Flash = settings.usageCostConfig
          .rateFor(providerId: 'deepseek', modelId: 'deepseek-v4-flash');
      expect(v4Pro.effectiveCachedInputCostPer1K, 0.025);
      expect(v4Pro.inputCostPer1K, 3);
      expect(v4Pro.outputCostPer1K, 6);
      expect(v4Flash.effectiveCachedInputCostPer1K, 0.02);
      expect(v4Flash.inputCostPer1K, 1);
      expect(v4Flash.outputCostPer1K, 2);
      expect(settings.toJson()['usageCostConfig'], isA<Map<String, dynamic>>());
    });

    test('用户自定义 DeepSeek V4 单价优先于内置预设', () {
      final config = UsageCostConfig.fromJson({
        'overrides': {
          'deepseek/deepseek-v4-pro': {
            'cachedInputCostPer1K': 9,
            'inputCostPer1K': 10,
            'outputCostPer1K': 11,
          },
        },
      });

      final rate = config.rateFor(
        providerId: 'deepseek',
        modelId: 'deepseek-v4-pro',
        at: DateTime.utc(2026, 7, 6, 1, 30),
      );
      final flash =
          config.rateFor(providerId: 'deepseek', modelId: 'deepseek-v4-flash');

      expect(rate.effectiveCachedInputCostPer1K, 9);
      expect(rate.inputCostPer1K, 10);
      expect(rate.outputCostPer1K, 11);
      expect(flash.effectiveCachedInputCostPer1K, 0.02);
      expect(flash.inputCostPer1K, 1);
      expect(flash.outputCostPer1K, 2);
    });

    test('DeepSeek V4 按北京时间高峰时段切换计价', () {
      final config = AISettings.defaults().usageCostConfig;

      final proPeak = config.rateFor(
        providerId: 'deepseek',
        modelId: 'deepseek-v4-pro',
        at: DateTime.utc(2026, 7, 6, 1, 30), // 北京 09:30
      );
      final proNormal = config.rateFor(
        providerId: 'deepseek',
        modelId: 'deepseek-v4-pro',
        at: DateTime.utc(2026, 7, 6, 4, 0), // 北京 12:00
      );
      final flashPeak = config.rateFor(
        providerId: 'deepseek',
        modelId: 'deepseek-v4-flash',
        at: DateTime.utc(2026, 7, 6, 6, 30), // 北京 14:30
      );

      expect(proPeak.effectiveCachedInputCostPer1K, 0.05);
      expect(proPeak.inputCostPer1K, 6);
      expect(proPeak.outputCostPer1K, 12);
      expect(proNormal.effectiveCachedInputCostPer1K, 0.025);
      expect(proNormal.inputCostPer1K, 3);
      expect(proNormal.outputCostPer1K, 6);
      expect(flashPeak.effectiveCachedInputCostPer1K, 0.04);
      expect(flashPeak.inputCostPer1K, 2);
      expect(flashPeak.outputCostPer1K, 4);
    });

    test('内置 DeepSeek V4 预设不重复写入持久化 JSON', () {
      final json = AISettings.defaults().usageCostConfig.toJson();

      expect(json['overrides'], isEmpty);
      expect(json['timeRules'], isEmpty);
      final restored =
          UsageCostConfig.fromJson((json as Map).cast<String, dynamic>());
      expect(
        restored
            .rateFor(
              providerId: 'deepseek',
              modelId: 'deepseek-v4-pro',
              at: DateTime.utc(2026, 7, 6, 1, 30),
            )
            .outputCostPer1K,
        12,
      );
    });

    test('provider/model 精确单价优先于 provider 默认单价', () {
      const config = UsageCostConfig(
        defaultRate: UsageCostRate(
            cachedInputCostPer1K: 0.5, inputCostPer1K: 1, outputCostPer1K: 2),
        overrides: {
          'openai/*': UsageCostRate(
              cachedInputCostPer1K: 2, inputCostPer1K: 3, outputCostPer1K: 4),
          'openai/gpt-4o': UsageCostRate(
              cachedInputCostPer1K: 4, inputCostPer1K: 5, outputCostPer1K: 6),
        },
      );

      expect(
          config
              .rateFor(providerId: 'openai', modelId: 'gpt-4o')
              .inputCostPer1K,
          5);
      expect(
          config
              .rateFor(providerId: 'openai', modelId: 'gpt-4o-mini')
              .inputCostPer1K,
          3);
      expect(
          config
              .rateFor(providerId: 'deepseek', modelId: 'deepseek-chat')
              .inputCostPer1K,
          1);
      expect(
          config
              .rateFor(providerId: 'openai', modelId: 'gpt-4o')
              .effectiveCachedInputCostPer1K,
          4);
    });
  });

  group('UsageDao 聚合查询', () {
    late Database db;
    late UsageDao dao;

    setUp(() async {
      dao = await openDao();
      db = dao.storage.db;
    });

    tearDown(() async {
      await db.close();
    });

    test('queryByConversation 支持分页（createdAt 倒序）', () async {
      await seed(dao,
          modelId: 'gpt',
          cid: 100,
          createdAt: 10,
          promptTokens: 1,
          completionTokens: 2);
      await seed(dao,
          modelId: 'gpt',
          cid: 100,
          createdAt: 20,
          promptTokens: 3,
          completionTokens: 4);
      await seed(dao,
          modelId: 'gpt',
          cid: 101,
          createdAt: 30,
          promptTokens: 5,
          completionTokens: 6);

      final first = await dao.queryByConversation(100, pageSize: 1, page: 0);
      final second = await dao.queryByConversation(100, pageSize: 1, page: 1);
      expect(first.single.createdAt, 20);
      expect(second.single.createdAt, 10);
      expect(second.single.promptTokens, 1);
    });

    test('queryZeroCostRecords 与 updateCost 支持历史成本回算', () async {
      await seed(
        dao,
        modelId: 'deepseek-v4-pro',
        providerId: 'deepseek',
        cid: 1,
        createdAt: 100,
        promptTokens: 1000,
        completionTokens: 500,
      );
      await seed(
        dao,
        modelId: 'gpt-a',
        providerId: 'openai',
        cid: 2,
        createdAt: 200,
        promptTokens: 1000,
        completionTokens: 500,
        cost: 0.12,
      );

      final zeroCost = await dao.queryZeroCostRecords();
      expect(zeroCost, hasLength(1));
      expect(zeroCost.single.modelId, 'deepseek-v4-pro');

      final id = zeroCost.single.id!;
      final updated = await dao.updateCost(id, 0.006);
      expect(updated, 1);
      final after = await dao.queryZeroCostRecords();
      expect(after, isEmpty);
      final rows = await dao.queryByConversation(1);
      expect(rows.single.cost, 0.006);
    });

    test('aggregateByModel 按 model 汇总并可过滤时间范围', () async {
      await seed(dao,
          modelId: 'gpt-a',
          cid: 1,
          createdAt: 100,
          promptTokens: 3,
          cachedPromptTokens: 1,
          completionTokens: 4);
      await seed(dao,
          modelId: 'gpt-a',
          cid: 2,
          createdAt: 200,
          promptTokens: 5,
          cachedPromptTokens: 2,
          completionTokens: 6);
      await seed(dao,
          modelId: 'gpt-b',
          cid: 1,
          createdAt: 300,
          promptTokens: 8,
          completionTokens: 9);

      final all = await dao.aggregateByModel();
      expect(all, hasLength(2));
      final fast = all.firstWhere((e) => e.key == 'gpt-a');
      final slow = all.firstWhere((e) => e.key == 'gpt-b');
      expect(fast.promptTokens, 8);
      expect(fast.cachedPromptTokens, 3);
      expect(fast.uncachedPromptTokens, 5);
      expect(fast.completionTokens, 10);
      expect(fast.calls, 2);
      expect(slow.cost, 0);

      final filtered = await dao.aggregateByModel(fromAt: 150, toAt: 250);
      expect(filtered, hasLength(1));
      expect(filtered.single.key, 'gpt-a');
    });

    test('aggregateByDate 与 aggregateByConversation 按 group key 汇总', () async {
      await seed(
        dao,
        modelId: 'gpt-a',
        cid: 1,
        projectId: 7,
        createdAt: DateTime.utc(2026, 6, 30).millisecondsSinceEpoch,
        promptTokens: 2,
        completionTokens: 4,
      );
      await seed(
        dao,
        modelId: 'gpt-a',
        cid: 1,
        projectId: 7,
        createdAt: DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
        promptTokens: 3,
        completionTokens: 5,
      );
      await seed(
        dao,
        modelId: 'gpt-b',
        cid: 2,
        projectId: 7,
        createdAt: DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
        promptTokens: 1,
        completionTokens: 1,
      );

      final byDate = await dao.aggregateByDate(projectId: 7);
      expect(byDate.map((e) => e.key), ['2026-07-01', '2026-06-30']);
      expect(byDate.first.totalTokens, 10);
      expect(byDate.last.totalTokens, 6);

      final byConversation = await dao.aggregateByConversation(projectId: 7);
      expect(byConversation, hasLength(2));
      expect(byConversation.first.key, '2');
      expect(byConversation.singleWhere((e) => e.key == '1').totalTokens, 14);
      expect(byConversation.singleWhere((e) => e.key == '2').cost, 0);
    });

    test('aggregateByProvider 支持 provider 分组和 project/model 交叉过滤', () async {
      await seed(
        dao,
        modelId: 'gpt-a',
        providerId: 'openai',
        cid: 1,
        projectId: 7,
        createdAt: 100,
        promptTokens: 10,
        completionTokens: 5,
        cost: 0.1,
        estimated: true,
      );
      await seed(
        dao,
        modelId: 'gpt-b',
        providerId: 'openai',
        cid: 2,
        projectId: 8,
        createdAt: 200,
        promptTokens: 2,
        completionTokens: 3,
      );
      await seed(
        dao,
        modelId: 'deepseek-chat',
        providerId: 'deepseek',
        cid: 3,
        projectId: 7,
        createdAt: 300,
        promptTokens: 4,
        completionTokens: 6,
      );
      await seed(
        dao,
        modelId: 'local-only',
        cid: 4,
        projectId: 7,
        createdAt: 400,
        promptTokens: 99,
        completionTokens: 1,
      );

      final all = await dao.aggregateByProvider();
      expect(all.map((e) => e.key), ['openai', 'deepseek']);
      final openai = all.firstWhere((e) => e.key == 'openai');
      expect(openai.totalTokens, 20);
      expect(openai.calls, 2);
      expect(openai.estimated, isTrue);

      final project7 = await dao.aggregateByProvider(projectId: 7);
      expect(project7.map((e) => e.key), ['openai', 'deepseek']);
      expect(project7.firstWhere((e) => e.key == 'openai').totalTokens, 15);

      final filteredModels = await dao.aggregateByModel(providerId: 'openai');
      expect(filteredModels.map((e) => e.key), ['gpt-a', 'gpt-b']);

      final filteredDates = await dao.aggregateByDate(providerId: 'deepseek');
      expect(filteredDates.single.totalTokens, 10);

      final filteredConversations =
          await dao.aggregateByConversation(providerId: 'openai');
      expect(filteredConversations.map((e) => e.key), ['2', '1']);
    });

    test('aggregateByProject 在项目表缺失时按 projectId 兜底汇总', () async {
      await seed(
        dao,
        modelId: 'gpt-a',
        providerId: 'openai',
        cid: 1,
        projectId: 7,
        createdAt: 100,
        promptTokens: 10,
        completionTokens: 5,
      );
      await seed(
        dao,
        modelId: 'gpt-a',
        providerId: 'openai',
        cid: 2,
        createdAt: 200,
        promptTokens: 2,
        completionTokens: 3,
      );

      final byProject = await dao.aggregateByProject(providerId: 'openai');

      expect(byProject.map((e) => e.key), ['项目 #7', '未分类']);
      expect(byProject.first.totalTokens, 15);
      expect(byProject.last.totalTokens, 5);
    });

    test('aggregateByProject 有项目表时展示项目名并支持过滤', () async {
      final projectDao = await ProjectDao.create(dao.storage);
      final research = ProjectModel(name: '研究项目');
      final writing = ProjectModel(name: '写作项目');
      final researchId = await projectDao.saveProject(research);
      final writingId = await projectDao.saveProject(writing);

      await seed(
        dao,
        modelId: 'gpt-a',
        providerId: 'openai',
        cid: 1,
        projectId: researchId,
        createdAt: 100,
        promptTokens: 10,
        completionTokens: 5,
        estimated: true,
      );
      await seed(
        dao,
        modelId: 'gpt-b',
        providerId: 'openai',
        cid: 2,
        projectId: writingId,
        createdAt: 200,
        promptTokens: 2,
        completionTokens: 3,
      );
      await seed(
        dao,
        modelId: 'deepseek-chat',
        providerId: 'deepseek',
        cid: 3,
        projectId: null,
        createdAt: 300,
        promptTokens: 4,
        completionTokens: 6,
      );

      final byProject = await dao.aggregateByProject();

      expect(byProject.map((e) => e.key), ['研究项目', '未分类', '写作项目']);
      expect(byProject.first.totalTokens, 15);
      expect(byProject.first.estimated, isTrue);

      final openai = await dao.aggregateByProject(providerId: 'openai');
      expect(openai.map((e) => e.key), ['研究项目', '写作项目']);

      final modelFiltered = await dao.aggregateByProject(modelId: 'gpt-b');
      expect(modelFiltered.single.key, '写作项目');
    });
  });

  group('UsageRecordService 真实/估算入库行为', () {
    late Database db;
    late UsageDao dao;
    late UsageRecordService service;

    setUp(() async {
      dao = await openDao();
      db = dao.storage.db;
      service = UsageRecordService(dao);
    });

    tearDown(() async {
      await db.close();
    });

    test('优先落库 provider usage，不触发估算回退', () async {
      await service.recordTurn(
        modelId: 'gpt-a',
        providerId: 'openai',
        projectId: 7,
        cid: 99,
        prompt: '你好',
        completion: '世界',
        promptTokens: 6,
        cachedPromptTokens: 2,
        completionTokens: 4,
        cost: 0.88,
        createdAt: 1,
      );

      final rows = await dao.queryByConversation(99);
      expect(rows, hasLength(1));
      expect(rows.single.promptTokens, 6);
      expect(rows.single.cachedPromptTokens, 2);
      expect(rows.single.uncachedPromptTokens, 4);
      expect(rows.single.completionTokens, 4);
      expect(rows.single.cost, 0.88);
      expect(rows.single.estimated, isFalse);
    });

    test('usage 缺失时按文本回退估算并标记 estimated', () async {
      const prompt = '这是估算路径的用户输入示例文本';
      const completion = '这是模型返回示例';
      final at = DateTime(2026, 6, 30);
      final sample = UsageCostEstimator.estimateTurn(
        modelId: 'gpt-a',
        prompt: prompt,
        completion: completion,
        at: at,
      );

      await service.recordTurn(
        modelId: 'gpt-a',
        projectId: null,
        cid: 100,
        prompt: prompt,
        completion: completion,
        createdAt: at.millisecondsSinceEpoch,
      );

      final rows = await dao.queryByConversation(100);
      expect(rows, hasLength(1));
      expect(rows.single.estimated, isTrue);
      expect(rows.single.promptTokens, sample.promptTokens);
      expect(rows.single.completionTokens, sample.completionTokens);
    });

    test('成本配置会按 provider/model 口径计算估算成本', () async {
      const costConfig = UsageCostConfig(overrides: {
        'openai/gpt-a': UsageCostRate(
            cachedInputCostPer1K: 0.5, inputCostPer1K: 2, outputCostPer1K: 4),
      });

      await service.recordTurn(
        modelId: 'gpt-a',
        providerId: 'openai',
        projectId: null,
        cid: 101,
        prompt: 'prompt',
        completion: 'completion',
        promptTokens: 1000,
        cachedPromptTokens: 400,
        completionTokens: 500,
        costConfig: costConfig,
        createdAt: 1,
      );

      final rows = await dao.queryByConversation(101);
      expect(rows.single.cachedPromptTokens, 400);
      expect(rows.single.uncachedPromptTokens, 600);
      expect(rows.single.cost, closeTo(0.0034, 0.000000001));
      expect(rows.single.estimated, isFalse);
    });

    test('成本配置会按 createdAt 应用分时计价规则', () async {
      await service.recordTurn(
        modelId: 'deepseek-v4-pro',
        providerId: 'deepseek',
        projectId: null,
        cid: 103,
        prompt: 'p',
        completion: 'c',
        promptTokens: 1000000,
        cachedPromptTokens: 1000000,
        completionTokens: 1000000,
        costConfig: AISettings.defaults().usageCostConfig,
        createdAt: DateTime.utc(2026, 7, 6, 1, 30).millisecondsSinceEpoch,
      );

      final rows = await dao.queryByConversation(103);
      expect(rows.single.cost, closeTo(12.05, 0.000000001));
    });

    test('同一 token 量可随成本配置得到不同估算成本', () async {
      await service.recordTurn(
        modelId: 'gpt-a',
        providerId: 'openai',
        projectId: null,
        cid: 102,
        prompt: 'p',
        completion: 'c',
        promptTokens: 1000,
        completionTokens: 1000,
        costConfig: const UsageCostConfig(
            defaultRate: UsageCostRate(
          inputCostPer1K: 1,
          outputCostPer1K: 1,
        )),
        createdAt: 1,
      );
      await service.recordTurn(
        modelId: 'gpt-a',
        providerId: 'openai',
        projectId: null,
        cid: 102,
        prompt: 'p',
        completion: 'c',
        promptTokens: 1000,
        completionTokens: 1000,
        costConfig: const UsageCostConfig(
            defaultRate: UsageCostRate(
          inputCostPer1K: 3,
          outputCostPer1K: 5,
        )),
        createdAt: 2,
      );

      final rows = await dao.queryByConversation(102);
      expect(rows.map((e) => e.cost), [0.008, 0.002]);
    });
  });
}
