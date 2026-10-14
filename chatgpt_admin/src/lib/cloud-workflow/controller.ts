import { CloudApi, CloudHttpError, CloudSessionStale } from './api';
import { Budget, canonical, Capability, CLOUD_DISABLED_NOTICE, CLOUD_ROLES, CloudContractError, Detail, Draft, finalWriting, freeze, hash, makePreview, newDraft, pollable, Preview, Profile, Result, Summary, validatePayload } from './model';
import { CloudReceipts, Receipt, ReceiptStorage, StopIntent } from './receipts';

export interface CloudClock { schedule(action: () => void, ms: number): unknown; cancel(timer: unknown): void; }
export interface CloudNoticeScope { readonly generation: number; readonly taskId: string | null; }
const browserClock: CloudClock = { schedule: (fn, ms) => setTimeout(fn, ms), cancel: t => clearTimeout(t as ReturnType<typeof setTimeout>) };
export interface CloudSnapshot { loading: boolean; busy: boolean; capability: Capability | null; profiles: Profile[]; tasks: Summary[]; nextCursor: string | null; receipts: Receipt[]; detail: Detail | null; results: Result[]; notice: string | null; stopNeedsNewIntent: boolean; draft: Draft; preview: Preview | null; }
/** 独立观察/提交协调器；没有本机runner、全局axios、React Query mutation重试或worker触发。 */
export class CloudController {
  private allowed = false;
  private closed = false;
  private visible = true;
  private generation = 0;
  private observedTaskId: string | null = null;
  private timer: unknown = null;
  private backoff = 20000;
  private store: CloudReceipts | null = null;
  private listeners = new Set<() => void>();
  private submitting = new Map<string, { digest: string; source: string; future: Promise<Receipt> }>();
  private stopping = new Map<string, Promise<void>>();
  private refreshFlight: { generation: number; id: string; promise: Promise<void> } | null = null;
  private pageFlight: Promise<void> | null = null;
  private snapshot: CloudSnapshot = freeze({ loading: true, busy: false, capability: null, profiles: [], tasks: [], nextCursor: null, receipts: [], detail: null, results: [], notice: null, stopNeedsNewIntent: false, draft: newDraft(), preview: null });
  constructor(readonly api: CloudApi, private readonly storage: ReceiptStorage, private readonly clock: CloudClock = browserClock) {}
  /** 只供合成测试显式注入；生产page永远new CloudController，不暴露路由/环境开关。 */
  static synthetic(api: CloudApi, storage: ReceiptStorage, clock?: CloudClock): CloudController { const c = new CloudController(api, storage, clock); c.allowed = true; return c; }
  getSnapshot = (): CloudSnapshot => this.snapshot;
  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => this.listeners.delete(listener); };
  verify(): void { this.api.verify(); if (this.closed) throw new CloudSessionStale(); }
  private update(change: Partial<CloudSnapshot>): void { this.verify(); this.snapshot = freeze({ ...this.snapshot, ...change }); this.listeners.forEach(fn => fn()); }
  get canCreate(): boolean { return this.allowed && this.api.canSubmit && this.snapshot.capability?.available === true && this.snapshot.profiles.length > 0; }
  noticeScope(): CloudNoticeScope { return { generation: this.generation, taskId: this.observedTaskId }; }
  report(e: unknown, scope?: CloudNoticeScope): void {
    if (!this.current() || (scope && (scope.generation !== this.generation || scope.taskId !== this.observedTaskId))) return;
    this.update({ notice: e instanceof CloudContractError || e instanceof CloudHttpError ? e.message : e instanceof Error ? e.message : '云任务操作未获确认' });
  }
  private current(): boolean { try { this.verify(); return true; } catch { return false; } }
  async initialize(): Promise<void> {
    this.verify(); const cap = await this.api.capability(); this.verify();
    const store = new CloudReceipts(this.storage, this.api.session.origin, cap.ownerId);
    const receipts = store.list(); this.verify(); this.store = store;
    const page = await this.api.list(); this.verify(); this.checkOwners(page.items, cap.ownerId);
    let profiles: Profile[] = [];
    try { profiles = await this.api.profiles(); this.verify(); } catch (e) { this.verify(); if (!(e instanceof CloudHttpError)) throw e; }
    this.update({ loading: false, capability: cap, receipts, tasks: page.items, nextCursor: page.nextCursor, profiles });
  }
  private checkOwners(rows: Summary[], owner = this.snapshot.capability?.ownerId): void { if (!owner || rows.some(r => r.ownerId !== owner)) throw new CloudContractError(); }
  edit(action: (d: Draft) => void): void {
    this.verify(); if (this.snapshot.busy) throw new Error('当前操作尚未结算');
    const d = structuredClone(this.snapshot.draft); action(d); d.revision++;
    this.update({ draft: d, preview: null, notice: null });
  }
  newDraft(): void { this.verify(); if (!this.snapshot.busy) this.update({ draft: newDraft(), preview: null, notice: null }); }
  async prepare(): Promise<Preview> {
    this.verify(); const d = this.snapshot.draft;
    if (this.snapshot.receipts.some(r => r.status === 'submission_unknown' && r.source.id === d.id)) throw new Error('该草稿提交结果未知，请按原key查询，不能重新发送');
    for (const role of CLOUD_ROLES) { const p = d.profiles[role]; if (!p || !this.snapshot.profiles.some(s => s.providerId === p.providerId && s.modelRowId === p.modelRowId)) throw new Error('请明确选择三个可用服务端模型'); }
    const prepared = await makePreview(d); this.verify();
    if (this.snapshot.draft.id !== d.id || this.snapshot.draft.revision !== prepared.revision) throw new Error('草稿已变化，请重新预览');
    this.update({ preview: prepared }); return prepared;
  }
  cancelPreview(): void { this.update({ preview: null }); }
  confirm(prepared: Preview): Promise<Receipt> {
    this.verify(); if (!this.canCreate) throw new Error(CLOUD_DISABLED_NOTICE);
    const key = prepared.payload.idempotencyKey, source = canonical(prepared.payload.source), old = this.submitting.get(key);
    if (old) { if (old.digest !== prepared.digest || old.source !== source) throw new CloudContractError(); return old.future; }
    if (this.snapshot.preview !== prepared || this.snapshot.draft.id !== prepared.payload.source.id || this.snapshot.draft.revision !== prepared.revision) throw new Error('确认已失效，请重新预览');
    const future = this.submit(prepared); this.submitting.set(key, { digest: prepared.digest, source, future }); return future;
  }
  private async submit(prepared: Preview): Promise<Receipt> {
    this.update({ busy: true });
    try {
      const validated = await validatePayload(prepared.payload); this.verify();
      if (canonical(validated) !== prepared.encoded || await hash(prepared.encoded) !== prepared.digest) throw new CloudContractError();
      this.verify();
      if (this.snapshot.draft.revision !== prepared.revision || this.snapshot.preview !== prepared) throw new Error('确认已失效');
      const owner = this.snapshot.capability!.ownerId;
      const registered = this.store!.record({ version: 2, origin: this.api.session.origin, ownerId: owner, key: validated.idempotencyKey, payloadHash: prepared.digest, source: validated.source, status: 'submission_unknown', taskId: null, publicationId: null, revision: 0 });
      this.verify(); this.update({ receipts: this.store!.list(), preview: null });
      if (registered.shouldSend) {
        try { await this.api.create(prepared.encoded); this.verify(); }
        catch { this.verify(); this.update({ notice: '提交结果未知，后续仅按原key查询，不重新发送' }); }
      }
      let receipt = registered.receipt;
      try { receipt = await this.resolve(receipt); this.verify(); }
      catch (e) { this.verify(); if (!(e instanceof CloudHttpError && e.status === 404)) throw e; this.update({ notice: '暂未查到提交，仍保持未知；不会重新发送' }); }
      if (receipt.taskId) await this.open(receipt.taskId);
      this.verify(); return receipt;
    } finally { if (this.current()) this.update({ busy: false }); }
  }
  async resolve(receipt: Receipt): Promise<Receipt> {
    this.verify(); if (!this.store || receipt.ownerId !== this.snapshot.capability?.ownerId || receipt.origin !== this.api.session.origin) throw new CloudContractError();
    const server = await this.api.byKey(receipt.key); this.verify();
    const bound = this.store.bind(receipt, server); this.verify();
    this.update({ receipts: this.store.list(), ...(!this.snapshot.detail || this.snapshot.detail.id === bound.taskId ? { notice: '提交已由服务端确认' } : {}) }); return bound;
  }
  async resolveAndOpen(receipt: Receipt): Promise<void> { const bound = await this.resolve(receipt); this.verify(); if (bound.taskId) await this.open(bound.taskId); }
  private async read(id: string): Promise<{ detail: Detail; results: Result[] }> {
    const d = await this.api.detail(id); this.verify(); this.checkOwners([d]);
    const results = d.state === 'complete' ? await this.api.results(id) : []; this.verify();
    if (d.state === 'complete') finalWriting(d, results);
    return { detail: d, results };
  }
  async open(id: string): Promise<void> {
    this.verify(); const gen = ++this.generation; this.cancelTimer();
    this.observedTaskId = id;
    this.update({ detail: null, results: [], notice: null, stopNeedsNewIntent: false });
    const next = await this.read(id); this.verify(); if (gen !== this.generation) return;
    this.update({ ...next, stopNeedsNewIntent: this.store!.stop(id)?.status === 'conflict' }); this.arm();
  }
  refresh(): Promise<void> {
    this.verify(); const id = this.snapshot.detail?.id, gen = this.generation;
    if (!id) return Promise.resolve();
    if (this.refreshFlight?.id === id && this.refreshFlight.generation === gen) return this.refreshFlight.promise;
    const promise = this.doRefresh(id, gen); const flight = { id, generation: gen, promise }; this.refreshFlight = flight;
    void promise.finally(() => { if (this.refreshFlight === flight) this.refreshFlight = null; }).catch(() => {});
    return promise;
  }
  private async doRefresh(id: string, gen: number): Promise<void> {
    const next = await this.read(id); this.verify();
    if (gen !== this.generation || this.snapshot.detail?.id !== id || next.detail.revision < this.snapshot.detail.revision) return;
    this.update(next); this.backoff = 20000; this.arm();
  }
  loadNextPage(): Promise<void> {
    this.verify(); if (this.pageFlight) return this.pageFlight;
    const promise = this.nextPage(); this.pageFlight = promise;
    void promise.finally(() => { if (this.pageFlight === promise) this.pageFlight = null; }).catch(() => {}); return promise;
  }
  private async nextPage(): Promise<void> {
    const cursor = this.snapshot.nextCursor; if (!cursor) return;
    const p = await this.api.list(cursor); this.verify(); this.checkOwners(p.items);
    if (cursor !== this.snapshot.nextCursor) return;
    const byId = new Map(this.snapshot.tasks.map(t => [t.id, t]));
    for (const t of p.items) { const old = byId.get(t.id); if (!old || t.revision >= old.revision) byId.set(t.id, t); }
    this.update({ tasks: [...byId.values()], nextCursor: p.nextCursor });
  }
  private cancelTimer(): void { if (this.timer !== null) this.clock.cancel(this.timer); this.timer = null; }
  setVisible(v: boolean): void { if (!this.current()) { this.close(); return; } if (this.visible === v) return; this.visible = v; this.cancelTimer(); if (v) void this.observe(); }
  private arm(): void { this.cancelTimer(); if (this.visible && this.current() && this.snapshot.detail && pollable(this.snapshot.detail.state)) this.timer = this.clock.schedule(() => { this.timer = null; void this.observe(); }, this.backoff); }
  private async observe(): Promise<void> {
    const gen = this.generation;
    try { this.verify(); if (!this.visible) return; await this.refresh(); this.verify(); }
    catch { if (!this.current()) { this.close(); return; } if (gen !== this.generation) return; this.backoff = Math.min(this.backoff * 2, 120000); this.update({ notice: '状态刷新失败，可手动查询；不会重新执行' }); }
    if (this.current() && gen === this.generation) this.arm();
  }
  stop(newIntent = false): Promise<void> {
    this.verify(); const d = this.snapshot.detail; if (!d) throw new Error('请先选择任务');
    const old = this.stopping.get(d.id); if (old) return old;
    const promise = this.doStop(d, this.generation, newIntent); this.stopping.set(d.id, promise);
    void promise.finally(() => { if (this.stopping.get(d.id) === promise) this.stopping.delete(d.id); }).catch(() => {}); return promise;
  }
  private async doStop(d: Detail, gen: number, newIntent: boolean): Promise<void> {
    this.update({ busy: true, notice: '停止请求已发出，等待服务器结算' });
    try {
      let intent = this.store!.stop(d.id);
      if (intent?.status === 'conflict' && !newIntent) throw new Error('状态已变化，请明确按新状态停止');
      if (!intent || (newIntent && intent.status === 'conflict')) intent = { taskId: d.id, operationId: crypto.randomUUID(), expectedRevision: d.revision, status: 'unknown' };
      const original: StopIntent = { ...intent, status: 'unknown' };
      this.verify(); this.store!.writeStop(original); this.verify();
      let acknowledged = false;
      try {
        await this.api.stop(d.id, original.operationId, original.expectedRevision); this.verify(); this.store!.writeStop({ ...original, status: 'acknowledged' });
        acknowledged = true;
      } catch (e) {
        this.verify();
        if (e instanceof CloudHttpError && e.status === 409) this.store!.writeStop({ ...original, status: 'conflict' });
        if (this.generation === gen && this.snapshot.detail?.id === d.id) {
          this.update({ stopNeedsNewIntent: e instanceof CloudHttpError && e.status === 409, notice: e instanceof CloudHttpError && e.status === 409 ? '状态已变化，请刷新后明确按新状态停止' : '停止结果未知；查询不会重发，明确重试复用原停止身份' });
        }
      }
      if (this.generation === gen && this.snapshot.detail?.id === d.id) {
        if (acknowledged) this.update({ notice: '停止请求已确认，等待实际状态结算', stopNeedsNewIntent: false });
        try { await this.refresh(); }
        catch {
          this.verify();
          // 查询失败不是停止mutation的409或未知ack，不能改已持久的回执。
          if (acknowledged && this.generation === gen && this.snapshot.detail?.id === d.id) this.update({ notice: '停止请求已确认，状态查询暂不可用' });
        }
      }
    } finally { if (this.current()) this.update({ busy: false }); }
  }
  get finalResult(): Result | null { return finalWriting(this.snapshot.detail, this.snapshot.results); }
  async copyResult(copy: (text: string) => Promise<void>): Promise<void> {
    this.verify(); const r = this.finalResult, id = this.snapshot.detail?.id, gen = this.generation;
    if (!r) throw new Error('当前没有已验证的最终成果');
    await copy(r.content); this.verify(); if (gen === this.generation && id === this.snapshot.detail?.id) this.update({ notice: '成果已复制' });
  }
  close(): void { if (this.closed) return; this.closed = true; this.generation++; this.cancelTimer(); this.api.close(); this.listeners.clear(); }
}
// 页面实际预算字段使用同一型别，不引入账单金额或额外执行额度。
export type CloudBudget = Budget;
