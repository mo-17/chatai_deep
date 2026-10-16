import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 将 UI 偏好归一成真正会用于 eligibility、probe 与任务快照的 reasoning 语义。
///
/// 不支持显式 reasoning-control 的本地模型不会发送关闭参数，因此其正式偏好
/// 是 providerDefault。后端由代理层解释统一语义，保留 offIfSupported。
TranslationModelPreference normalizeTranslationModelPreference(
  AISettings settings,
  TranslationModelPreference preference,
) {
  final validated = TranslationModelPreference.fromJson(preference.toJson());
  if (validated.reasoningPolicy != ChatReasoningPolicy.offIfSupported) {
    return validated;
  }
  if (validated.mode == TranslationModelPreferenceMode.backend ||
      (validated.mode == TranslationModelPreferenceMode.followGlobal &&
          settings.mode == AIMode.backend)) {
    return validated;
  }

  final providerId = validated.mode == TranslationModelPreferenceMode.local
      ? validated.providerId
      : settings.activeProviderId;
  AiProvider? provider;
  for (final candidate in settings.providers) {
    if (candidate.id == providerId) {
      provider = candidate;
      break;
    }
  }
  final modelId = validated.mode == TranslationModelPreferenceMode.local
      ? validated.modelId ?? ''
      : provider?.effectiveModelId ?? '';
  final decision = ReasoningControlAdapter.resolve(
    providerId: provider?.id,
    providerCode: provider?.providerCode,
    modelId: modelId,
    policy: ChatReasoningPolicy.offIfSupported,
  );
  if (decision.supported) return validated;
  return TranslationModelPreference(
    mode: validated.mode,
    providerId: validated.providerId,
    modelId: validated.modelId,
    reasoningPolicy: ChatReasoningPolicy.providerDefault,
  );
}

/// 快照所指向的模型已经无法按原配置执行。
final class TranslationModelUnavailableException implements Exception {
  final String safeCode;
  final String message;

  const TranslationModelUnavailableException(
    this.message, {
    this.safeCode = 'model_unavailable',
  });

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
            selection: settings.backendSelection,
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
          selection: validated.backendSelection,
        );
    }
  }

  /// 仅供旧任务恢复使用：记忆偏好失效时不借用其他模型，也不阻断现代任务。
  static TranslationRequestProfile? legacyFallbackOrNull(
    AISettings settings,
    TranslationModelPreference preference,
  ) {
    try {
      final profile = snapshot(settings, preference);
      // 此旧接口无法证明任务尚未发送，不能用新明确选择重签历史任务。
      return profile.backendSelection == null ? profile : null;
    } on TranslationModelUnavailableException {
      return null;
    } on FormatException {
      return null;
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
        _verifyBackendSelection(profile.backendSelection);
        _requireModelId(profile.modelId, scope: '后端');
        final next = current.clone();
        next.mode = AIMode.backend;
        next.backendSelection = profile.backendSelection;
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
    ChatReasoningPolicy reasoningPolicy, {
    BackendSelection? selection,
  }) {
    _verifyBackendSelection(selection);
    final resolvedModel =
        _requireModelId(selection?.modelId ?? modelId, scope: '后端');
    return TranslationRequestProfile(
      mode: TranslationExecutionMode.backend,
      modelId: selection?.modelId ?? resolvedModel,
      backendSelection: selection,
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: false,
    );
  }

  static void _verifyBackendSelection(BackendSelection? selection) {
    if (selection == null) return;
    final identity = AiCatalogIdentity.capture();
    if (!identity.authenticated ||
        !selection.isPair ||
        !selection.matchesScope(
            accountHash: identity.account ?? '',
            origin: identity.endpoint.origin)) {
      throw const TranslationModelUnavailableException(
        '原后端选择不可用于当前账号或地址，请重新选择',
        safeCode: 'invalid_backend_selection',
      );
    }
  }

  static AiProvider _requireLocalProvider(
    AISettings settings, {
    required String? providerId,
    required String? modelId,
  }) {
    if (providerId == null || providerId.trim().isEmpty) {
      throw const TranslationModelUnavailableException(
        '本地翻译服务商未配置',
        safeCode: 'providerMissing',
      );
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
        safeCode: 'providerMissing',
      );
    }
    if (!provider.enabled) {
      throw TranslationModelUnavailableException(
        '翻译服务商已停用：$providerId',
        safeCode: 'providerDisabled',
      );
    }
    if (provider.apiKey.trim().isEmpty) {
      throw TranslationModelUnavailableException(
        '翻译服务商缺少 API Key：$providerId',
        safeCode: 'apiKeyMissing',
      );
    }
    final resolvedModel = modelId ?? provider.effectiveModelId;
    _requireModelId(resolvedModel, scope: '本地');
    if (!provider.models.any((model) => model.id == resolvedModel)) {
      throw TranslationModelUnavailableException(
        '翻译模型已从服务商移除：$providerId/$resolvedModel',
        safeCode: 'modelMissing',
      );
    }
    return provider;
  }

  static String _requireModelId(String? modelId, {required String scope}) {
    if (modelId == null || modelId.trim().isEmpty) {
      throw TranslationModelUnavailableException(
        '$scope翻译模型未配置',
        safeCode: 'modelMissing',
      );
    }
    return modelId;
  }
}
