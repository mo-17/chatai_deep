import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';

enum ChatFailureAction {
  retry,
  configureProvider,
  checkBalance,
  chooseModel,
  checkInput,
  none
}

/// 展示层只读取白名单诊断，绝不展示未知 exception/响应正文。
final class ChatFailureDiagnosis {
  final String code;
  final String message;
  final String suggestion;
  final ChatFailureAction action;
  final int? statusCode;
  final ChatFailureStage failureStage;
  final ChatFailureKind failureKind;
  const ChatFailureDiagnosis(
      this.code, this.message, this.suggestion, this.action,
      {this.statusCode,
      this.failureStage = ChatFailureStage.unknown,
      this.failureKind = ChatFailureKind.unknown});

  String get diagnosticReference => '${failureStage.name}/${failureKind.name}';

  static const _storedCodes = {
    'authentication_error',
    'insufficient_balance',
    'model_not_found',
    'invalid_request',
    'rate_limited',
    'server_error',
    'timeout',
    'network_error',
    'invalid_endpoint',
    'invalid_response',
    'attachment_upload_failed',
    'cancelled',
    'request_failed',
  };

  /// 只保存分类与安全枚举，展示文案和按钮动作始终由本地代码重建。
  Map<String, dynamic> toJson() => {
        'version': 1,
        'code': _storedCodes.contains(code) ? code : 'request_failed',
        if (statusCode != null && statusCode! >= 100 && statusCode! <= 599)
          'statusCode': statusCode,
        'failureStage': failureStage.name,
        'failureKind': failureKind.name,
      };

  /// 损坏的可选诊断只丢弃自身，不使其他任务断点失效。
  static ChatFailureDiagnosis? fromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1) return null;
    final code = raw['code'];
    if (code is! String || !_storedCodes.contains(code)) return null;
    final status = raw['statusCode'];
    if (status != null && (status is! int || status < 100 || status > 599)) {
      return null;
    }
    final stage = _decodeEnum(
        ChatFailureStage.values, raw['failureStage'], ChatFailureStage.unknown);
    final kind = _decodeEnum(
        ChatFailureKind.values, raw['failureKind'], ChatFailureKind.unknown);
    if (stage == null || kind == null) return null;
    final canonical = ChatFailureDiagnosis.from(
        ChatTransportException(safeCode: code, safeMessage: ''));
    return ChatFailureDiagnosis(canonical.code, canonical.message,
        canonical.suggestion, canonical.action,
        statusCode: status as int?, failureStage: stage, failureKind: kind);
  }

  factory ChatFailureDiagnosis.from(Object error) {
    if (error is! ChatTransportException) {
      return ChatFailureDiagnosis('request_failed', '请求失败，原因暂未确定',
          '请检查 AI 服务设置或稍后手动重试', ChatFailureAction.retry,
          failureKind: error is TypeError
              ? ChatFailureKind.type
              : error is RangeError
                  ? ChatFailureKind.range
                  : error is StateError
                      ? ChatFailureKind.state
                      : ChatFailureKind.unknown);
    }
    final code = const {'first_event_timeout', 'idle_timeout', 'total_timeout'}
            .contains(error.safeCode)
        ? error.safeCode
        : chatFailureCodeForStatus(error.statusCode) ?? error.safeCode;
    final diagnosis = switch (code) {
      'authentication_error' || 'api_key_missing' => const ChatFailureDiagnosis(
          'authentication_error',
          '身份验证失败',
          '检查服务商 API Key、权限或登录状态',
          ChatFailureAction.configureProvider),
      'insufficient_balance' => const ChatFailureDiagnosis(
          'insufficient_balance',
          '服务商余额不足',
          '前往服务商检查余额或切换可用服务商',
          ChatFailureAction.checkBalance),
      'model_not_found' => const ChatFailureDiagnosis(
          'model_not_found',
          '模型或 API 路由不存在',
          '检查模型名称与 API 地址，刷新模型列表',
          ChatFailureAction.chooseModel),
      'invalid_request' ||
      'unknown_parameter' ||
      'unsupported_parameter' ||
      'unsupported_reasoning_control' =>
        const ChatFailureDiagnosis('invalid_request', '请求参数不受支持或无效',
            '检查模型能力、推理等级、附件及输入预算', ChatFailureAction.checkInput),
      'rate_limited' => const ChatFailureDiagnosis(
          'rate_limited', '请求过于频繁', '等待服务商限流恢复后再试', ChatFailureAction.retry),
      'server_error' => const ChatFailureDiagnosis(
          'server_error', '服务商暂时异常', '稍后重试或切换服务商', ChatFailureAction.retry),
      'timeout' ||
      'connect_timeout' ||
      'first_event_timeout' ||
      'idle_timeout' ||
      'total_timeout' =>
        const ChatFailureDiagnosis('timeout', '网络请求超时', '检查网络与代理，部分回复已保留；可手动继续',
            ChatFailureAction.retry),
      'network_error' => const ChatFailureDiagnosis('network_error', '网络连接失败',
          '检查网络、代理与服务地址后重试', ChatFailureAction.retry),
      'invalid_endpoint' => const ChatFailureDiagnosis(
          'invalid_endpoint',
          'API 地址无效',
          '在 AI 服务设置中检查完整的 HTTP 或 HTTPS 地址',
          ChatFailureAction.configureProvider),
      'invalid_response' => const ChatFailureDiagnosis(
          'invalid_response',
          '服务返回了无法解析的响应',
          '检查 API 地址与模型兼容性，已收到的内容不会自动重发',
          ChatFailureAction.configureProvider),
      'attachment_upload_failed' => const ChatFailureDiagnosis(
          'attachment_upload_failed',
          '附件上传失败',
          '检查文件与网络后重新选择附件',
          ChatFailureAction.checkInput),
      'cancelled' => const ChatFailureDiagnosis(
          'cancelled', '请求已取消', '任务可从已保存的进度手动继续', ChatFailureAction.none),
      _ => const ChatFailureDiagnosis('request_failed', '请求失败，原因暂未确定',
          '请检查 AI 服务设置或稍后手动重试', ChatFailureAction.retry),
    };
    return ChatFailureDiagnosis(diagnosis.code, diagnosis.message,
        diagnosis.suggestion, diagnosis.action,
        statusCode: error.statusCode,
        failureStage: error.failureStage,
        failureKind: error.failureKind);
  }
}

T? _decodeEnum<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw == null) return fallback;
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}

String? chatFailureCodeForStatus(int? status) => switch (status) {
      400 || 422 => 'invalid_request',
      401 || 403 => 'authentication_error',
      402 => 'insufficient_balance',
      404 => 'model_not_found',
      429 => 'rate_limited',
      final int value when value >= 500 => 'server_error',
      _ => null,
    };
