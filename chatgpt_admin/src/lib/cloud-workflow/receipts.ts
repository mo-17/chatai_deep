import { canonical, CloudContractError, digest, DraftSource, draftSource, integer, row, ServerReceipt, uuid } from './model';
export interface Receipt { version: 2; origin: string; ownerId: number; key: string; payloadHash: string; source: DraftSource; status: 'submission_unknown' | 'accepted'; taskId: string | null; publicationId: string | null; revision: number; }
export interface StopIntent { taskId: string; operationId: string; expectedRevision: number; status: 'unknown' | 'acknowledged' | 'conflict'; }
export interface ReceiptStorage { getItem(key: string): string | null; setItem(key: string, value: string): void; }
// 持久化最小owner/origin回执，无JWT、完整正文、输入快照、URL凭据。
export class CloudReceipts {
  private readonly key: string;
  constructor(private readonly storage: ReceiptStorage, readonly origin: string, readonly ownerId: number) {
    integer(ownerId); if (new URL(origin).origin !== origin) throw new CloudContractError();
    this.key = `chatai-cloud-receipts-v2:${encodeURIComponent(origin)}:${ownerId}`;
  }
  private read(): { receipts: Receipt[]; stops: StopIntent[] } {
    const raw = this.storage.getItem(this.key);
    if (!raw) return { receipts: [], stops: [] };
    if (new TextEncoder().encode(raw).length > 256 * 1024) throw new CloudContractError();
    const r = row(JSON.parse(raw), ['version', 'receipts', 'stops']);
    if (r.version !== 2 || !Array.isArray(r.receipts) || r.receipts.length > 100 || !Array.isArray(r.stops) || r.stops.length > 100) throw new CloudContractError();
    const receipts = r.receipts.map(v => {
      const p = row(v, ['version', 'origin', 'ownerId', 'key', 'payloadHash', 'source', 'status', 'taskId', 'publicationId', 'revision']);
      if (p.version !== 2 || p.origin !== this.origin || p.ownerId !== this.ownerId || !['submission_unknown', 'accepted'].includes(p.status as string)) throw new CloudContractError();
      const taskId = p.taskId === null ? null : uuid(p.taskId), publicationId = p.publicationId === null ? null : uuid(p.publicationId);
      if ((taskId === null) !== (publicationId === null) || (p.status === 'accepted' && !taskId)) throw new CloudContractError();
      return { version: 2 as const, origin: this.origin, ownerId: this.ownerId, key: uuid(p.key), payloadHash: digest(p.payloadHash), source: draftSource(p.source), status: p.status as Receipt['status'], taskId, publicationId, revision: integer(p.revision, 0) };
    });
    const stops = r.stops.map(v => { const p = row(v, ['taskId', 'operationId', 'expectedRevision', 'status']); if (!['unknown', 'acknowledged', 'conflict'].includes(p.status as string)) throw new CloudContractError(); return { taskId: uuid(p.taskId), operationId: uuid(p.operationId), expectedRevision: integer(p.expectedRevision), status: p.status as StopIntent['status'] }; });
    if (new Set(receipts.map(r => r.key)).size !== receipts.length || new Set(stops.map(s => s.taskId)).size !== stops.length) throw new CloudContractError();
    return { receipts, stops };
  }
  list(): Receipt[] { return this.read().receipts; }
  record(receipt: Receipt): { receipt: Receipt; shouldSend: boolean } {
    const all = this.read(), old = all.receipts.find(r => r.key === receipt.key);
    if (old) {
      if (old.payloadHash !== receipt.payloadHash || canonical(old.source) !== canonical(receipt.source)) throw new CloudContractError();
      return { receipt: old, shouldSend: false };
    }
    if (all.receipts.length >= 100) throw new Error('本地云回执已满，未发出提交');
    all.receipts.push(receipt); this.storage.setItem(this.key, JSON.stringify({ version: 2, ...all }));
    return { receipt, shouldSend: true };
  }
  bind(expected: Receipt, server: ServerReceipt): Receipt {
    const all = this.read(), i = all.receipts.findIndex(r => r.key === expected.key), old = all.receipts[i];
    if (!old || old.payloadHash !== expected.payloadHash || canonical(old.source) !== canonical(expected.source) || server.ownerId !== this.ownerId || server.payloadHash !== old.payloadHash || (server.state !== 'deleted' && canonical(server.source) !== canonical(old.source)) || (old.taskId && old.taskId !== server.id) || (old.publicationId && old.publicationId !== server.publicationId)) throw new CloudContractError();
    if (server.revision < old.revision) return old;
    const bound: Receipt = { ...old, status: 'accepted', taskId: server.id, publicationId: server.publicationId, revision: server.revision };
    all.receipts[i] = bound; this.storage.setItem(this.key, JSON.stringify({ version: 2, ...all })); return bound;
  }
  stop(id: string): StopIntent | undefined { return this.read().stops.find(s => s.taskId === id); }
  writeStop(s: StopIntent): void {
    const all = this.read(), i = all.stops.findIndex(v => v.taskId === s.taskId);
    if (i < 0) { if (all.stops.length >= 100) throw new Error('本地停止回执已满，未发送'); all.stops.push(s); } else all.stops[i] = s;
    this.storage.setItem(this.key, JSON.stringify({ version: 2, ...all }));
  }
}
