export type ReasoningPolicy = 'provider_default' | 'off_if_supported';

const deepSeekDualMode = new Set([
  'deepseek-v4-pro',
  'deepseek-v4-flash',
  'deepseek-flash',
  'deepseek-v4-flash-vision-exp',
]);
const qwenThinking = /^qwen3(?:[.-]|$)/;
const openAiNone = new Set([
  'gpt-5.1',
  'gpt-5.1-chat-latest',
  'gpt-5.2',
  'gpt-5.2-chat-latest',
]);

/** 将统一推理策略转换为已确认兼容的 first-party 请求参数。 */
export function resolveReasoningControl(input: {
  providerCode: string;
  modelId: string;
  policy: ReasoningPolicy;
}): Record<string, unknown> {
  if (input.policy === 'provider_default') return {};

  if (
    input.providerCode === 'deepseek' &&
    deepSeekDualMode.has(input.modelId)
  ) {
    return { thinking: { type: 'disabled' } };
  }
  if (input.providerCode === 'dashscope' && qwenThinking.test(input.modelId)) {
    return { enable_thinking: false };
  }
  if (input.providerCode === 'openai' && openAiNone.has(input.modelId)) {
    return { reasoning_effort: 'none' };
  }
  return {};
}
