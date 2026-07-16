import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';

enum TranslationModelPreferenceMode { followGlobal, local, backend }

enum TranslationExecutionMode { local, backend }

/// 账号级翻译模型偏好，只保存定位模型所需的非敏感字段。
final class TranslationModelPreference {
  final TranslationModelPreferenceMode mode;
  final String? providerId;
  final String? modelId;
  final ChatReasoningPolicy reasoningPolicy;

  const TranslationModelPreference({
    required this.mode,
    this.providerId,
    this.modelId,
    required this.reasoningPolicy,
  });

  Map<String, dynamic> toJson() {
    _validatePreference(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
    );
    return {
      'mode': mode.name,
      if (providerId != null) 'providerId': providerId,
      if (modelId != null) 'modelId': modelId,
      'reasoningPolicy': reasoningPolicy.name,
    };
  }

  factory TranslationModelPreference.fromJson(Map<String, dynamic> json) {
    final mode = _enumValue(
      json['mode'],
      TranslationModelPreferenceMode.values,
      'mode',
    );
    final providerId = _optionalString(json['providerId'], 'providerId');
    final modelId = _optionalString(json['modelId'], 'modelId');
    final reasoningPolicy = _enumValue(
      json['reasoningPolicy'],
      ChatReasoningPolicy.values,
      'reasoningPolicy',
    );
    _validatePreference(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
    );
    return TranslationModelPreference(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
      reasoningPolicy: reasoningPolicy,
    );
  }
}

/// 翻译任务创建时冻结的执行模型。任务后续重试只消费这份快照。
final class TranslationRequestProfile {
  static const currentVersion = 1;

  final TranslationExecutionMode mode;
  final String? providerId;
  final String modelId;
  final ChatReasoningPolicy reasoningPolicy;
  final bool reasoningControlSuppressed;

  TranslationRequestProfile({
    required this.mode,
    this.providerId,
    required this.modelId,
    required this.reasoningPolicy,
    required this.reasoningControlSuppressed,
  }) {
    _validateProfile(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
    );
  }

  TranslationRequestProfile suppressReasoningControl() {
    if (reasoningControlSuppressed) return this;
    return TranslationRequestProfile(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: true,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'mode': mode.name,
        'providerId': providerId,
        'modelId': modelId,
        'reasoningPolicy': reasoningPolicy.name,
        'reasoningControlSuppressed': reasoningControlSuppressed,
      };

  factory TranslationRequestProfile.fromJson(Map<String, dynamic> json) {
    if (json['version'] != currentVersion) {
      throw const FormatException('不支持的翻译请求快照版本');
    }
    final mode = _enumValue(
      json['mode'],
      TranslationExecutionMode.values,
      'mode',
    );
    final providerId = _optionalString(json['providerId'], 'providerId');
    final modelId = _requiredString(json['modelId'], 'modelId');
    final reasoningPolicy = _enumValue(
      json['reasoningPolicy'],
      ChatReasoningPolicy.values,
      'reasoningPolicy',
    );
    final suppressed = json['reasoningControlSuppressed'];
    if (suppressed is! bool) {
      throw const FormatException('reasoningControlSuppressed 必须是 bool');
    }
    _validateProfile(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
    );
    return TranslationRequestProfile(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: suppressed,
    );
  }
}

T _enumValue<T extends Enum>(Object? raw, List<T> values, String field) {
  if (raw is! String) throw FormatException('$field 必须是枚举名称');
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException('$field 包含未知枚举名称');
}

String? _optionalString(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! String) throw FormatException('$field 必须是字符串');
  return raw;
}

String _requiredString(Object? raw, String field) {
  final value = _optionalString(raw, field);
  if (value == null || value.trim().isEmpty) {
    throw FormatException('$field 不能为空');
  }
  return value;
}

void _validatePreference({
  required TranslationModelPreferenceMode mode,
  required String? providerId,
  required String? modelId,
}) {
  switch (mode) {
    case TranslationModelPreferenceMode.followGlobal:
      if (providerId != null || modelId != null) {
        throw const FormatException('followGlobal 偏好不能固定 providerId 或 modelId');
      }
    case TranslationModelPreferenceMode.local:
      if (providerId == null || providerId.trim().isEmpty) {
        throw const FormatException('local 偏好必须包含 providerId');
      }
      if (modelId == null || modelId.trim().isEmpty) {
        throw const FormatException('local 偏好必须包含 modelId');
      }
    case TranslationModelPreferenceMode.backend:
      if (providerId != null) {
        throw const FormatException('backend 偏好不能包含 providerId');
      }
      if (modelId == null || modelId.trim().isEmpty) {
        throw const FormatException('backend 偏好必须包含 modelId');
      }
  }
}

void _validateProfile({
  required TranslationExecutionMode mode,
  required String? providerId,
  required String modelId,
}) {
  if (modelId.trim().isEmpty) {
    throw const FormatException('modelId 不能为空');
  }
  switch (mode) {
    case TranslationExecutionMode.local:
      if (providerId == null || providerId.trim().isEmpty) {
        throw const FormatException('local 快照必须包含 providerId');
      }
    case TranslationExecutionMode.backend:
      if (providerId != null) {
        throw const FormatException('backend 快照不能包含 providerId');
      }
  }
}
