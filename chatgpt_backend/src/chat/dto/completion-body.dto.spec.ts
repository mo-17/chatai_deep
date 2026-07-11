import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CompletionBodyDto } from './completion-body.dto';

describe('CompletionBodyDto', () => {
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
});
