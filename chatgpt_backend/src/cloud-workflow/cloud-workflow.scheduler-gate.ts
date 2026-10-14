import { ConflictException, ServiceUnavailableException } from '@nestjs/common';
import type { EntityManager } from 'typeorm';

/** 内部调度上下文，不属于用户DTO/HTTP header或模型输入。 */
export interface CloudSchedulerContext {
  epoch: string;
}
export interface SchedulerGate {
  epoch: string;
  accepting: boolean;
}
export const MAX_SCHEDULER_EPOCH = 9223372036854775807n;
export function schedulerEpoch(value: unknown): string {
  if (
    typeof value !== 'string' ||
    !/^(0|[1-9][0-9]{0,18})$/.test(value) ||
    BigInt(value) > MAX_SCHEDULER_EPOCH
  )
    throw new ConflictException('scheduler_epoch_invalid');
  return value;
}
export async function readSchedulerGate(
  tx: Pick<EntityManager, 'query'>,
): Promise<SchedulerGate> {
  const [row] = await tx.query<SchedulerGate[]>(
    'SELECT epoch::text AS epoch,accepting FROM cloud_workflow_scheduler_gate WHERE id=1 FOR UPDATE',
  );
  if (!row || typeof row.accepting !== 'boolean')
    throw new ServiceUnavailableException('scheduler_gate_missing');
  return { epoch: schedulerEpoch(row.epoch), accepting: row.accepting };
}
export async function requireSchedulerAdmission(
  tx: EntityManager,
  context?: CloudSchedulerContext,
): Promise<void> {
  if (!context)
    throw new ServiceUnavailableException('scheduler_context_required');
  const epoch = schedulerEpoch(context.epoch),
    gate = await readSchedulerGate(tx);
  if (!gate.accepting || gate.epoch !== epoch)
    throw new ConflictException('scheduler_gate_closed_or_stale');
}

// 空闲判据覆盖过期队首/租约与未结算发送；不能把claim返回null当空队列。
export const SCHEDULER_ACTIVITY_SQL = `SELECT
  (SELECT count(*)::int FROM cloud_workflow_parents WHERE state='queued') AS queued,
  (SELECT count(*)::int FROM cloud_workflow_parents WHERE state IN ('running','cancelling')) AS running,
  (SELECT count(*)::int FROM cloud_workflow_attempts WHERE state='dispatched') AS dispatched,
  EXISTS(SELECT 1 FROM cloud_workflow_slot WHERE parent_id IS NOT NULL) AS slot,
  EXISTS(SELECT 1 FROM cloud_workflow_slot WHERE id=1) AS "slotExists"`;
export interface SchedulerActivity {
  queued: number;
  running: number;
  dispatched: number;
  slot: boolean;
  slotExists: boolean;
}
export function schedulerWork(
  activity: SchedulerActivity,
): 'pending' | 'busy' | 'idle' {
  if (
    !activity ||
    activity.slotExists !== true ||
    typeof activity.slot !== 'boolean' ||
    [activity.queued, activity.running, activity.dispatched].some(
      (n) => !Number.isSafeInteger(n) || n < 0,
    )
  )
    throw new ServiceUnavailableException('scheduler_activity_unknown');
  if (activity.running || activity.dispatched || activity.slot) return 'busy';
  return activity.queued ? 'pending' : 'idle';
}
