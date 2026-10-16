import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';

enum TranslationModelPreferenceMode { followGlobal, local, backend }

enum TranslationExecutionMode { local, backend }

/// 账号级翻译模型偏好，只保存定位模型所需的非敏感字段。
final class TranslationModelPreference {
  final TranslationModelPreferenceMode mode;
  final String? providerId;
  final String? modelId;
  final ChatReasoningPolicy reasoningPolicy;
  final BackendSelection? backendSelection;
  final bool isUnavailable;

  const TranslationModelPreference({
    required this.mode,
    this.providerId,
    this.modelId,
    required this.reasoningPolicy,
    this.backendSelection,
  }) : isUnavailable = false;

  /// 明确的新格式损坏时不能伪装成 followGlobal；原存储值由 store 保留。
  const TranslationModelPreference.unavailable()
      : mode = TranslationModelPreferenceMode.backend,
        providerId = null,
        modelId = null,
        reasoningPolicy = ChatReasoningPolicy.providerDefault,
        backendSelection = null,
        isUnavailable = true;

  Map<String, dynamic> toJson() {
    if (isUnavailable) throw const FormatException('翻译模型偏好无效，请重新选择');
    _validatePreference(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
    );
    _validatePair(mode == TranslationModelPreferenceMode.backend, modelId,
        backendSelection);
    return {
      if (backendSelection != null) 'version': 2,
      'mode': mode.name,
      if (providerId != null) 'providerId': providerId,
      if (modelId != null) 'modelId': modelId,
      'reasoningPolicy': reasoningPolicy.name,
      if (backendSelection != null)
        'backendSelection': backendSelection!.toSafeJson(),
    };
  }

  factory TranslationModelPreference.fromJson(Map<String, dynamic> json) {
    final modern =
        json.containsKey('version') || json.containsKey('backendSelection');
    if (modern &&
        (json['version'] != 2 ||
            !_keys(json, {
              'version',
              'mode',
              'providerId',
              'modelId',
              'reasoningPolicy',
              'backendSelection'
            }))) {
      throw const FormatException('翻译模型偏好版本或字段无效');
    }
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
    final selection =
        modern ? BackendSelection.fromStorage(json['backendSelection']) : null;
    if (modern && selection == null) {
      throw const FormatException('翻译模型偏好缺少明确选择');
    }
    _validatePair(
        mode == TranslationModelPreferenceMode.backend, modelId, selection);
    return TranslationModelPreference(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
      reasoningPolicy: reasoningPolicy,
      backendSelection: selection,
    );
  }
}

/// 翻译任务创建时冻结的执行模型。任务后续重试只消费这份快照。
final class TranslationRequestProfile {
  static const currentVersion = 2;

  final TranslationExecutionMode mode;
  final String? providerId;
  final String modelId;
  final ChatReasoningPolicy reasoningPolicy;
  final bool reasoningControlSuppressed;
  final BackendSelection? backendSelection;
  final int version;

  TranslationRequestProfile({
    required this.mode,
    this.providerId,
    required this.modelId,
    required this.reasoningPolicy,
    required this.reasoningControlSuppressed,
    this.backendSelection,
    int? version,
  }) : version = version ?? (backendSelection == null ? 1 : currentVersion) {
    _validateProfile(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
    );
    if (this.version != 1 && this.version != currentVersion ||
        (this.version == currentVersion) != (backendSelection != null)) {
      throw const FormatException('翻译请求快照版本或选择无效');
    }
    _validatePair(
        mode == TranslationExecutionMode.backend, modelId, backendSelection);
  }

  TranslationRequestProfile suppressReasoningControl() {
    if (reasoningControlSuppressed) return this;
    return TranslationRequestProfile(
      mode: mode,
      providerId: providerId,
      modelId: modelId,
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: true,
      backendSelection: backendSelection,
      version: version,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'mode': mode.name,
        'providerId': providerId,
        'modelId': modelId,
        'reasoningPolicy': reasoningPolicy.name,
        'reasoningControlSuppressed': reasoningControlSuppressed,
        if (backendSelection != null)
          'backendSelection': backendSelection!.toSafeJson(),
      };

  factory TranslationRequestProfile.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 && json['version'] != currentVersion) {
      throw const FormatException('不支持的翻译请求快照版本');
    }
    if (!_keys(json, {
      'version',
      'mode',
      'providerId',
      'modelId',
      'reasoningPolicy',
      'reasoningControlSuppressed',
      if (json['version'] == currentVersion) 'backendSelection'
    })) {
      throw const FormatException('翻译请求快照包含未知字段');
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
      version: json['version'] as int,
      backendSelection: json['version'] == currentVersion
          ? BackendSelection.fromStorage(json['backendSelection'])
          : null,
    );
  }
}

bool _keys(Map<String, dynamic> value, Set<String> allowed) =>
    value.keys.every(allowed.contains);

void _validatePair(bool backend, String? modelId, BackendSelection? selection) {
  if (selection == null) return;
  if (!backend || !selection.isPair || selection.modelId != modelId) {
    throw const FormatException('翻译模型选择与快照不一致');
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
