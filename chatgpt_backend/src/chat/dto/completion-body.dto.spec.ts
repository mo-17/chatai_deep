import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CompletionBodyDto } from './completion-body.dto';

describe('CompletionBodyDto', () => {
  it.each([
    ['standard', 'provider_default'],
    ['translation', 'off_if_supported'],
  ])(
    'keeps validated semantic options %s / %s and strips lifecycle internals',
    async (requestProfile, reasoningPolicy) => {
      const body = plainToInstance(CompletionBodyDto, {
        model: 'test-model',
        messages: [],
        request_profile: requestProfile,
        reasoning_policy: reasoningPolicy,
        deadline_ms: 300_000,
        first_event_timeout_ms: 45_000,
        idle_timeout_ms: 60_000,
        cancel_token: 'private-token',
        signal: 'not-a-signal',
      });

      const errors = await validate(body, { whitelist: true });

      expect(errors).toHaveLength(0);
      expect(body.request_profile).toBe(requestProfile);
      expect(body.reasoning_policy).toBe(reasoningPolicy);
      expect(body).not.toHaveProperty('deadline_ms');
      expect(body).not.toHaveProperty('first_event_timeout_ms');
      expect(body).not.toHaveProperty('idle_timeout_ms');
      expect(body).not.toHaveProperty('cancel_token');
      expect(body).not.toHaveProperty('signal');
    },
  );

  it.each([
    ['request_profile', 'bulk_translation'],
    ['request_profile', 'translation '],
    ['reasoning_policy', 'off'],
    ['reasoning_policy', 'OFF_IF_SUPPORTED'],
  ])('rejects unsupported semantic option %s=%s', async (field, value) => {
    const body = plainToInstance(CompletionBodyDto, {
      model: 'test-model',
      messages: [],
      [field]: value,
    });

    const errors = await validate(body, { whitelist: true });

    expect(errors.some((error) => error.property === field)).toBe(true);
  });

  it('keeps a valid temperature when whitelist validation is enabled', async () => {
    const source = {
      model: 'test-model',
      messages: [],
      temperature: 0.75,
      unknown: 'removed',
    };
    const body = plainToInstance(CompletionBodyDto, source);

    const errors = await validate(body, { whitelist: true });

    expect(errors).toHaveLength(0);
    expect(body.temperature).toBe(0.75);
    expect(
      (body as unknown as Record<string, unknown>).unknown,
    ).toBeUndefined();
  });

  it('rejects a temperature outside the supported range', async () => {
    const body = plainToInstance(CompletionBodyDto, {
      model: 'test-model',
      messages: [],
      temperature: 2.1,
    });

    const errors = await validate(body, { whitelist: true });

    expect(errors.some((error) => error.property === 'temperature')).toBe(true);
  });

  it('keeps a valid top_p when whitelist validation is enabled', async () => {
    const source = {
      model: 'test-model',
      messages: [],
      top_p: 0,
      unknown: 'removed',
    };
    const body = plainToInstance(CompletionBodyDto, source);

    const errors = await validate(body, { whitelist: true });

    expect(errors).toHaveLength(0);
    expect(body.top_p).toBe(0);
    expect(
      (body as unknown as Record<string, unknown>).unknown,
    ).toBeUndefined();
  });

  it.each([-0.01, 1.01])('rejects top_p outside [0, 1]: %s', async (top_p) => {
    const body = plainToInstance(CompletionBodyDto, {
      model: 'test-model',
      messages: [],
      top_p,
    });

    const errors = await validate(body, { whitelist: true });

    expect(errors.some((error) => error.property === 'top_p')).toBe(true);
  });
});
