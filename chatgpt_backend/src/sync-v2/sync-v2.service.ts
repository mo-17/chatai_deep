import {
  BadRequestException,
  Inject,
  Injectable,
  InternalServerErrorException,
} from '@nestjs/common';
import { createHash } from 'crypto';
import type {
  PushSyncV2Dto,
  SyncV2ChangeDto,
  SyncV2Operation,
} from './dto/sync-v2.dto';
import {
  SYNC_V2_ENTITIES,
  SYNC_V2_LIMITS,
  SYNC_V2_MAX_BIGINT,
} from './sync-v2.constants';
import { SyncV2EventEntity } from './sync-v2-event.entity';
import type {
  SyncV2ReceiptEntity,
  SyncV2ReceiptReason,
  SyncV2ReceiptResult,
} from './sync-v2-receipt.entity';
import { SYNC_V2_STORE } from './sync-v2.store';
import type { SyncV2Store, SyncV2Transaction } from './sync-v2.store';

export interface PresentedSyncV2Event {
  sequence: string;
  changeId: string;
  entity: string;
  syncId: string;
  parentChangeId: string | null;
  revision: string;
  op: SyncV2Operation;
  payload: Record<string, unknown> | null;
  deviceId: string;
  serverCreatedAt: string;
}

interface AcceptedAck {
  changeId: string;
  result: 'accepted';
  duplicate: boolean;
  entity: string;
  syncId: string;
  parentChangeId: string | null;
  revision: string;
  sequence: string;
}

interface PersistedFailureAckBase {
  changeId: string;
  duplicate: boolean;
  entity: string;
  syncId: string;
  parentChangeId: string | null;
  revision: string;
  expectedRevision: string;
  remote: PresentedSyncV2Event | null;
}

interface RemoteAheadAck extends PersistedFailureAckBase {
  result: 'conflict';
  reason: 'remote_ahead';
}

interface RevisionGapAck extends PersistedFailureAckBase {
  result: 'rejected';
  reason: 'revision_gap';
}

interface BlockedAck extends PersistedFailureAckBase {
  result: 'blocked';
  reason: 'blocked_by_ancestor';
}

interface ChangeIdReusedAck {
  changeId: string;
  result: 'rejected';
  duplicate: false;
  entity: string;
  syncId: string;
  parentChangeId: string | null;
  revision: string;
  reason: 'change_id_reused';
}

export type SyncV2Ack =
  | AcceptedAck
  | RemoteAheadAck
  | RevisionGapAck
  | BlockedAck
  | ChangeIdReusedAck;

interface PreparedChange {
  index: number;
  change: SyncV2ChangeDto;
  requestHash: string;
}

const uuidV4 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const positiveDecimal = /^[1-9]\d*$/;
const nonNegativeDecimal = /^(0|[1-9]\d*)$/;

@Injectable()
export class SyncV2Service {
  constructor(
    @Inject(SYNC_V2_STORE)
    private readonly store: SyncV2Store,
  ) {}

  capabilities() {
    return {
      protocol: 2,
      mode: 'shadow' as const,
      shadowOnly: true,
      activationEnabled: false,
      bootstrapAvailable: false,
      requiresMigration: true,
      entities: [...SYNC_V2_ENTITIES],
      parity: {
        core: true,
        story: false,
        binaryResources: false,
      },
      limits: { ...SYNC_V2_LIMITS },
    };
  }

