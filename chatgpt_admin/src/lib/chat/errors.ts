const messages: Record<string, string> = {
  model_ambiguous: '原模型属于多个服务商，请明确重新选择服务商和模型',
  model_unavailable: '原模型已删除或停用，请重新选择',
  provider_unavailable: '原服务商已停用或配置不可用，请重新选择或联系管理员',
  catalog_not_public: '模型清单未开放，请联系管理员或明确选择服务商和模型',
  invalid_request: '请求参数无效，请检查模型选择与输入',
  chat_permission_denied: '需要管理员权限',
  conversation_unavailable: '会话不存在或不可访问，请重新读取列表',
  conversation_request_failed: '会话请求未完成，请重新读取记录后再操作',
  authentication_error: '鉴权失败，请检查登录或后台服务商配置',
  rate_limited: '请求受到限流；不会自动重发，请明确决定下一次操作',
  server_error: '请求未完成；结果可能未知，请核对记录',
  request_failed: '请求未正常完成；不会自动重发，请核对记录',
  first_event_timeout: '等待模型响应超时，结果可能未知',
  idle_timeout: '响应中断，已收到的内容会保留',
  total_timeout: '请求超时，结果可能未知',
  unsupported_reasoning_control: '原配置不支持本次推理参数，请检查后台配置',
  unknown_parameter: '后台请求参数不受支持，请检查配置',
  unsupported_parameter: '后台请求参数不受支持，请检查配置',
  scope_changed: '账号、来源或当前请求已变化，请重新打开目标会话',
  invalid_response: '响应格式无效，请核对记录；不会自动重发',
  stream_incomplete: '响应未完整结束，请核对已收到的内容；不会自动重发',
  cancelled: '请求已停止；上游可能已处理或计费',
  selection_required: '请明确选择服务商和模型',
  ownership_unverified: '原会话归属无法确认，请重新读取当前账号的列表',
  create_unknown: '创建结果未确认，请刷新列表核对；不会重复创建',
  save_unknown: '保存结果未确认，请重新读取记录；不会重复补写',
};
export const configurationCodes = new Set([
  'model_ambiguous',
  'model_unavailable',
  'provider_unavailable',
  'catalog_not_public',
  'selection_required',
]);
export class ChatFailure extends Error {
  readonly autoRetry = false;
  constructor(
    readonly safeCode: string,
    readonly status?: number,
    readonly authError = false,
  ) {
    super(messages[safeCode] ?? messages.request_failed);
    this.name = 'ChatFailure';
  }
}
export function safeChatFailure(raw: unknown, status?: number): ChatFailure {
  if (raw instanceof ChatFailure) return raw;
  const value =
    raw && typeof raw === 'object' && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  const supplied = value.safeCode;
  const code =
    typeof supplied === 'string' && Object.hasOwn(messages, supplied)
      ? supplied
      : status === 400
        ? 'invalid_request'
        : status === 401
          ? 'authentication_error'
          : status === 403
            ? 'chat_permission_denied'
            : status === 429
              ? 'rate_limited'
              : status && status >= 500
                ? 'server_error'
                : 'request_failed';
  return new ChatFailure(
    code,
    status,
    code === 'authentication_error' &&
      status === 401 &&
      value.authError === true,
  );
}
