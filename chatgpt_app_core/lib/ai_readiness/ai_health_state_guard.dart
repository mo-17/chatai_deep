import 'package:chatgpt_app_core/data/provider_presets.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 一次模型健康检查启动时对应的连接配置快照。
///
/// 请求返回后必须先用 [matches] 与当前 provider 做 CAS 校验；这样测试期间
/// 修改 Key、有效 host、模型清单或当前选择时，旧请求结果不会认证新配置。
/// 快照只存在于内存且不实现 `toString`，避免凭据进入日志。
final class AIProviderHealthConfiguration {
  final String providerId;
  final String _type;
  final String _apiKey;
  final String _effectiveHost;
  final String _effectiveModelId;
  final List<String> _modelIds;
  final bool _hasUniqueModelIds;

  AIProviderHealthConfiguration._({
    required this.providerId,
    required String type,
    required String apiKey,
    required String effectiveHost,
    required String effectiveModelId,
    required List<String> modelIds,
    required bool hasUniqueModelIds,
  })  : _type = type,
        _apiKey = apiKey,
        _effectiveHost = effectiveHost,
        _effectiveModelId = effectiveModelId,
        _modelIds = List.unmodifiable(modelIds),
        _hasUniqueModelIds = hasUniqueModelIds;

  factory AIProviderHealthConfiguration.capture(AiProvider provider) {
    final modelIds = provider.models.map((model) => model.id).toList()..sort();
    return AIProviderHealthConfiguration._(
      providerId: provider.id,
      type: provider.type.trim().toLowerCase(),
      apiKey: provider.apiKey,
      effectiveHost: _effectiveHostFor(provider),
      effectiveModelId: provider.effectiveModelId,
      modelIds: modelIds,
      hasUniqueModelIds: modelIds.toSet().length == modelIds.length,
    );
  }

  bool matches(AiProvider provider) {
    final current = AIProviderHealthConfiguration.capture(provider);
    return _hasUniqueModelIds &&
        current._hasUniqueModelIds &&
        providerId == current.providerId &&
        _type == current._type &&
        _apiKey == current._apiKey &&
        _effectiveHost == current._effectiveHost &&
        _effectiveModelId == current._effectiveModelId &&
        _sameStrings(_modelIds, current._modelIds);
  }
}

/// 在设置更新边界清除已经不再对应当前连接配置的模型健康结果。
///
/// 不增加任何 JSON 字段：旧设置照常读取；保存时只比较持久化前后的有效配置。
/// 配置未变时完整保留 next 中刚写入的 success/failure，配置变化时则清除该
/// provider 全部模型的旧结果，避免 readiness 使用过期 success。
AISettings reconcileAIHealthState({
  required AISettings? previous,
  required AISettings next,
}) {
  final reconciled = next.clone();
  final previousById = <String, AiProvider>{
    if (previous != null)
      for (final provider in previous.providers) provider.id: provider,
  };

  for (final provider in reconciled.providers) {
    final before = previousById[provider.id];
    if (before == null ||
        !AIProviderHealthConfiguration.capture(before).matches(provider)) {
      for (final model in provider.models) {
        model.clearTestResult();
      }
    }
  }
  return reconciled;
}

bool _sameStrings(List<String> before, List<String> after) {
  if (before.length != after.length) return false;
  for (var i = 0; i < before.length; i++) {
    if (before[i] != after[i]) return false;
  }
  return true;
}

String _effectiveHostFor(AiProvider provider) {
  final configured = provider.apiHost.trim();
  final host = configured.isEmpty
      ? (ProviderPresets.byId(provider.id)?.apiHost ?? '')
      : configured;
  return AiProvider.buildChatCompletionsUrl(host);
}
