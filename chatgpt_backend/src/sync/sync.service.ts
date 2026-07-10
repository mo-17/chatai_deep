import { BadRequestException, Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { MoreThan, Repository } from 'typeorm';
import { SyncChangeDto } from './dto/sync.dto';
import { SyncChangeEntity } from './sync-change.entity';

export interface SyncConflict {
  entity: string;
  entityId: string;
  reason: 'remote_newer' | 'same_timestamp';
  local: SyncChangeDto;
  remote: SyncChangeEntity;
}

@Injectable()
export class SyncService {
  private static readonly maxPullPayloadBytes = 4 * 1024 * 1024;

  constructor(
    @InjectRepository(SyncChangeEntity)
    private readonly repo: Repository<SyncChangeEntity>,
  ) {}

  async push(userId: number, changes: SyncChangeDto[], deviceId?: string) {
    if (!Array.isArray(changes)) {
      throw new BadRequestException('changes 必须是数组');
    }
    if (changes.length > 500) {
      throw new BadRequestException('单次同步最多提交 500 条变更');
    }

    const accepted: SyncChangeEntity[] = [];
    const conflicts: SyncConflict[] = [];

    for (const change of changes) {
      this.validateChange(change);
      const latest = await this.latestOf(
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

      const saved = await this.repo.save(
        this.repo.create({
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
        payloadBytes + bytes > SyncService.maxPullPayloadBytes
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

  private async latestOf(userId: number, entity: string, entityId: string) {
    return this.repo.findOne({
      where: { userId, entity, entityId },
      order: { id: 'DESC' },
    });
  }

  private validateChange(change: SyncChangeDto) {
    if (!change.entity?.trim())
      throw new BadRequestException('entity 不能为空');
    if (!change.entityId?.trim()) {
      throw new BadRequestException('entityId 不能为空');
    }
    if (change.op !== 'upsert' && change.op !== 'delete') {
      throw new BadRequestException('op 仅支持 upsert/delete');
    }
    if (!Number.isFinite(change.updatedAt) || change.updatedAt < 0) {
      throw new BadRequestException('updatedAt 必须是毫秒时间戳');
    }
    if (change.entity === 'assistant_role_asset_chunk') {
      this.validateRoleAssetChunk(change);
    }
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