  async push(userId: number, body: PushSyncV2Dto) {
    const prepared = this.prepare(body);
    const firstByChangeId = new Map<string, PreparedChange>();
    for (const item of prepared) {
      if (!firstByChangeId.has(item.change.changeId)) {
        firstByChangeId.set(item.change.changeId, item);
      }
    }
    const primaryItems = [...firstByChangeId.values()].sort((a, b) =>
      this.compareForProcessing(a, b),
    );

    return this.store.transaction(async (tx) => {
      await tx.lock(
        primaryItems.flatMap(({ change }) => [
          `change:${userId}:${change.changeId}`,
          `head:${userId}:${change.entity}:${change.syncId}`,
        ]),
      );

      const primaryAcks = new Map<string, SyncV2Ack>();
      const blockedChangeIds = new Set<string>();
      for (const item of primaryItems) {
        const blockedByAncestor =
          item.change.parentChangeId != null &&
          blockedChangeIds.has(item.change.parentChangeId);
        const ack = blockedByAncestor
          ? await this.processBlockedChange(tx, userId, item)
          : await this.processChange(tx, userId, body.deviceId, item);
        primaryAcks.set(item.change.changeId, ack);
        const isReusedChangeId =
          ack.result === 'rejected' && ack.reason === 'change_id_reused';
        if (ack.result !== 'accepted' && !isReusedChangeId) {
          blockedChangeIds.add(item.change.changeId);
        }
      }

      const acks = prepared.map((item) => {
        const first = firstByChangeId.get(item.change.changeId)!;
        const firstAck = primaryAcks.get(item.change.changeId)!;
        if (item === first) return firstAck;
        if (item.requestHash === first.requestHash) {
          if (
            firstAck.result === 'rejected' &&
            firstAck.reason === 'change_id_reused'
          ) {
            return firstAck;
          }
          return { ...firstAck, duplicate: true };
        }
        return this.reusedChangeIdAck(item.change);
      });
      return { acks };
    });
  }

  async pull(userId: number, cursor = '0', limit = 200) {
    this.validateCursor(cursor);
    if (!Number.isInteger(limit) || limit < 1) {
      throw new BadRequestException('limit 必须是正整数');
    }
    const safeLimit = Math.min(limit, SYNC_V2_LIMITS.maxPullLimit);
    const rows = await this.store.pullEvents(userId, cursor, safeLimit + 1);
    const changes: PresentedSyncV2Event[] = [];
    let responseBytes = 0;
    for (const row of rows.slice(0, safeLimit)) {
      const change = this.presentEvent(row);
      const changeBytes = Buffer.byteLength(JSON.stringify(change), 'utf8');
      if (
        changes.length > 0 &&
        responseBytes + changeBytes > SYNC_V2_LIMITS.maxPullResponseBytes
      ) {
        break;
      }
      changes.push(change);
      responseBytes += changeBytes;
    }
    return {
      cursor:
        changes.length > 0 ? changes[changes.length - 1].sequence : cursor,
      hasMore: rows.length > changes.length,
      changes,
    };
  }

  private prepare(body: PushSyncV2Dto): PreparedChange[] {
    if (!body || typeof body !== 'object') {
      throw new BadRequestException('同步请求不能为空');
    }
    if (
      typeof body.deviceId !== 'string' ||
      body.deviceId.length > SYNC_V2_LIMITS.maxDeviceIdLength ||
      !uuidV4.test(body.deviceId)
    ) {
      throw new BadRequestException('deviceId 必须是 UUID v4');
    }
    if (!Array.isArray(body.changes)) {
      throw new BadRequestException('changes 必须是数组');
    }
    if (body.changes.length > SYNC_V2_LIMITS.maxChanges) {
      throw new BadRequestException(
        `单次同步最多提交 ${SYNC_V2_LIMITS.maxChanges} 条变更`,
      );
    }

    const envelopeBytes = Buffer.byteLength(
      this.canonicalStringify(body),
      'utf8',
    );
    if (envelopeBytes > SYNC_V2_LIMITS.maxEnvelopeBytes) {
      throw new BadRequestException('同步请求体超过大小限制');
    }

    return body.changes.map((change, index) => {
      this.validateChange(change);
      const normalizedPayload =
        change.op === 'delete' ? null : (change.payload ?? null);
      const requestHash = createHash('sha256')
        .update(
          this.canonicalStringify({
            changeId: change.changeId,
            entity: change.entity,
            syncId: change.syncId,
            parentChangeId: change.parentChangeId ?? null,
            revision: change.revision,
            op: change.op,
            payload: normalizedPayload,
          }),
        )
        .digest('hex');
      return { index, change, requestHash };
    });
  }

