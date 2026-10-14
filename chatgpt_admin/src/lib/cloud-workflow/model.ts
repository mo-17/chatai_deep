// 生产闸门不读取环境变量、URL或浏览器存储。合成开启仅由测试依赖注入。
export const CLOUD_DISABLED_NOTICE = '云任务暂未启用，离线退出策略尚待确认';
export const CLOUD_CONSENT = 'cloud-text-v1';
export const CLOUD_ROLES = ['analysis', 'writing', 'review'] as const;
export type Role = typeof CLOUD_ROLES[number];
export const CLOUD_STATES = ['queued', 'running', 'paused', 'needs_configuration', 'budget_exhausted', 'cancelling', 'cancelled', 'complete', 'failed', 'unknown', 'deleted'] as const;
export type State = typeof CLOUD_STATES[number];
export type JsonRow = Record<string, unknown>;
export class CloudContractError extends Error { constructor() { super('云任务数据不符合有界文本合同'); } }
export function row(v: unknown, keys?: string[]): JsonRow {
  if (!v || typeof v !== 'object' || Array.isArray(v) || Object.getPrototypeOf(v) !== Object.prototype) throw new CloudContractError();
  const r = v as JsonRow;
  if (keys && (Object.keys(r).length !== keys.length || keys.some(k => !(k in r)) || Object.keys(r).some(k => !keys.includes(k)))) throw new CloudContractError();
  return r;
}
export function integer(v: unknown, min = 1, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof v !== 'number' || !Number.isSafeInteger(v) || v < min || v > max) throw new CloudContractError();
  return v;
}
export function uuid(v: unknown): string {
  if (typeof v !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)) throw new CloudContractError();
  return v.toLowerCase();
}
export function digest(v: unknown): string {
  if (typeof v !== 'string' || !/^[a-f0-9]{64}$/.test(v)) throw new CloudContractError();
  return v;
}
export function bytes(s: string): number { return new TextEncoder().encode(s).length; }
export function text(v: unknown, maxBytes: number): string {
  if (typeof v !== 'string' || !v.trim() || v.includes('\0') || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(v) || bytes(v) > maxBytes) throw new CloudContractError();
  return v;
}
export function canonical(v: unknown): string {
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (v !== null && typeof v === 'object') return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical((v as JsonRow)[k])).join(',') + '}';
  if (v === undefined || (typeof v === 'number' && !Number.isFinite(v))) throw new CloudContractError();
  return JSON.stringify(v);
}
export async function hash(s: string): Promise<string> {
  const data = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(data), b => b.toString(16).padStart(2, '0')).join('');
}
export function freeze<T>(v: T): T {
  if (v && typeof v === 'object') { Object.values(v).forEach(freeze); Object.freeze(v); }
  return v;
}
export function bounded(v: unknown, depth = 0): void {
  if (depth > 12 || (Array.isArray(v) && v.length > 200) || (v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length > 100)) throw new CloudContractError();
  if (v && typeof v === 'object') Object.values(v).forEach(c => bounded(c, depth + 1));
}
export function state(v: unknown): State {
  if (!CLOUD_STATES.includes(v as State)) throw new CloudContractError();
  return v as State;
}
export const stateLabel = (s: State): string => ({ queued: '已接受，等待执行', running: '执行中', paused: '已暂停', needs_configuration: '需要模型配置', budget_exhausted: '预算已用尽', cancelling: '正在停止', cancelled: '已停止', complete: '已完成', failed: '失败', unknown: '执行结果未知', deleted: '已删除' }[s]);
export const pollable = (s: State) => ['queued', 'running', 'cancelling'].includes(s);
export interface Profile { providerId: number; modelRowId: number; modelId: string; providerName: string; modelName: string; }
export function profile(v: unknown): Profile {
  const r = row(v, ['providerId', 'modelRowId', 'modelId', 'providerName', 'modelName']);
  return freeze({ providerId: integer(r.providerId, 1, 2147483647), modelRowId: integer(r.modelRowId, 1, 2147483647), modelId: text(r.modelId, 240), providerName: text(r.providerName, 240), modelName: text(r.modelName, 240) });
}
export interface Acceptance { format: 'txt' | 'md' | 'csv'; outputName: string; minChars: number; maxChars: number; requiredTerms: string[]; requireFullRead: boolean; }
export interface Budget { attempts: number; estimatedTokens: number; outputTokens: number; durationMs: number; reworks: number; }
export interface DraftSource { kind: 'draft'; id: string; revision: number; contentHash: string; }
export interface Draft { id: string; revision: number; task: string; inputs: { title: string; text: string }[]; profiles: Partial<Record<Role, Profile>>; acceptance: Acceptance; budget: Budget; requiredTermsText?: string; }
export function newDraft(): Draft {
  return { id: crypto.randomUUID(), revision: 1, task: '', inputs: [], profiles: {}, acceptance: { format: 'md', outputName: 'result.md', minChars: 0, maxChars: 12000, requiredTerms: [], requireFullRead: true }, budget: { attempts: 8, estimatedTokens: 32000, outputTokens: 2048, durationMs: 600000, reworks: 1 } };
}
export interface Payload { version: 2; consentVersion: string; idempotencyKey: string; clientInstanceId: string; source: DraftSource; task: string; inputs: { title: string; text: string; contentHash: string }[]; profiles: Record<Role, { providerId: number; modelRowId: number }>; acceptance: Acceptance; budget: Budget; grantDurationMs: number; }
export interface Preview { payload: Payload; encoded: string; digest: string; revision: number; profiles: Record<Role, Profile>; }
export function draftSource(v: unknown): DraftSource {
  const r = row(v, ['kind', 'id', 'revision', 'contentHash']);
  if (r.kind !== 'draft') throw new CloudContractError();
  return { kind: 'draft', id: uuid(r.id), revision: integer(r.revision), contentHash: digest(r.contentHash) };
}
export async function validatePayload(v: unknown): Promise<Payload> {
  bounded(v);
  const r = row(v, ['version', 'consentVersion', 'idempotencyKey', 'clientInstanceId', 'source', 'task', 'inputs', 'profiles', 'acceptance', 'budget', 'grantDurationMs']);
  if (r.version !== 2 || r.consentVersion !== CLOUD_CONSENT || bytes(canonical(v)) > 48000) throw new CloudContractError();
  const task = text(r.task, 12000), source = draftSource(r.source);
  if (source.contentHash !== await hash(task)) throw new CloudContractError();
  if (!Array.isArray(r.inputs) || r.inputs.length > 4) throw new CloudContractError();
  const inputs = [];
  for (const input of r.inputs) {
    const i = row(input, ['title', 'text', 'contentHash']);
    const value = text(i.text, 12000), contentHash = digest(i.contentHash);
    if (contentHash !== await hash(value)) throw new CloudContractError();
    inputs.push({ title: text(i.title, 240), text: value, contentHash });
  }
  if (inputs.reduce((n, i) => n + bytes(i.text), 0) > 24000) throw new CloudContractError();
  const p = row(r.profiles, [...CLOUD_ROLES]);
  const profiles = {} as Payload['profiles'];
  for (const role of CLOUD_ROLES) { const a = row(p[role], ['providerId', 'modelRowId']); profiles[role] = { providerId: integer(a.providerId, 1, 2147483647), modelRowId: integer(a.modelRowId, 1, 2147483647) }; }
  const a = row(r.acceptance, ['format', 'outputName', 'minChars', 'maxChars', 'requiredTerms', 'requireFullRead']);
  const outputName = text(a.outputName, 120);
  if (!['txt', 'md', 'csv'].includes(a.format as string) || !/^[a-zA-Z0-9_\-\u4e00-\u9fff][a-zA-Z0-9_.\-\u4e00-\u9fff]{0,100}\.(txt|md|csv)$/.test(outputName) || !outputName.endsWith('.' + a.format) || typeof a.requireFullRead !== 'boolean' || !Array.isArray(a.requiredTerms) || a.requiredTerms.length > 20) throw new CloudContractError();
  const minChars = integer(a.minChars, 0, 12000), maxChars = integer(a.maxChars, 1, 12000), requiredTerms = a.requiredTerms.map(x => text(x, 120));
  if (minChars > maxChars || new Set(requiredTerms).size !== requiredTerms.length) throw new CloudContractError();
  const b = row(r.budget, ['attempts', 'estimatedTokens', 'outputTokens', 'durationMs', 'reworks']);
  const budget = { attempts: integer(b.attempts, 1, 8), estimatedTokens: integer(b.estimatedTokens, 2048, 32000), outputTokens: integer(b.outputTokens, 1, 2048), durationMs: integer(b.durationMs, 1, 600000), reworks: integer(b.reworks, 0, 1) };
  return freeze({ version: 2, consentVersion: CLOUD_CONSENT, idempotencyKey: uuid(r.idempotencyKey), clientInstanceId: uuid(r.clientInstanceId), source, task, inputs, profiles, acceptance: { format: a.format as Acceptance['format'], outputName, minChars, maxChars, requiredTerms, requireFullRead: a.requireFullRead }, budget, grantDurationMs: integer(r.grantDurationMs, 1, 600000) });
}
export async function makePreview(d: Draft): Promise<Preview> {
  // 原始编辑副本先克隆，所有await后由协调器校验draft revision和会话。
  const copy = structuredClone(d), inputs = [];
  // 编辑原文只属于本页草稿；预览时才投影为有界协议数组，不进入receipt。
  if (copy.requiredTermsText !== undefined) copy.acceptance.requiredTerms = copy.requiredTermsText.split('\n').map(s => s.trim()).filter(Boolean);
  for (const i of copy.inputs) inputs.push({ ...i, contentHash: await hash(i.text) });
  const profiles = {} as Record<Role, Profile>, ids = {} as Payload['profiles'];
  for (const role of CLOUD_ROLES) { profiles[role] = profile(copy.profiles[role]); ids[role] = { providerId: profiles[role].providerId, modelRowId: profiles[role].modelRowId }; }
  const payload = await validatePayload({ version: 2, consentVersion: CLOUD_CONSENT, idempotencyKey: crypto.randomUUID(), clientInstanceId: crypto.randomUUID(), source: { kind: 'draft', id: copy.id, revision: copy.revision, contentHash: await hash(copy.task) }, task: copy.task, inputs, profiles: ids, acceptance: copy.acceptance, budget: copy.budget, grantDurationMs: copy.budget.durationMs });
  const encoded = canonical(payload);
  return freeze({ payload, encoded, digest: await hash(encoded), revision: copy.revision, profiles });
}
export interface Capability { ownerId: number; available: boolean; }
export function capability(v: unknown): Capability {
  const r = row(v);
  if (typeof r.available !== 'boolean' || r.destination !== 'cloud' || r.consentVersion !== CLOUD_CONSENT) throw new CloudContractError();
  return { ownerId: integer(r.ownerId, 1, 2147483647), available: r.available };
}
export interface Summary { id: string; ownerId: number; state: State; revision: number; }
export function summary(v: unknown): Summary { const r = row(v); return freeze({ id: uuid(r.id), ownerId: integer(r.owner_id), state: state(r.state), revision: integer(r.revision) }); }
export interface Step { id: string; role: Role; state: State; revision: number; resultVersion: number; }
export interface Detail extends Summary { publicationId: string; finalResultId: string | null; steps: Step[]; payloadHash: string; payload: JsonRow | null; attemptsUsed: number; estimatedTokens: number; reason: string | null; }
export async function detail(v: unknown): Promise<Detail> {
  const r = row(v), p = row(r.parent), head = summary(p);
  const payload = p.payload == null ? null : row(p.payload);
  if (head.state !== 'deleted' && (!payload || ![1, 2].includes(payload.version as number) || digest(p.payload_hash) !== await hash(canonical(payload)))) throw new CloudContractError();
  if (!Array.isArray(r.steps) || r.steps.length !== 3) throw new CloudContractError();
  const steps = r.steps.map(v => { const s = row(v); if (!CLOUD_ROLES.includes(s.role as Role) || !['queued', 'running', 'complete', 'failed', 'unknown'].includes(s.state as string)) throw new CloudContractError(); return { id: uuid(s.id), role: s.role as Role, state: state(s.state), revision: integer(s.revision), resultVersion: integer(s.result_version, 0, 8) }; });
  if (new Set(steps.map(s => s.role)).size !== 3 || new Set(steps.map(s => s.id)).size !== 3) throw new CloudContractError();
  return freeze({ ...head, publicationId: uuid(p.publication_id), finalResultId: p.final_result_id == null ? null : uuid(p.final_result_id), steps, payloadHash: digest(p.payload_hash), payload, attemptsUsed: integer(p.attempts_used, 0, 8), estimatedTokens: integer(p.estimated_tokens, 0, 32000), reason: p.reason == null ? null : text(p.reason, 240) });
}
export interface Result { id: string; stepId: string; version: number; content: string; hash: string; publicationId: string; }
export async function result(v: unknown): Promise<Result> {
  const r = row(v, ['id', 'step_id', 'version', 'content', 'content_hash', 'publication_id']), content = text(r.content, 48000);
  if ([...content].length > 12000 || await hash(content) !== digest(r.content_hash)) throw new CloudContractError();
  return freeze({ id: uuid(r.id), stepId: uuid(r.step_id), version: integer(r.version, 1, 8), content, hash: digest(r.content_hash), publicationId: uuid(r.publication_id) });
}
export function finalWriting(d: Detail | null, results: Result[]): Result | null {
  if (!d || d.state !== 'complete') return null;
  const writer = d.steps.find(s => s.role === 'writing'), output = results.find(r => r.id === d.finalResultId);
  if (!writer || !output || writer.state !== 'complete' || output.stepId !== writer.id || output.version !== writer.resultVersion || output.publicationId !== d.publicationId) throw new CloudContractError();
  return output;
}
export interface ServerReceipt { id: string; ownerId: number; state: State; revision: number; payloadHash: string; source: JsonRow | null; publicationId: string; finalResultId: string | null; }
export function serverReceipt(v: unknown): ServerReceipt {
  const r = row(v, ['id', 'ownerId', 'state', 'revision', 'payloadHash', 'source', 'publicationId', 'finalResultId']);
  return freeze({ id: uuid(r.id), ownerId: integer(r.ownerId), state: state(r.state), revision: integer(r.revision), payloadHash: digest(r.payloadHash), source: r.source === null ? null : row(r.source), publicationId: uuid(r.publicationId), finalResultId: r.finalResultId === null ? null : uuid(r.finalResultId) });
}
