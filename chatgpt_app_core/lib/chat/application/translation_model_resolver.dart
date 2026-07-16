import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 快照所指向的模型已经无法按原配置执行。
final class TranslationModelUnavailableException implements Exception {
  final String message;

  const TranslationModelUnavailableException(this.message);

  @override
  String toString() => 'TranslationModelUnavailableException: $message';
}

/// 在任务创建时冻结翻译模型，并在每次执行前严格恢复该模型。
final class TranslationModelResolver {
  const TranslationModelResolver._();

  static TranslationRequestProfile snapshot(
    AISettings settings,
    TranslationModelPreference preference,
  ) {
    // const 构造器保留轻量调用体验；解析入口仍强制执行与持久化 JSON 相同的合同。
    final validated = TranslationModelPreference.fromJson(preference.toJson());
    switch (validated.mode) {
      case TranslationModelPreferenceMode.followGlobal:
        if (settings.mode == AIMode.backend) {
          return _backendProfile(
            settings.backendModel,
            validated.reasoningPolicy,
          );
        }
        return _localProfile(
          settings,
          providerId: settings.activeProviderId,
          modelId: null,
          reasoningPolicy: validated.reasoningPolicy,
        );
      case TranslationModelPreferenceMode.local:
        return _localProfile(
          settings,
          providerId: validated.providerId,
          modelId: validated.modelId,
          reasoningPolicy: validated.reasoningPolicy,
        );
      case TranslationModelPreferenceMode.backend:
        return _backendProfile(
          validated.modelId,
          validated.reasoningPolicy,
        );
    }
  }

  static AISettings apply(
    AISettings current,
    TranslationRequestProfile profile,
  ) {
    switch (profile.mode) {
      case TranslationExecutionMode.local:
        // 先在当前设置中严格校验，避免 clone() 的预设补全掩盖已删除服务商。
        _requireLocalProvider(
          current,
          providerId: profile.providerId,
          modelId: profile.modelId,
        );
        final next = current.clone();
        final provider = _requireLocalProvider(
          next,
          providerId: profile.providerId,
          modelId: profile.modelId,
        );
        next.mode = AIMode.local;
        next.activeProviderId = provider.id;
        provider.selectedModelId = profile.modelId;
        return next;
      case TranslationExecutionMode.backend:
        _requireModelId(profile.modelId, scope: '后端');
        final next = current.clone();
        next.mode = AIMode.backend;
        next.backendModel = profile.modelId;
        return next;
    }
  }

  static TranslationRequestProfile _localProfile(
    AISettings settings, {
    required String? providerId,
    required String? modelId,
    required ChatReasoningPolicy reasoningPolicy,
  }) {
    final provider = _requireLocalProvider(
      settings,
      providerId: providerId,
      modelId: modelId,
    );
    final resolvedModel = modelId ?? provider.effectiveModelId;
    return TranslationRequestProfile(
      mode: TranslationExecutionMode.local,
      providerId: provider.id,
      modelId: resolvedModel,
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: false,
    );
  }

  static TranslationRequestProfile _backendProfile(
    String? modelId,
    ChatReasoningPolicy reasoningPolicy,
  ) {
    final resolvedModel = _requireModelId(modelId, scope: '后端');
    return TranslationRequestProfile(
      mode: TranslationExecutionMode.backend,
      modelId: resolvedModel,
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: false,
    );
  }

  static AiProvider _requireLocalProvider(
    AISettings settings, {
    required String? providerId,
    required String? modelId,
  }) {
    if (providerId == null || providerId.trim().isEmpty) {
      throw const TranslationModelUnavailableException('本地翻译服务商未配置');
    }
    AiProvider? provider;
    for (final candidate in settings.providers) {
      if (candidate.id == providerId) {
        provider = candidate;
        break;
      }
    }
    if (provider == null) {
      throw TranslationModelUnavailableException(
        '翻译服务商已删除：$providerId',
      );
    }
    if (!provider.enabled) {
      throw TranslationModelUnavailableException(
        '翻译服务商已停用：$providerId',
      );
    }
    if (provider.apiKey.trim().isEmpty) {
      throw TranslationModelUnavailableException(
        '翻译服务商缺少 API Key：$providerId',
      );
    }
    final resolvedModel = modelId ?? provider.effectiveModelId;
    _requireModelId(resolvedModel, scope: '本地');
    if (!provider.models.any((model) => model.id == resolvedModel)) {
      throw TranslationModelUnavailableException(
        '翻译模型已从服务商移除：$providerId/$resolvedModel',
      );
    }
    return provider;
  }

  static String _requireModelId(String? modelId, {required String scope}) {
    if (modelId == null || modelId.trim().isEmpty) {
      throw TranslationModelUnavailableException('$scope翻译模型未配置');
    }
    return modelId;
  }
}
