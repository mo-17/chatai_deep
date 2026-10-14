import { Injectable, BadRequestException } from '@nestjs/common';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import { CloudWorkflowStore } from './cloud-workflow.store';
import type { CloudSchedulerContext } from './cloud-workflow.scheduler-gate';
import {
  CloudAuthorization,
  integer,
  object,
  parseCloudPayload,
  parseOperation,
  uuid,
  CLOUD_LIMITS,
} from './cloud-workflow.contract';

@Injectable()
export class CloudWorkflowService {
  constructor(
    private readonly store: CloudWorkflowStore,
    private readonly readiness: CloudWorkflowReadiness,
  ) {}
  capabilities(a: CloudAuthorization) {
    return { ...this.readiness.capabilities(), ownerId: a.userId };
  }
  profiles() {
    return this.store.profiles();
  }
  byIdempotency(a: CloudAuthorization, key: string) {
    return this.store.byIdempotency(a.userId, uuid(key));
  }
  create(
    a: CloudAuthorization,
    body: unknown,
    scheduler?: CloudSchedulerContext,
  ) {
    this.readiness.requireReady();
    return this.store.create(a, parseCloudPayload(body), Date.now, scheduler);
  }
  detail(a: CloudAuthorization, id: string) {
    return this.store.detail(a.userId, uuid(id));
  }
  results(a: CloudAuthorization, id: string) {
    return this.store.results(a.userId, uuid(id));
  }
  async list(a: CloudAuthorization, cursor?: string, limit?: string) {
    if (limit !== undefined && !/^[1-9]\d*$/.test(limit))
      throw new BadRequestException('分页数量无效');
    const take = integer(limit === undefined ? 20 : Number(limit), 1, 50);
    const rows = await this.store.list(
      a.userId,
      cursor === undefined ? null : uuid(cursor),
      take + 1,
    );
    const hasMore = rows.length > take;
    return {
      items: rows.slice(0, take),
      nextCursor: hasMore ? rows[take - 1].id : null,
    };
  }
  control(
    a: CloudAuthorization,
    id: string,
    kind: 'stop' | 'delete' | 'continue',
    body: unknown,
    scheduler?: CloudSchedulerContext,
  ) {
    if (kind === 'continue') {
      this.readiness.requireReady();
      const p = object(body, [
        'operationId',
        'expectedRevision',
        'grantDurationMs',
      ]);
      return this.store.control(
        a,
        uuid(id),
        kind,
        parseOperation({
          operationId: p.operationId,
          expectedRevision: p.expectedRevision,
        }),
        integer(p.grantDurationMs, 1, CLOUD_LIMITS.durationMs),
        Date.now,
        scheduler,
      );
    }
    return this.store.control(a, uuid(id), kind, parseOperation(body));
  }
  revokeClient(a: CloudAuthorization, body: unknown) {
    const p = object(body, ['clientInstanceId', 'operationId']);
    return this.store.revokeClient(
      a,
      uuid(p.clientInstanceId),
      uuid(p.operationId),
    );
  }
}