  private validateChange(change: SyncV2ChangeDto) {
    if (!change || typeof change !== 'object') {
      throw new BadRequestException('变更不能为空');
    }
    if (!uuidV4.test(change.changeId ?? '')) {
      throw new BadRequestException('changeId 必须是 UUID v4');
    }
    if (!SYNC_V2_ENTITIES.includes(change.entity)) {
      throw new BadRequestException(`不支持的同步实体: ${change.entity}`);
    }
    if (!uuidV4.test(change.syncId ?? '')) {
      throw new BadRequestException('syncId 必须是 UUID v4');
    }
    if (
      change.parentChangeId !== undefined &&
      change.parentChangeId !== null &&
      !uuidV4.test(change.parentChangeId)
    ) {
      throw new BadRequestException('parentChangeId 必须是 UUID v4');
    }
    if (!positiveDecimal.test(change.revision ?? '')) {
      throw new BadRequestException('revision 必须是正十进制字符串');
    }
    if (BigInt(change.revision) > SYNC_V2_MAX_BIGINT) {
      throw new BadRequestException('revision 超出 bigint 范围');
    }
    if (change.revision === '1' && change.parentChangeId != null) {
      throw new BadRequestException('revision 1 不能包含 parentChangeId');
    }
    if (change.op !== 'upsert' && change.op !== 'delete') {
      throw new BadRequestException('op 仅支持 upsert/delete');
    }
    if (change.op === 'delete') {
      if (change.payload !== undefined && change.payload !== null) {
        throw new BadRequestException('delete 变更不能包含 payload');
      }
      return;
    }
    if (!this.isPlainObject(change.payload)) {
      throw new BadRequestException('upsert payload 必须是对象');
    }
    if (
      Buffer.byteLength(this.canonicalStringify(change.payload), 'utf8') >
      SYNC_V2_LIMITS.maxPayloadBytes
    ) {
      throw new BadRequestException('单条同步 payload 超过大小限制');
    }
  }

  private validateCursor(cursor: string) {
    if (!nonNegativeDecimal.test(cursor)) {
      throw new BadRequestException('cursor 必须是非负十进制字符串');
    }
    if (BigInt(cursor) > SYNC_V2_MAX_BIGINT) {
      throw new BadRequestException('cursor 超出 bigint 范围');
    }
  }

  private compareForProcessing(a: PreparedChange, b: PreparedChange) {
    const entity = a.change.entity.localeCompare(b.change.entity);
    if (entity !== 0) return entity;
    const syncId = a.change.syncId.localeCompare(b.change.syncId);
    if (syncId !== 0) return syncId;
    const revisionA = BigInt(a.change.revision);
    const revisionB = BigInt(b.change.revision);
    if (revisionA < revisionB) return -1;
    if (revisionA > revisionB) return 1;
    return a.index - b.index;
  }

