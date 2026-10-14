// 仅用于隔离合成测试，不含生产凭据/数据，也不启动网络服务。
import { randomUUID } from 'node:crypto';
import {
  CloudPayloadV1,
  CloudPayload,
  CloudAuthorization,
  CloudOperation,
  CLOUD_CONSENT_VERSION,
  hashText,
} from './cloud-workflow.contract';
export function fixturePayload(): CloudPayloadV1 {
  return {
    version: 1,
    consentVersion: CLOUD_CONSENT_VERSION,
    idempotencyKey: randomUUID(),
    clientInstanceId: randomUUID(),
    source: {
      cid: 77,
      messageId: randomUUID(),
      contentHash: hashText('synthetic source'),
    },
    task: '写一份合成说明',
    acceptance: {
      format: 'md',
      outputName: 'result.md',
      minChars: 0,
      maxChars: 12000,
      requiredTerms: ['合成'],
      requireFullRead: true,
    },
    inputs: [
      {
        title: '合成输入',
        text: '仅此文本快照',
        contentHash: hashText('仅此文本快照'),
      },
    ],
    profiles: {
      analysis: { providerId: 1, modelRowId: 1 },
      writing: { providerId: 1, modelRowId: 1 },
      review: { providerId: 1, modelRowId: 1 },
    },
    budget: {
      attempts: 8,
      estimatedTokens: 32000,
      outputTokens: 2048,
      durationMs: 600000,
      reworks: 1,
    },
    grantDurationMs: 600000,
  };
}

// 明确注入的测试接单上下文，生产模块从不引用此fixture。
import { DataSource } from 'typeorm';
import { CloudWorkflowStore } from './cloud-workflow.store';
import type { CloudSchedulerContext } from './cloud-workflow.scheduler-gate';
export class SyntheticAdmittedStore extends CloudWorkflowStore {
  constructor(
    db: DataSource,
    private readonly admission: CloudSchedulerContext,
  ) {
    super(db);
  }
  create(
    a: CloudAuthorization,
    p: CloudPayload,
    clock: () => number = Date.now,
    context = this.admission,
  ) {
    return super.create(a, p, clock, context);
  }
  control(
    a: CloudAuthorization,
    id: string,
    kind: 'stop' | 'delete' | 'continue',
    op: CloudOperation,
    duration?: number,
    clock: () => number = Date.now,
    context = this.admission,
  ) {
    return super.control(a, id, kind, op, duration, clock, context);
  }
}
