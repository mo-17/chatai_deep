import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';

final class ReasoningControlDecision {
  final bool supported;
  final Map<String, dynamic> requestFields;
  final String explanation;

  const ReasoningControlDecision({
    required this.supported,
    required this.requestFields,
    required this.explanation,
  });
}

/// 将统一的推理策略转换为已确认兼容的服务商请求参数。
abstract final class ReasoningControlAdapter {
  static const policyVersion = 1;

  static const _firstPartyProviders = {
    'deepseek',
    'dashscope',
    'openai',
  };

  static const _deepSeekDualMode = {
    'deepseek-v4-pro',
    'deepseek-v4-flash',
    'deepseek-flash',
    'deepseek-v4-flash-vision-exp',
  };

  static final _qwenThinking = RegExp(r'^qwen3(?:[.-]|$)');

  static const _openAiNone = {
    'gpt-5.1',
    'gpt-5.1-chat-latest',
    'gpt-5.2',
    'gpt-5.2-chat-latest',
  };

  static const _unsupportedParameterCodes = {
    'unknown_parameter',
    'unsupported_parameter',
  };

  static ReasoningControlDecision resolve({
    required String? providerId,
    required String? providerCode,
    required String modelId,
    required ChatReasoningPolicy policy,
    bool suppressed = false,
  }) {
    final provider = _resolveFirstPartyProvider(
      providerId: providerId,
      providerCode: providerCode,
    );
    final supportedFields = _supportedFields(provider, modelId);
    final supported = supportedFields != null;

    if (policy == ChatReasoningPolicy.providerDefault) {
      return ReasoningControlDecision(
        supported: supported,
        requestFields: const {},
        explanation: 'provider_default',
      );
    }
    if (suppressed) {
      return ReasoningControlDecision(
        supported: supported,
        requestFields: const {},
        explanation: 'suppressed',
      );
    }
    if (!supported) {
      return const ReasoningControlDecision(
        supported: false,
        requestFields: {},
        explanation: 'unsupported_provider_or_model',
      );
    }
    return ReasoningControlDecision(
      supported: true,
      requestFields: supportedFields,
      explanation: 'reasoning_disabled',
    );
  }

  static bool isExplicitUnsupportedParameter({
    required int statusCode,
    required String safeErrorCode,
  }) {
    return statusCode == 400 &&
        _unsupportedParameterCodes.contains(safeErrorCode);
  }

  static String? _resolveFirstPartyProvider({
    required String? providerId,
    required String? providerCode,
  }) {
    if (providerId != null && providerId.isNotEmpty) {
      return _firstPartyProviders.contains(providerId) ? providerId : null;
    }
    return _firstPartyProviders.contains(providerCode) ? providerCode : null;
  }

  static Map<String, dynamic>? _supportedFields(
    String? provider,
    String modelId,
  ) {
    if (provider == 'deepseek' && _deepSeekDualMode.contains(modelId)) {
      return const {
        'thinking': {'type': 'disabled'},
      };
    }
    if (provider == 'dashscope' && _qwenThinking.hasMatch(modelId)) {
      return const {'enable_thinking': false};
    }
    if (provider == 'openai' && _openAiNone.contains(modelId)) {
      return const {'reasoning_effort': 'none'};
    }
    return null;
  }
}