  private async processChange(
    tx: SyncV2Transaction,
    userId: number,
    deviceId: string,
    item: PreparedChange,
  ): Promise<SyncV2Ack> {
    const { change, requestHash } = item;
    const receipt = await tx.findReceipt(userId, change.changeId);
    if (receipt) {
      if (receipt.requestHash !== requestHash) {
        return this.reusedChangeIdAck(change);
      }
      return this.replayReceipt(tx, userId, receipt);
    }

    const head = await tx.findHead(userId, change.entity, change.syncId);
    const headRevision = head ? BigInt(head.revision) : BigInt(0);
    const expectedRevision = headRevision + BigInt(1);
    const requestedRevision = BigInt(change.revision);
    const parentMatches = head
      ? change.parentChangeId === head.changeId
      : change.parentChangeId == null;
    const parentReceipt =
      !parentMatches && change.parentChangeId
        ? await tx.findReceipt(userId, change.parentChangeId)
        : null;
    const parentWasNotAccepted =
      parentReceipt !== null && parentReceipt.result !== 'accepted';

    if (requestedRevision === expectedRevision && parentMatches) {
      const event = await tx.appendEvent({
        userId,
        changeId: change.changeId,
        entity: change.entity,
        syncId: change.syncId,
        parentChangeId: change.parentChangeId ?? null,
        revision: change.revision,
        op: change.op,
        payload: change.op === 'delete' ? null : change.payload!,
        deviceId,
      });
      await tx.saveHead({
        userId,
        entity: change.entity,
        syncId: change.syncId,
        changeId: event.changeId,
        revision: event.revision,
        eventSequence: event.sequence,
        op: event.op,
      });
      await tx.saveReceipt({
        userId,
        changeId: change.changeId,
        requestHash,
        entity: change.entity,
        syncId: change.syncId,
        parentChangeId: change.parentChangeId ?? null,
        revision: change.revision,
        op: change.op,
        result: 'accepted',
        reason: null,
        expectedRevision: change.revision,
        acceptedSequence: event.sequence,
        remoteSequence: null,
      });
      return {
        changeId: event.changeId,
        result: 'accepted',
        duplicate: false,
        entity: event.entity,
        syncId: event.syncId,
        parentChangeId: event.parentChangeId,
        revision: event.revision,
        sequence: event.sequence,
      };
    }

    const result: Exclude<SyncV2ReceiptResult, 'accepted'> =
      requestedRevision <= headRevision
        ? 'conflict'
        : !parentMatches &&
            (requestedRevision === expectedRevision || parentWasNotAccepted)
          ? 'blocked'
          : 'rejected';
    const reason: SyncV2ReceiptReason =
      result === 'blocked'
        ? 'blocked_by_ancestor'
        : result === 'conflict'
          ? 'remote_ahead'
          : 'revision_gap';
    const remote = head
      ? await this.requiredEvent(tx, userId, head.eventSequence)
      : null;
    await tx.saveReceipt({
      userId,
      changeId: change.changeId,
      requestHash,
      entity: change.entity,
      syncId: change.syncId,
      parentChangeId: change.parentChangeId ?? null,
      revision: change.revision,
      op: change.op,
      result,
      reason,
      expectedRevision: expectedRevision.toString(),
      acceptedSequence: null,
      remoteSequence: remote?.sequence ?? null,
    });
    return this.persistedFailureAck(
      change,
      result,
      reason,
      expectedRevision.toString(),
      remote ? this.presentEvent(remote) : null,
      false,
    );
  }

  private async processBlockedChange(
    tx: SyncV2Transaction,
    userId: number,
    item: PreparedChange,
  ): Promise<SyncV2Ack> {
    const { change, requestHash } = item;
    const receipt = await tx.findReceipt(userId, change.changeId);
    if (receipt) {
      if (receipt.requestHash !== requestHash) {
        return this.reusedChangeIdAck(change);
      }
      return this.replayReceipt(tx, userId, receipt);
    }
    const head = await tx.findHead(userId, change.entity, change.syncId);
    const expectedRevision = (
      (head ? BigInt(head.revision) : BigInt(0)) + BigInt(1)
    ).toString();
    const remote = head
      ? await this.requiredEvent(tx, userId, head.eventSequence)
      : null;
    await tx.saveReceipt({
      userId,
      changeId: change.changeId,
      requestHash,
      entity: change.entity,
      syncId: change.syncId,
      parentChangeId: change.parentChangeId ?? null,
      revision: change.revision,
      op: change.op,
      result: 'blocked',
      reason: 'blocked_by_ancestor',
      expectedRevision,
      acceptedSequence: null,
      remoteSequence: remote?.sequence ?? null,
    });
    return this.persistedFailureAck(
      change,
      'blocked',
      'blocked_by_ancestor',
      expectedRevision,
      remote ? this.presentEvent(remote) : null,
      false,
    );
  }

