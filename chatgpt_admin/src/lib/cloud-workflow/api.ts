import { bounded, capability, CLOUD_DISABLED_NOTICE, CloudContractError, detail, integer, Profile, profile, Result, result, row, ServerReceipt, serverReceipt, state, Summary, summary, uuid } from './model';

export interface CloudSession { origin: string; frontendOrigin: string; token: string | null; epoch: number; }
export class CloudSessionStale extends Error { constructor() { super('云任务会话已变化，请重新打开'); } }
export class CloudHttpError extends Error { constructor(readonly status: number) { super(`云任务请求失败（HTTP ${status}）`); } }
export interface ApiDependencies { session: CloudSession; current: () => CloudSession; fetch?: typeof fetch; onCurrent401?: () => void; }
export class CloudApi {
  readonly session: Readonly<CloudSession>;
  private readonly current: () => CloudSession;
  private readonly send: typeof fetch;
  private readonly current401?: () => void;
  private readonly pending = new Set<AbortController>();
  private closed = false;
  private submissionAllowed = false;
  static synthetic(deps: ApiDependencies): CloudApi {
    const api = new CloudApi(deps); api.submissionAllowed = true; return api;
  }
  get canSubmit(): boolean { return this.submissionAllowed; }
  constructor(deps: ApiDependencies) {
    this.session = Object.freeze({ ...deps.session });
    this.current = deps.current; this.send = deps.fetch ?? fetch.bind(globalThis); this.current401 = deps.onCurrent401;
    for (const origin of [this.session.origin, this.session.frontendOrigin]) {
      const u = new URL(origin);
      if (!['http:', 'https:'].includes(u.protocol) || u.origin !== origin || u.username || u.password) throw new CloudContractError();
    }
    if (!this.session.token || this.session.token === 'guest-mode') throw new CloudSessionStale();
    this.verify();
  }
  verify(): void {
    const c = this.current(), s = this.session;
    if (this.closed || c.epoch !== s.epoch || c.token !== s.token || c.origin !== s.origin || c.frontendOrigin !== s.frontendOrigin) throw new CloudSessionStale();
  }
  close(): void { if (this.closed) return; this.closed = true; for (const p of this.pending) p.abort(); this.pending.clear(); }
  private async request(method: 'GET' | 'POST', path: string, encoded?: string): Promise<unknown> {
    this.verify();
    const abort = new AbortController(); this.pending.add(abort);
    const timer = setTimeout(() => abort.abort(), 15000);
    try {
      // 固定JWT只发给捕获的本后台同源代理；不使用全局axios或任何provider地址。
      const response = await this.send(`${this.session.frontendOrigin}/api/cloud-workflows${path}`, {
        method, headers: { Authorization: `Bearer ${this.session.token}`, 'Content-Type': 'application/json' },
        ...(encoded !== undefined ? { body: encoded } : {}), signal: abort.signal, redirect: 'error', cache: 'no-store', credentials: 'same-origin',
      });
      this.verify();
      const reader = response.body?.getReader();
      const chunks: Uint8Array[] = []; let size = 0;
      try {
        if (reader) for (;;) {
          const next = await reader.read(); this.verify();
          if (next.done) break;
          size += next.value.length;
          if (size > 512 * 1024) { abort.abort(); await reader.cancel(); throw new CloudContractError(); }
          chunks.push(next.value);
        }
      } finally { reader?.releaseLock(); }
      this.verify();
      if (!response.ok) {
        if (response.status === 401) { this.verify(); this.current401?.(); }
        throw new CloudHttpError(response.status);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const c of chunks) { bytes.set(c, offset); offset += c.length; }
      const parsed: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      bounded(parsed); this.verify(); return parsed;
    } catch (e) {
      // 未经过本会话校验的旧401、旧错误和正文均不能影响新账号。
      this.verify();
      if (e instanceof CloudHttpError || e instanceof CloudContractError) throw e;
      throw new Error('云任务响应未获确认，请查询原提交身份');
    } finally { clearTimeout(timer); this.pending.delete(abort); }
  }
  async capability() { const c = capability(await this.request('GET', '/capability')); this.verify(); return c; }
  async profiles(): Promise<Profile[]> {
    const v = await this.request('GET', '/profiles');
    if (!Array.isArray(v) || v.length > 200) throw new CloudContractError();
    const p = v.map(profile); this.verify(); return p;
  }
  async list(cursor: string | null = null): Promise<{ items: Summary[]; nextCursor: string | null }> {
    const r = row(await this.request('GET', `?limit=4${cursor ? '&cursor=' + uuid(cursor) : ''}`), ['items', 'nextCursor']);
    if (!Array.isArray(r.items) || r.items.length > 4) throw new CloudContractError();
    const items = r.items.map(summary), nextCursor = r.nextCursor === null ? null : uuid(r.nextCursor);
    if (new Set(items.map(i => i.id)).size !== items.length || (nextCursor && (items.length !== 4 || nextCursor !== items.at(-1)!.id || nextCursor === cursor))) throw new CloudContractError();
    this.verify(); return { items, nextCursor };
  }
  async detail(id: string) { const parsed = await detail(await this.request('GET', '/' + uuid(id))); this.verify(); if (parsed.id !== id) throw new CloudContractError(); return parsed; }
  async results(id: string): Promise<Result[]> {
    const v = await this.request('GET', `/${uuid(id)}/result`);
    if (!Array.isArray(v) || v.length > 8) throw new CloudContractError();
    const results = await Promise.all(v.map(result)); this.verify();
    if (new Set(results.map(r => r.id)).size !== results.length) throw new CloudContractError(); return results;
  }
  async byKey(key: string): Promise<ServerReceipt> { const r = serverReceipt(await this.request('GET', '/by-idempotency/' + uuid(key))); this.verify(); return r; }
  async create(encoded: string): Promise<void> {
    this.verify(); if (!this.submissionAllowed) throw new Error(CLOUD_DISABLED_NOTICE);
    await this.request('POST', '', encoded); this.verify();
  }
  async stop(id: string, operationId: string, expectedRevision: number): Promise<void> {
    const r = row(await this.request('POST', `/${uuid(id)}/stop`, JSON.stringify({ operationId: uuid(operationId), expectedRevision: integer(expectedRevision) })));
    state(r.state); this.verify();
  }
}
