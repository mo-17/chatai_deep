import { resolveReasoningControl } from './reasoning-control';

describe('resolveReasoningControl', () => {
  it.each([
    ['deepseek', 'deepseek-v4-flash', { thinking: { type: 'disabled' } }],
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
