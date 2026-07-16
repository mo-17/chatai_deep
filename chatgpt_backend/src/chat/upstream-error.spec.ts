import {
  SafeUpstreamException,
  safeFailureFromResponse,
  safeFailureFromSsePayload,
  safeUpstreamPayloadFromError,
} from './upstream-error';

describe('safe upstream errors', () => {
  it('accepts only an exact 400 error code and clamps decimal Retry-After', async () => {
    const failure = await safeFailureFromResponse(
      new Response(
        JSON.stringify({
          error: {
            code: 'unsupported_parameter',
            message: 'SECRET provider detail',
          },
        }),
        { status: 400, headers: { 'Retry-After': '999' } },
      ),
    );

    expect(failure).toBeInstanceOf(SafeUpstreamException);
    expect(failure.statusCode).toBe(400);
    expect(failure.safeCode).toBe('unsupported_parameter');
    expect(failure.retryAfterSeconds).toBe(120);
    expect(String(failure)).not.toContain('SECRET provider detail');
  });

  it('does not infer an unsupported parameter from a fuzzy upstream message', async () => {
    const failure = await safeFailureFromResponse(
      new Response(
        JSON.stringify({
          error: { message: 'unknown parameter: thinking' },
        }),
        { status: 400 },
      ),
    );

    expect(failure.safeCode).toBe('invalid_request');
    expect(String(failure)).not.toContain('unknown parameter: thinking');
  });

  it('normalizes SSE metadata without trusting its message', () => {
    const failure = safeFailureFromSsePayload({
      statusCode: 429,
      retryAfterSeconds: 0,
      error: { message: 'SECRET rate-limit detail' },
    });

    expect(failure.safeCode).toBe('rate_limited');
    expect(failure.retryAfterSeconds).toBe(1);
    expect(String(failure)).not.toContain('SECRET rate-limit detail');
  });

  it('builds the fixed controller payload from allowlisted fields only', () => {
    const payload = safeUpstreamPayloadFromError(
      Object.assign(new Error('SECRET transport detail'), {
        statusCode: 429,
        safeCode: 'rate_limited',
        retryAfterSeconds: 12,
      }),
    );

    expect(payload).toEqual({
      code: 'upstream_error',
      safeCode: 'rate_limited',
      statusCode: 429,
      retryAfterSeconds: 12,
      message: '上游请求受限',
    });
    expect(JSON.stringify(payload)).not.toContain('SECRET transport detail');
  });

  it.each([
    ['first_event_timeout', '首个响应事件超时'],
    ['idle_timeout', '上游响应空闲超时'],
    ['total_timeout', '上游响应总时长超时'],
  ])('preserves allowlisted deadline code %s', (safeCode, message) => {
    const payload = safeUpstreamPayloadFromError(
      Object.assign(new Error('SECRET timeout detail'), {
        statusCode: 504,
        safeCode,
      }),
    );

    expect(payload).toEqual({
      code: 'upstream_error',
      safeCode,
      statusCode: 504,
      message,
    });
    expect(JSON.stringify(payload)).not.toContain('SECRET');
  });
});
