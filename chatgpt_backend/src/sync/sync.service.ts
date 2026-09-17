import { BadRequestException, Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, MoreThan, Repository } from 'typeorm';
import { SyncChangeDto } from './dto/sync.dto';
import { SyncChangeEntity } from './sync-change.entity';
import { LEGACY_SYNC_LIMITS } from './sync.constants';

export interface SyncConflict {
  entity: string;
  entityId: string;
  reason: 'remote_newer' | 'same_timestamp';
  local: SyncChangeDto;
  remote: SyncChangeEntity;
}

interface PreparedChange {
  change: SyncChangeDto;
  payloadBytes: number;
}

interface StorageUsage {
  recordCount: number;
  payloadBytes: number;
}

@Injectable()
export class SyncService {
  constructor(
    @InjectRepository(SyncChangeEntity)
    private readonly repo: Repository<SyncChangeEntity>,
  ) {}

  async push(userId: number, changes: SyncChangeDto[], deviceId?: string) {
    if (!Number.isSafeInteger(userId) || userId <= 0) {
      throw new BadRequestException('userId 不合法');
    }
    if (!Array.isArray(changes)) {
      throw new BadRequestException('changes 必须是数组');
    }
    if (changes.length > LEGACY_SYNC_LIMITS.maxChanges) {
      throw new BadRequestException(
        `单次同步最多提交 ${LEGACY_SYNC_LIMITS.maxChanges} 条变更`,
      );
    }
    this.validateDeviceId(deviceId);

    let envelopeNodes = 0;
    const prepared: PreparedChange[] = changes.map((change) => {
      const inspected = this.validateChange(change);
      envelopeNodes += inspected.nodes;
      if (envelopeNodes > LEGACY_SYNC_LIMITS.maxEnvelopeNodes) {
        throw new BadRequestException('同步请求包含过多 JSON 节点');
      }
      return {
        change,
        // jsonb::text 会为分隔符增加少量空白；按节点数预留上界，避免同一事务低估。
        payloadBytes:
          change.op === 'delete' ? 0 : inspected.bytes + inspected.nodes * 2,
      };
    });

    let envelopeBytes: number;
    try {
      envelopeBytes = Buffer.byteLength(
        JSON.stringify({ deviceId: deviceId ?? null, changes }),
        'utf8',
      );
    } catch {
      throw new BadRequestException('同步请求体不是有效 JSON');
    }
    if (envelopeBytes > LEGACY_SYNC_LIMITS.maxEnvelopeBytes) {
      throw new BadRequestException('同步请求体超过大小限制');
    }

    return this.repo.manager.transaction(async (manager) => {
      // 同一用户的并发 push 必须串行计费，否则多个请求可同时越过累计配额。
      await manager.query('SELECT pg_advisory_xact_lock($1::bigint)', [userId]);
      const repo = manager.getRepository(SyncChangeEntity);
      const storage = await this.getStorageUsage(manager, userId);
      const result = await this.pushPrepared(
        repo,
        userId,
        prepared,
        deviceId,
        storage,
      );
      // PostgreSQL jsonb 可能规范化数值表示；提交前以数据库实际文本体积复核。
      this.assertStorageWithinBudget(
        await this.getStorageUsage(manager, userId),
      );
      return result;
    });
  }

