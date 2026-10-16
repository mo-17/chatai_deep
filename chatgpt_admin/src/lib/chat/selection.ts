import { ChatFailure } from './errors';
import { assertChatScope, chatScopeKey, type ChatScope } from './scope';

export interface ChatPair {
  providerCode: string;
  modelId: string;
}
export interface ChatChoice extends ChatPair {
  key: string;
  label: string;
}
export type ChatSelection =
  | { kind: 'none' }
  | { kind: 'pair'; pair: ChatPair }
  | { kind: 'legacy'; modelId: string }
  | { kind: 'unavailable' };
export const pairKey = (pair: ChatPair) =>
  JSON.stringify([pair.providerCode, pair.modelId]);
export const nonblank = (v: unknown): v is string =>
  typeof v === 'string' && /\S/.test(v);
export function readPair(raw: unknown): ChatPair {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw))
    throw new ChatFailure('selection_required');
  const p = raw as Partial<ChatPair>;
  if (!nonblank(p.providerCode) || !nonblank(p.modelId))
    throw new ChatFailure('selection_required');
  return { providerCode: p.providerCode, modelId: p.modelId };
}
export function pairFromKey(raw: string): ChatPair {
  try {
    const p: unknown = JSON.parse(raw);
    if (!Array.isArray(p) || p.length !== 2) throw 0;
    return readPair({ providerCode: p[0], modelId: p[1] });
  } catch {
    throw new ChatFailure('selection_required');
  }
}
export function selectionLabel(
  s: ChatSelection,
  choices: ChatChoice[],
): string {
  if (s.kind === 'pair')
    return (
      choices.find((c) => c.key === pairKey(s.pair))?.label ??
      `${s.pair.providerCode} · ${s.pair.modelId}（已删除/停用或未确认，请重新选择）`
    );
  if (s.kind === 'legacy') return `原模型 ${s.modelId}（服务商待权威确认）`;
  return s.kind === 'unavailable'
    ? '原选择归属或格式无法确认，请重新选择'
    : '未选择服务商和模型';
}
export function choicesFromMetadata(
  providers: unknown,
  models: unknown,
): ChatChoice[] {
  if (!Array.isArray(providers) || !Array.isArray(models))
    throw new ChatFailure('invalid_response');
  const byId = new Map<
    number,
    { code: string; name: string; enabled: boolean }
  >();
  const codes = new Set<string>();
  for (const raw of providers) {
    const p = raw as Record<string, unknown>;
    if (
      !p ||
      !Number.isSafeInteger(p.id) ||
      byId.has(p.id as number) ||
      !nonblank(p.code) ||
      !nonblank(p.displayName) ||
      typeof p.enabled !== 'boolean' ||
      codes.has(p.code)
    )
      throw new ChatFailure('invalid_response');
    codes.add(p.code);
    byId.set(p.id as number, {
      code: p.code,
      name: p.displayName,
      enabled: p.enabled,
    });
  }
  const choices: ChatChoice[] = [],
    seen = new Set<string>();
  for (const raw of models) {
    const m = raw as Record<string, unknown>;
    if (!m || !nonblank(m.modelId) || typeof m.enabled !== 'boolean')
      throw new ChatFailure('invalid_response');
    const p = byId.get(m.providerId as number);
    if (!p) continue;
    if (m.providerCode !== undefined && m.providerCode !== p.code)
      throw new ChatFailure('invalid_response');
    const pair = { providerCode: p.code, modelId: m.modelId },
      key = pairKey(pair);
    if (seen.has(key)) throw new ChatFailure('invalid_response');
    seen.add(key);
    if (p.enabled && m.enabled)
      choices.push({
        ...pair,
        key,
        label: `${p.name}（${p.code}） · ${m.modelId}`,
      });
  }
  return choices;
}
const preferenceKey = (scope: ChatScope) =>
  'ai-chat-pair-v1:' + chatScopeKey(scope);
export function readPreference(scope: ChatScope): ChatSelection {
  assertChatScope(scope);
  const raw = localStorage.getItem(preferenceKey(scope));
  if (raw === null)
    return localStorage.getItem('ai-chat-model') === null
      ? { kind: 'none' }
      : { kind: 'unavailable' };
  try {
    const value: unknown = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw 0;
    const record = value as Record<string, unknown>;
    if (record.version !== 1 || record.scope !== chatScopeKey(scope)) throw 0;
    return { kind: 'pair', pair: readPair(record.pair) };
  } catch {
    return { kind: 'unavailable' };
  }
}
export function writePreference(scope: ChatScope, pair: ChatPair) {
  assertChatScope(scope);
  localStorage.setItem(
    preferenceKey(scope),
    JSON.stringify({
      version: 1,
      scope: chatScopeKey(scope),
      pair: readPair(pair),
    }),
  );
}