  private async replayReceipt(
    tx: SyncV2Transaction,
    userId: number,
    receipt: SyncV2ReceiptEntity,
  ): Promise<SyncV2Ack> {
    if (receipt.result === 'accepted') {
      if (!receipt.acceptedSequence) {
        throw new InternalServerErrorException('accepted receipt 缺少 event');
      }
      const event = await this.requiredEvent(
        tx,
        userId,
        receipt.acceptedSequence,
      );
      return {
        changeId: receipt.changeId,
        result: 'accepted',
        duplicate: true,
        entity: receipt.entity,
        syncId: receipt.syncId,
        parentChangeId: event.parentChangeId,
        revision: receipt.revision,
        sequence: event.sequence,
      };
    }
    const remote = receipt.remoteSequence
      ? await this.requiredEvent(tx, userId, receipt.remoteSequence)
      : null;
    return this.persistedFailureAck(
      receipt,
      receipt.result,
      receipt.reason,
      receipt.expectedRevision,
      remote ? this.presentEvent(remote) : null,
      true,
    );
  }

  private async requiredEvent(
    tx: SyncV2Transaction,
    userId: number,
    sequence: string,
  ) {
    const event = await tx.findEvent(userId, sequence);
    if (!event) {
      throw new InternalServerErrorException(
        `sync v2 event ${sequence} 不存在`,
      );
    }
    return event;
  }

  private persistedFailureAck(
    change: {
      changeId: string;
      entity: string;
      syncId: string;
      parentChangeId?: string | null;
      revision: string;
    },
    result: Exclude<SyncV2ReceiptResult, 'accepted'>,
    reason: SyncV2ReceiptReason | null,
    expectedRevision: string,
    remote: PresentedSyncV2Event | null,
    duplicate: boolean,
  ): RemoteAheadAck | RevisionGapAck | BlockedAck {
    const common = {
      changeId: change.changeId,
      duplicate,
      entity: change.entity,
      syncId: change.syncId,
      parentChangeId: change.parentChangeId ?? null,
      revision: change.revision,
      expectedRevision,
      remote,
    };
    if (result === 'conflict' && reason === 'remote_ahead') {
      return { ...common, result, reason };
    }
    if (result === 'rejected' && reason === 'revision_gap') {
      return { ...common, result, reason };
    }
    if (result === 'blocked' && reason === 'blocked_by_ancestor') {
      return { ...common, result, reason };
    }
    throw new InternalServerErrorException(
      `非法 sync v2 receipt 状态: ${result}/${reason ?? 'null'}`,
    );
  }

  private reusedChangeIdAck(change: SyncV2ChangeDto): ChangeIdReusedAck {
    return {
      changeId: change.changeId,
      result: 'rejected',
      duplicate: false,
      entity: change.entity,
      syncId: change.syncId,
      parentChangeId: change.parentChangeId ?? null,
      revision: change.revision,
      reason: 'change_id_reused',
    };
  }

  private presentEvent(event: SyncV2EventEntity): PresentedSyncV2Event {
    return {
      sequence: event.sequence,
      changeId: event.changeId,
      entity: event.entity,
      syncId: event.syncId,
      parentChangeId: event.parentChangeId,
      revision: event.revision,
      op: event.op,
      payload: event.payload,
      deviceId: event.deviceId,
      serverCreatedAt: event.serverCreatedAt.toISOString(),
    };
  }

  private isPlainObject(value: unknown): value is Record<string, unknown> {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  private canonicalStringify(value: unknown): string {
    if (Array.isArray(value)) {
      return `[${value.map((item) => this.canonicalStringify(item)).join(',')}]`;
    }
    if (value !== null && typeof value === 'object') {
      const map = value as Record<string, unknown>;
      return `{${Object.keys(map)
        .filter((key) => map[key] !== undefined)
        .sort()
        .map(
          (key) =>
            `${JSON.stringify(key)}:${this.canonicalStringify(map[key])}`,
        )
        .join(',')}}`;
    }
    const encoded = JSON.stringify(value);
    return encoded === undefined ? 'null' : encoded;
  }
}