  private async pushPrepared(
    repo: Repository<SyncChangeEntity>,
    userId: number,
    prepared: PreparedChange[],
    deviceId: string | undefined,
    storage: StorageUsage,
  ) {
    const accepted: SyncChangeEntity[] = [];
    const conflicts: SyncConflict[] = [];

    for (const { change, payloadBytes } of prepared) {
      const latest = await this.latestOf(
        repo,
        userId,
        change.entity,
        change.entityId,
      );
      const localUpdatedAt = change.updatedAt;
      const remoteUpdatedAt = latest ? Number(latest.updatedAt) : -1;

      if (latest && localUpdatedAt < remoteUpdatedAt) {
        conflicts.push({
          entity: change.entity,
          entityId: change.entityId,
          reason: 'remote_newer',
          local: change,
          remote: latest,
        });
        continue;
      }

      if (
        latest &&
        localUpdatedAt === remoteUpdatedAt &&
        !this.sameChange(latest, change)
      ) {
        conflicts.push({
          entity: change.entity,
          entityId: change.entityId,
          reason: 'same_timestamp',
          local: change,
          remote: latest,
        });
        continue;
      }

      if (latest && localUpdatedAt === remoteUpdatedAt) {
        accepted.push(latest);
        continue;
      }

      this.assertStorageBudget(storage, payloadBytes);
      const saved = await repo.save(
        repo.create({
          userId,
          entity: change.entity,
          entityId: change.entityId,
          op: change.op,
          updatedAt: String(localUpdatedAt),
          payload: change.op === 'delete' ? null : (change.payload ?? null),
          deviceId: change.deviceId ?? deviceId ?? null,
        }),
      );
      accepted.push(saved);
      storage.recordCount += 1;
      storage.payloadBytes += payloadBytes;
    }

    return {
      // 上传响应只需确认游标和时间戳。资源分块可能包含大量 base64，
      // 不回显 payload，避免一次上传产生双倍响应流量和内存占用。
      accepted: accepted.map((row) => this.present(row, false)),
      conflicts: conflicts.map((conflict) => ({
        entity: conflict.entity,
        entityId: conflict.entityId,
        reason: conflict.reason,
        remote: this.present(conflict.remote),
      })),
      cursor: accepted.reduce((max, row) => Math.max(max, row.id), 0),
    };
  }

  async pull(userId: number, cursor = 0, limit = 200) {
    const safeCursor = Number.isFinite(cursor) && cursor > 0 ? cursor : 0;
    const safeLimit = Math.min(Math.max(limit || 200, 1), 500);
    const rows = await this.repo.find({
      where: { userId, id: MoreThan(safeCursor) },
      order: { id: 'ASC' },
      take: safeLimit,
    });
    const changes: ReturnType<SyncService['present']>[] = [];
    let payloadBytes = 0;
    for (const row of rows) {
      const change = this.present(row);
      const bytes = Buffer.byteLength(JSON.stringify(change), 'utf8');
      if (
        changes.length > 0 &&
        payloadBytes + bytes > LEGACY_SYNC_LIMITS.maxPullResponseBytes
      ) {
        break;
      }
      changes.push(change);
      payloadBytes += bytes;
    }
    return {
      cursor: changes.reduce(
        (max, change) => Math.max(max, change.id),
        safeCursor,
      ),
      changes,
      hasMore: changes.length < rows.length || rows.length === safeLimit,
    };
  }

  private async latestOf(
    repo: Repository<SyncChangeEntity>,
    userId: number,
    entity: string,
    entityId: string,
  ) {
    return repo.findOne({
      where: { userId, entity, entityId },
      order: { id: 'DESC' },
    });
  }

  private async getStorageUsage(
    manager: EntityManager,
    userId: number,
  ): Promise<StorageUsage> {
    const rawRows: unknown = await manager.query(
      `SELECT COUNT(*) AS "recordCount",
              COALESCE(SUM(octet_length(COALESCE("payload"::text, ''))), 0) AS "payloadBytes"
         FROM "sync_changes"
        WHERE "userId" = $1`,
      [userId],
    );
    const firstRow: unknown = Array.isArray(rawRows) ? rawRows[0] : undefined;
    if (!this.isPlainObject(firstRow)) {
      throw new BadRequestException('无法计算同步存储配额');
    }
    const recordCount = Number(firstRow.recordCount ?? 0);
    const payloadBytes = Number(firstRow.payloadBytes ?? 0);
    if (
      !Number.isSafeInteger(recordCount) ||
      !Number.isSafeInteger(payloadBytes)
    ) {
      throw new BadRequestException('无法计算同步存储配额');
    }
    return { recordCount, payloadBytes };
  }

