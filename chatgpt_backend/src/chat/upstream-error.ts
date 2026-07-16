import { GatewayTimeoutException, HttpException } from '@nestjs/common';

export type SafeUpstreamCode =
  | 'unknown_parameter'
  | 'unsupported_parameter'
  | 'invalid_request'
  | 'authentication_error'
  | 'rate_limited'
  | 'server_error'
  | 'request_failed';

export interface SafeUpstreamPayload {
  code: 'upstream_error';
  safeCode: SafeUpstreamCode;
  statusCode: number;
  retryAfterSeconds?: number;
  message: string;
}

const SAFE_UPSTREAM_CODES = new Set<SafeUpstreamCode>([
  'unknown_parameter',
  'unsupported_parameter',
  'invalid_request',
  'authentication_error',
  'rate_limited',
  'server_error',
  'request_failed',
]);

export class SafeUpstreamException extends HttpException {
  readonly statusCode: number;
  readonly safeCode: SafeUpstreamCode;
  readonly retryAfterSeconds?: number;
  readonly safePayload: SafeUpstreamPayload;

  constructor(input: {
    statusCode?: number;
    safeCode: SafeUpstreamCode;
    retryAfterSeconds?: number;
  }) {
    const statusCode = safeStatusCode(input.statusCode) ?? 502;
    const retryAfterSeconds = clampRetryAfterSeconds(input.retryAfterSeconds);
    const safePayload = buildSafeUpstreamPayload(
      statusCode,
      input.safeCode,
      retryAfterSeconds,
    );
    super(safePayload, statusCode);
    this.name = 'SafeUpstreamException';
    this.statusCode = statusCode;
    this.safeCode = input.safeCode;
    this.retryAfterSeconds = retryAfterSeconds;
    this.safePayload = safePayload;
  }
}

export function safeUpstreamPayloadFromError(
  error: unknown,
): SafeUpstreamPayload {
  if (error instanceof SafeUpstreamException) return error.safePayload;
  if (error instanceof GatewayTimeoutException) {
    return buildSafeUpstreamPayload(504, 'request_failed', undefined, true);
  }

  const record = asRecord(error);
  const explicitStatus = safeStatusCode(record?.['statusCode']);
  const exceptionStatus =
    error instanceof HttpException ? safeStatusCode(error.getStatus()) : null;
  const statusCode = explicitStatus ?? exceptionStatus ?? 502;
  const suppliedCode = record?.['safeCode'];
  const safeCode = isSafeUpstreamCode(suppliedCode)
    ? suppliedCode
    : explicitStatus !== null || exceptionStatus !== null
      ? safeCodeForStatus(statusCode)
      : 'request_failed';
  return buildSafeUpstreamPayload(
    statusCode,
    safeCode,
    clampRetryAfterSeconds(record?.['retryAfterSeconds']),
  );
}

export async function safeFailureFromResponse(
  response: globalThis.Response,
): Promise<SafeUpstreamException> {
  let payload: Record<string, unknown> | null = null;
  try {
    payload = parseJsonObject(await response.text());
  } catch {
    // 上游 body 读取失败时仍只返回安全元数据。
  }
  return safeFailureFromPayload(
    response.status,
    payload,
    parseRetryAfterHeader(response.headers.get('retry-after')),
  );
}

export function safeFailureFromSsePayload(
  payload: Record<string, unknown> | null,
): SafeUpstreamException {
  const explicitCode = explicitParameterCode(payload);
  const statusCode =
    safeStatusCode(payload?.['statusCode']) ?? (explicitCode ? 400 : 502);
  return safeFailureFromPayload(
    statusCode,
    payload,
    clampRetryAfterSeconds(payload?.['retryAfterSeconds']),
  );
}

function safeFailureFromPayload(
  statusCode: number,
  payload: Record<string, unknown> | null,
  retryAfterSeconds: number | undefined,
): SafeUpstreamException {
  const explicitCode =
    statusCode === 400 ? explicitParameterCode(payload) : undefined;
  return new SafeUpstreamException({
    statusCode,
    safeCode: explicitCode ?? safeCodeForStatus(statusCode),
    retryAfterSeconds,
  });
}

function explicitParameterCode(
  payload: Record<string, unknown> | null,
): 'unknown_parameter' | 'unsupported_parameter' | undefined {
  const error = asRecord(payload?.['error']);
  for (const value of [error?.['code'], error?.['type']]) {
    if (value === 'unknown_parameter' || value === 'unsupported_parameter') {
      return value;
    }
  }
  return undefined;
}

function buildSafeUpstreamPayload(
  statusCode: number,
  safeCode: SafeUpstreamCode,
  retryAfterSeconds?: number,
  timeout = false,
): SafeUpstreamPayload {
  return {
    code: 'upstream_error',
    safeCode,
    statusCode,
    ...(retryAfterSeconds === undefined ? {} : { retryAfterSeconds }),
    message: timeout ? '上游响应超时' : safeMessageForCode(safeCode),
  };
}

function safeMessageForCode(code: SafeUpstreamCode): string {
  switch (code) {
    case 'unknown_parameter':
    case 'unsupported_parameter':
      return '上游不支持请求参数';
    case 'invalid_request':
      return '请求参数无效';
    case 'authentication_error':
      return '身份验证失败';
    case 'rate_limited':
      return '上游请求受限';
    case 'server_error':
      return '上游服务异常';
    case 'request_failed':
      return '请求失败';
  }
}

function safeCodeForStatus(statusCode: number): SafeUpstreamCode {
  if (statusCode === 400) return 'invalid_request';
  if (statusCode === 401 || statusCode === 403) {
    return 'authentication_error';
  }
  if (statusCode === 429) return 'rate_limited';
  if (statusCode >= 500) return 'server_error';
  return 'request_failed';
}

function isSafeUpstreamCode(value: unknown): value is SafeUpstreamCode {
  return (
    typeof value === 'string' &&
    SAFE_UPSTREAM_CODES.has(value as SafeUpstreamCode)
  );
}

function safeStatusCode(value: unknown): number | null {
  return typeof value === 'number' &&
    Number.isInteger(value) &&
    value >= 100 &&
    value <= 599
    ? value
    : null;
}

function clampRetryAfterSeconds(value: unknown): number | undefined {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    return undefined;
  }
  return Math.min(120, Math.max(1, value));
}

function parseRetryAfterHeader(value: string | null): number | undefined {
  if (value === null || !/^\d+$/.test(value)) return undefined;
  const seconds = BigInt(value);
  if (seconds < 1n) return 1;
  if (seconds > 120n) return 120;
  return Number(seconds);
}

function parseJsonObject(text: string): Record<string, unknown> | null {
  if (!text) return null;
  try {
    return asRecord(JSON.parse(text) as unknown);
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object'
    ? (value as Record<string, unknown>)
    : null;
}
