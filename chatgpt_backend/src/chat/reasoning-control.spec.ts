import {
  resolveReasoningControl,
  type ReasoningEffort,
} from './reasoning-control';

describe('resolveReasoningControl', () => {
  it.each(['low', 'high', 'max'] as const)(
    'enables selected DeepSeek effort %s only for supported dual-mode models',
    (effort) => {
      for (const modelId of [
        'deepseek-v4-pro',
        'deepseek-v4-flash',
        'deepseek-flash',
        'deepseek-v4-flash-vision-exp',
      ]) {
        expect(
          resolveReasoningControl({
            providerCode: 'deepseek',
            modelId,
            policy: 'provider_default',
            effort,
          }),
        ).toEqual({ thinking: { type: 'enabled' }, reasoning_effort: effort });
      }
    },
  );

  it('prioritizes disabling thinking over an effort selection', () => {
    expect(
      resolveReasoningControl({
        providerCode: 'deepseek',
        modelId: 'deepseek-flash',
        policy: 'off_if_supported',
        effort: 'max',
      }),
    ).toEqual({ thinking: { type: 'disabled' } });
  });

  it.each([
    ['deepseek', 'deepseek-reasoner'],
    ['deepseek', 'deepseek-flash-custom'],
    ['custom', 'deepseek-flash'],
    ['openrouter', 'deepseek-v4-pro'],
    ['openai', 'gpt-5.2'],
    ['dashscope', 'qwen3.5-plus'],
  ])('omits DeepSeek effort for %s/%s', (providerCode, modelId) => {
    expect(
      resolveReasoningControl({
        providerCode,
        modelId,
        policy: 'provider_default',
        effort: 'max',
      }),
    ).toEqual({});
  });

  it('does not forward malformed effort values outside DTO validation', () => {
    expect(
      resolveReasoningControl({
        providerCode: 'deepseek',
        modelId: 'deepseek-flash',
        policy: 'provider_default',
        effort: 'unlimited' as ReasoningEffort,
      }),
    ).toEqual({});
  });

  it.each([
    ['deepseek', 'deepseek-v4-flash', { thinking: { type: 'disabled' } }],
    ['deepseek', 'deepseek-flash', { thinking: { type: 'disabled' } }],
    [
      'deepseek',
      'deepseek-v4-flash-vision-exp',
      { thinking: { type: 'disabled' } },
    ],
    ['dashscope', 'qwen3.5-plus', { enable_thinking: false }],
    ['openai', 'gpt-5.2', { reasoning_effort: 'none' }],
    ['gemini', 'gemini-2.5-pro', {}],
    ['openrouter', 'openai/gpt-5.2', {}],
    ['custom_1', 'deepseek-v4-flash', {}],
  ])(
    'maps first-party provider %s and model %s to the expected fields',
    (providerCode, modelId, expected) => {
      expect(
        resolveReasoningControl({
          providerCode,
          modelId,
          policy: 'off_if_supported',
        }),
      ).toEqual(expected);
    },
  );

  it.each([
    ['deepseek', 'deepseek-v4-pro', true],
    ['deepseek', 'deepseek-v4-flash', true],
    ['deepseek', 'deepseek-flash', true],
    ['deepseek', 'deepseek-v4-flash-vision-exp', true],
    ['deepseek', 'deepseek-flash-custom', false],
    ['deepseek', 'deepseek-reasoner', false],
    ['deepseek', 'DeepSeek-V4-Pro', false],
    ['dashscope', 'qwen3', true],
    ['dashscope', 'qwen3.5-plus', true],
    ['dashscope', 'qwen3-max', true],
    ['dashscope', 'qwen30-plus', false],
    ['dashscope', 'Qwen3.5-plus', false],
    ['openai', 'gpt-5.1', true],
    ['openai', 'gpt-5.1-chat-latest', true],
    ['openai', 'gpt-5.2', true],
    ['openai', 'gpt-5.2-chat-latest', true],
    ['openai', 'gpt-5', false],
    ['openai', 'gpt-5.2-mini', false],
  ])(
    'keeps the conservative allowlist for %s/%s',
    (providerCode, modelId, expectedSupported) => {
      const fields = resolveReasoningControl({
        providerCode,
        modelId,
        policy: 'off_if_supported',
      });

      expect(Object.keys(fields).length > 0).toBe(expectedSupported);
    },
  );

  it.each([
    ['deepseek', 'deepseek-v4-flash'],
    ['deepseek', 'deepseek-flash'],
    ['deepseek', 'deepseek-v4-flash-vision-exp'],
    ['dashscope', 'qwen3.5-plus'],
    ['openai', 'gpt-5.2'],
    ['custom_1', 'gpt-5.2'],
  ])(
    'leaves request fields unchanged for provider_default: %s/%s',
    (providerCode, modelId) => {
      expect(
        resolveReasoningControl({
          providerCode,
          modelId,
          policy: 'provider_default',
        }),
      ).toEqual({});
    },
  );
});
