import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';
import { createHash, randomBytes } from 'node:crypto';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { ProviderCacheService } from './provider-cache.service';
import {
  catalogEndpoint,
  catalogPage,
  DiscoveredModel,
  ModelCatalogTransport,
  ModelSyncError,
} from './model-discovery';

export interface SyncOwner {
  userId: number;
  bearer: string;
}
interface Preview {
  owner: string;
  providerId: number;
  fingerprint: string;
  expiresAt: number;
  rows: DiscoveredModel[];
  bytes: number;
}
const fingerprint = (p: AiProvider) =>
  createHash('sha256')
    .update(JSON.stringify([p.id, p.code, p.baseUrl, p.apiKey, p.updateTime]))
    .digest('hex');
const ownerKey = (owner: SyncOwner) =>
  createHash('sha256')
    .update(JSON.stringify([owner.userId, owner.bearer]))
    .digest('hex');

@Injectable()
export class AdminModelSyncService implements OnModuleDestroy {
  private readonly previews = new Map<string, Preview>();
  private readonly pending = new Set<string>();
  private readonly active = new Set<AbortController>();
  private stopped = false;
  constructor(
    @InjectRepository(AiProvider)
    private readonly providers: Repository<AiProvider>,
    @InjectRepository(AiModel) private readonly models: Repository<AiModel>,
    private readonly dataSource: DataSource,
    private readonly transport: ModelCatalogTransport,
    private readonly cache: ProviderCacheService,
  ) {}
  onModuleDestroy() {
    this.stopped = true;
    for (const abort of this.active) abort.abort();
    this.previews.clear();
  }
  private check(providerId: number, owner: SyncOwner) {
    if (
      this.stopped ||
      !Number.isSafeInteger(providerId) ||
      providerId <= 0 ||
      !Number.isSafeInteger(owner.userId) ||
      owner.userId <= 0 ||
      !owner.bearer
    )
      throw new ModelSyncError('model_sync_invalid');
  }
  async preview(providerId: number, owner: SyncOwner) {
    this.check(providerId, owner);
    const pendingKey = JSON.stringify([providerId, ownerKey(owner)]);
    if (this.pending.has(pendingKey) || this.active.size >= 2)
      throw new ModelSyncError('model_sync_busy', 409);
    this.pending.add(pendingKey);
    const abort = new AbortController();
    this.active.add(abort);
    const timer = setTimeout(() => abort.abort(), 12000);
    try {
      const provider = await this.providers.findOne({
        where: { id: providerId },
      });
      if (
        !provider ||
        typeof provider.apiKey !== 'string' ||
        !provider.apiKey.trim() ||
        /[\r\n]/.test(provider.apiKey)
      )
        throw new ModelSyncError('model_sync_unavailable');
      const { url, format } = catalogEndpoint(provider.baseUrl);
      const headers: Record<string, string> =
        format === 'anthropic'
          ? { 'x-api-key': provider.apiKey, 'anthropic-version': '2023-06-01' }
          : format === 'gemini'
            ? { 'x-goog-api-key': provider.apiKey }
            : { Authorization: `Bearer ${provider.apiKey}` };
      const rows: DiscoveredModel[] = [];
      const ids = new Set<string>();
      const cursors = new Set<string>();
      let done = false;
      for (let page = 0; page < 10; page++) {
        if (format === 'anthropic') url.searchParams.set('limit', '100');
        if (format === 'gemini') url.searchParams.set('pageSize', '100');
        abort.signal.throwIfAborted();
        const parsed = catalogPage(
          await this.transport.get(new URL(url), headers, abort.signal),
          format,
        );
        abort.signal.throwIfAborted();
        for (const row of parsed.models) {
          if (
            Object.values(row).some(
              (value) =>
                typeof value === 'string' && value.includes(provider.apiKey),
            )
          )
            throw new ModelSyncError();
          if (ids.has(row.modelId)) throw new ModelSyncError();
          ids.add(row.modelId);
          rows.push(row);
          if (rows.length > 1000) throw new ModelSyncError('model_sync_limit');
        }
        if (!parsed.next) {
          done = true;
          break;
        }
        if (parsed.next.includes(provider.apiKey)) throw new ModelSyncError();
        if (cursors.has(parsed.next)) throw new ModelSyncError();
        cursors.add(parsed.next);
        url.searchParams.set(
          format === 'anthropic' ? 'after_id' : 'pageToken',
          parsed.next,
        );
      }
      if (!done) throw new ModelSyncError('model_sync_limit');
      const existing = await this.models.find({ where: { providerId } });
      abort.signal.throwIfAborted();
      const byId = new Map(existing.map((m) => [m.modelId, m]));
      for (const [id, p] of this.previews)
        if (p.expiresAt <= Date.now()) this.previews.delete(id);
      const bytes = Buffer.byteLength(JSON.stringify(rows));
      if (
        this.stopped ||
        this.previews.size >= 50 ||
        bytes +
          [...this.previews.values()].reduce((sum, p) => sum + p.bytes, 0) >
          4 * 1024 * 1024
      )
        throw new ModelSyncError('model_sync_busy', 409);
      const previewId = randomBytes(24).toString('hex');
      const expiresAt = Date.now() + 300000;
      this.previews.set(previewId, {
        owner: ownerKey(owner),
        providerId,
        fingerprint: fingerprint(provider),
        expiresAt,
        rows: rows.filter((row) => !byId.has(row.modelId)),
        bytes,
      });
      return {
        previewId,
        expiresAt,
        providerId,
        providerCode: provider.code,
        format,
        rows: rows.map((row) => {
          const current = byId.get(row.modelId);
          const changes = current
            ? (
                [
                  'displayName',
                  'description',
                  'supportsVision',
                  'supportsTool',
                  'supportsReasoning',
                  'supportsPdf',
                ] as const
              ).filter(
                (key) => row[key] !== undefined && row[key] !== current[key],
              )
            : [];
          return {
            ...row,
            status: !current ? 'new' : changes.length ? 'changed' : 'existing',
            changes,
          };
        }),
      };
    } catch (error) {
      if (error instanceof ModelSyncError) throw error;
      throw new ModelSyncError();
    } finally {
      clearTimeout(timer);
      this.active.delete(abort);
      this.pending.delete(pendingKey);
    }
  }
  async import(
    providerId: number,
    owner: SyncOwner,
    previewId: string,
    modelIds: string[],
  ) {
    this.check(providerId, owner);
    const preview = this.previews.get(previewId);
    if (
      !preview ||
      preview.providerId !== providerId ||
      preview.owner !== ownerKey(owner) ||
      preview.expiresAt <= Date.now()
    )
      throw new ModelSyncError('model_sync_expired', 409);
    if (
      !Array.isArray(modelIds) ||
      !modelIds.length ||
      modelIds.length > 1000 ||
      new Set(modelIds).size !== modelIds.length
    )
      throw new ModelSyncError('model_sync_invalid');
    const rows = modelIds.map((id) =>
      preview.rows.find((row) => row.modelId === id),
    );
    if (rows.some((row) => !row))
      throw new ModelSyncError('model_sync_invalid');
    try {
      const imported = await this.dataSource.transaction(async (manager) => {
        // 与既有 create/edit/setDefault/delete 协作：先锁 provider，网络已结束。
        const provider = await manager.findOne(AiProvider, {
          where: { id: providerId },
          lock: { mode: 'pessimistic_write' },
        });
        if (!provider || fingerprint(provider) !== preview.fingerprint)
          throw new ModelSyncError('model_sync_changed', 409);
        if (this.stopped || preview.expiresAt <= Date.now())
          throw new ModelSyncError('model_sync_expired', 409);
        const result = await manager
          .createQueryBuilder()
          .insert()
          .into(AiModel)
          .values(
            rows.map((row) => ({
              providerId,
              modelId: row!.modelId,
              displayName: row!.displayName,
              description: row!.description,
              enabled: false,
              isDefault: false,
              sortOrder: 0,
              supportsVision: row!.supportsVision ?? false,
              supportsTool: row!.supportsTool ?? false,
              supportsReasoning: row!.supportsReasoning ?? false,
              supportsPdf: row!.supportsPdf ?? false,
            })),
          )
          .orIgnore()
          .returning(['modelId'])
          .execute();
        return (result.raw as Array<{ modelId: string }>).map(
          (row) => row.modelId,
        );
      });
      if (imported.length) this.cache.invalidate();
      return {
        providerId,
        imported,
        skipped: modelIds.filter((id) => !imported.includes(id)),
      };
    } catch (error) {
      if (error instanceof ModelSyncError) throw error;
      throw new ModelSyncError('model_sync_import_unknown', 503);
    }
  }
}