  private assertStorageBudget(storage: StorageUsage, payloadBytes: number) {
    if (storage.recordCount + 1 > LEGACY_SYNC_LIMITS.maxStoredChangesPerUser) {
      throw new BadRequestException('同步记录数量已达到存储上限');
    }
    if (
      storage.payloadBytes + payloadBytes >
      LEGACY_SYNC_LIMITS.maxStoredPayloadBytesPerUser
    ) {
      throw new BadRequestException('同步 payload 已达到存储上限');
    }
  }

  private assertStorageWithinBudget(storage: StorageUsage) {
    if (storage.recordCount > LEGACY_SYNC_LIMITS.maxStoredChangesPerUser) {
      throw new BadRequestException('同步记录数量已达到存储上限');
    }
    if (
      storage.payloadBytes > LEGACY_SYNC_LIMITS.maxStoredPayloadBytesPerUser
    ) {
      throw new BadRequestException('同步 payload 已达到存储上限');
    }
  }

  private validateDeviceId(deviceId?: string) {
    if (
      deviceId !== undefined &&
      (typeof deviceId !== 'string' ||
        deviceId.length > LEGACY_SYNC_LIMITS.maxDeviceIdLength)
    ) {
      throw new BadRequestException('deviceId 超过长度限制');
    }
  }

  private validateChange(change: SyncChangeDto): {
    bytes: number;
    nodes: number;
  } {
    if (!change || typeof change !== 'object' || Array.isArray(change)) {
      throw new BadRequestException('变更不能为空');
    }
    if (typeof change.entity !== 'string' || !change.entity.trim())
      throw new BadRequestException('entity 不能为空');
    if (change.entity.length > LEGACY_SYNC_LIMITS.maxEntityLength) {
      throw new BadRequestException('entity 超过长度限制');
    }
    if (typeof change.entityId !== 'string' || !change.entityId.trim()) {
      throw new BadRequestException('entityId 不能为空');
    }
    if (change.entityId.length > LEGACY_SYNC_LIMITS.maxEntityIdLength) {
      throw new BadRequestException('entityId 超过长度限制');
    }
    if (change.op !== 'upsert' && change.op !== 'delete') {
      throw new BadRequestException('op 仅支持 upsert/delete');
    }
    if (!Number.isFinite(change.updatedAt) || change.updatedAt < 0) {
      throw new BadRequestException('updatedAt 必须是毫秒时间戳');
    }
    this.validateDeviceId(change.deviceId);

    let inspected = { bytes: 0, nodes: 0 };
    if (change.payload !== undefined && change.payload !== null) {
      if (!this.isPlainObject(change.payload)) {
        throw new BadRequestException('payload 必须是对象');
      }
      inspected = this.inspectJson(change.payload);
      if (inspected.bytes > LEGACY_SYNC_LIMITS.maxPayloadBytes) {
        throw new BadRequestException('单条同步 payload 超过大小限制');
      }
    }
    if (change.entity === 'assistant_role_asset_chunk') {
      this.validateRoleAssetChunk(change);
    }
    return inspected;
  }

  private inspectJson(value: unknown): { bytes: number; nodes: number } {
    const stack: Array<{ value: unknown; depth: number }> = [
      { value, depth: 1 },
    ];
    let nodes = 1;
    while (stack.length > 0) {
      const current = stack.pop()!;

      const item = current.value;
      if (
        item === null ||
        typeof item === 'string' ||
        typeof item === 'boolean'
      ) {
        continue;
      }
      if (typeof item === 'number') {
        if (!Number.isFinite(item)) {
          throw new BadRequestException('payload 包含非法数值');
        }
        continue;
      }
      if (current.depth > LEGACY_SYNC_LIMITS.maxJsonDepth) {
        throw new BadRequestException('payload 嵌套层级超过限制');
      }
      if (Array.isArray(item)) {
        for (const child of item) {
          nodes += 1;
          if (nodes > LEGACY_SYNC_LIMITS.maxPayloadNodes) {
            throw new BadRequestException(
              '单条同步 payload 包含过多 JSON 节点',
            );
          }
          stack.push({ value: child, depth: current.depth + 1 });
        }
        continue;
      }
      if (!this.isPlainObject(item)) {
        throw new BadRequestException('payload 只能包含 JSON 值');
      }
      for (const [key, child] of Object.entries(item)) {
        nodes += 1;
        if (nodes > LEGACY_SYNC_LIMITS.maxPayloadNodes) {
          throw new BadRequestException('单条同步 payload 包含过多 JSON 节点');
        }
        if (key.length > LEGACY_SYNC_LIMITS.maxJsonKeyLength) {
          throw new BadRequestException('payload 字段名超过长度限制');
        }
        stack.push({ value: child, depth: current.depth + 1 });
      }
    }

    let encoded: string;
    try {
      encoded = JSON.stringify(value);
    } catch {
      throw new BadRequestException('payload 不是有效 JSON');
    }
    return { bytes: Buffer.byteLength(encoded, 'utf8'), nodes };
  }

