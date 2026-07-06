import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';

/// 用量记录服务。
///
/// 负责把单轮会话落库前的 usage 语义统一：真实 usage 优先；任何缺失字段
/// 使用文本估算兜底，并把 `estimated` 标记同步落库。
class UsageRecordService {
  final UsageDao dao;

  UsageRecordService(this.dao);

  /// 记录一轮助手回复的使用量。
  ///
  /// - `promptTokens` / `completionTokens` 有值时直接落库；无值时按文本估算。
  /// - `estimated` 标记服务端 usage 不可用时置 true。
  /// - `cost` 若未从上游返回且经过估算，使用内部估算口径（当前价格因子默认 0）。
  Future<void> recordTurn({
    required String modelId,
    String? providerId,
    required int? projectId,
    required int? cid,
    required String prompt,
    required String completion,
    int? promptTokens,
    int? cachedPromptTokens,
    int? completionTokens,
    bool estimated = false,
    double cost = 0,
    UsageCostConfig? costConfig,
    required int createdAt,
  }) async {
    final at = DateTime.fromMillisecondsSinceEpoch(createdAt);
    final rate = costConfig?.rateFor(
      providerId: providerId,
      modelId: modelId,
      at: at,
    );
    final sample = UsageCostEstimator.estimateTurn(
      modelId: modelId,
      prompt: prompt,
      completion: completion,
      at: at,
      projectId: projectId?.toString(),
      conversationId: cid?.toString(),
      inputCostPer1K: rate?.inputCostPer1K ?? 0,
      outputCostPer1K: rate?.outputCostPer1K ?? 0,
    );

    final useEstimated =
        estimated || promptTokens == null || completionTokens == null;
    final usagePromptTokens = promptTokens ?? sample.promptTokens;
    final usageCachedPromptTokens =
        (cachedPromptTokens ?? 0).clamp(0, usagePromptTokens).toInt();
    final usageCompletionTokens = completionTokens ?? sample.completionTokens;

    final estimatedCost = rate == null
        ? sample.cost
        : rate.costFor(
            promptTokens: usagePromptTokens,
            cachedPromptTokens: usageCachedPromptTokens,
            completionTokens: usageCompletionTokens,
          );
    final finalCost = cost > 0 ? cost : estimatedCost;
    await dao.insert(UsageRecord(
      modelId: modelId,
      providerId: providerId,
      projectId: projectId,
      cid: cid,
      promptTokens: usagePromptTokens,
      cachedPromptTokens: usageCachedPromptTokens,
      completionTokens: usageCompletionTokens,
      cost: finalCost,
      estimated: useEstimated,
      createdAt: createdAt,
    ));
  }
}