  private isPlainObject(value: unknown): value is Record<string, unknown> {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      return false;
    }
    const prototype: unknown = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }

  private validateRoleAssetChunk(change: SyncChangeDto) {
    const payload = change.payload ?? {};
    const assistantId = Number(payload.assistantId);
    const assetIndex = Number(payload.assetIndex);
    const chunkIndex = Number(payload.chunkIndex);
    const totalChunks = Number(payload.totalChunks);
    const assetCount = Number(payload.assetCount);
    const assistantUpdatedAt = Number(payload.assistantUpdatedAt);
    const data = payload.base64;
    const metadata = payload.metadata;
    const validInteger = (value: number) =>
      Number.isInteger(value) && Number.isSafeInteger(value);
    const valid =
      validInteger(assistantId) &&
      assistantId > 0 &&
      validInteger(assetIndex) &&
      assetIndex >= 0 &&
      assetIndex < 256 &&
      validInteger(chunkIndex) &&
      chunkIndex >= 0 &&
      validInteger(totalChunks) &&
      totalChunks > 0 &&
      totalChunks <= 107 &&
      chunkIndex < totalChunks &&
      validInteger(assetCount) &&
      assetCount > 0 &&
      assetCount <= 256 &&
      assistantUpdatedAt === change.updatedAt &&
      change.entityId === `${assistantId}:${assetIndex}:${chunkIndex}` &&
      typeof data === 'string' &&
      data.length > 0 &&
      data.length <= 262_144 &&
      /^[A-Za-z0-9+/]*={0,2}$/.test(data) &&
      metadata !== null &&
      typeof metadata === 'object' &&
      !Array.isArray(metadata) &&
      JSON.stringify(metadata).length <= 16_384;
    if (!valid) {
      throw new BadRequestException('角色卡资源分块不合法');
    }
  }

  private sameChange(remote: SyncChangeEntity, local: SyncChangeDto) {
    if (remote.op !== local.op) return false;
    const remotePayload =
      remote.op === 'delete' ? null : (remote.payload ?? null);
    const localPayload = local.op === 'delete' ? null : (local.payload ?? null);
    try {
      if (remotePayload !== null) this.inspectJson(remotePayload);
      if (localPayload !== null) this.inspectJson(localPayload);
    } catch {
      // 历史脏数据不能重新触发无界递归；按内容不同走冲突分支。
      return false;
    }
    return (
      this.stableStringify(remotePayload) === this.stableStringify(localPayload)
    );
  }

  private stableStringify(value: unknown): string {
    if (Array.isArray(value)) {
      return `[${value.map((item) => this.stableStringify(item)).join(',')}]`;
    }
    if (value && typeof value === 'object') {
      const map = value as Record<string, unknown>;
      return `{${Object.keys(map)
        .sort()
        .map(
          (key) => `${JSON.stringify(key)}:${this.stableStringify(map[key])}`,
        )
        .join(',')}}`;
    }
    return JSON.stringify(value);
  }

  private present(row: SyncChangeEntity, includePayload = true) {
    return {
      id: row.id,
      entity: row.entity,
      entityId: row.entityId,
      op: row.op,
      updatedAt: Number(row.updatedAt),
      ...(includePayload ? { payload: row.payload } : {}),
      deviceId: row.deviceId,
      createdAt: row.createdAt,
    };
  }
}
