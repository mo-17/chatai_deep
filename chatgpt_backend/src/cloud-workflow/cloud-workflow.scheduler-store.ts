import { Injectable, ConflictException } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { CloudWorkflowStore } from './cloud-workflow.store';
import {
  readSchedulerGate,
  schedulerEpoch,
  SCHEDULER_ACTIVITY_SQL,
  schedulerWork,
  type SchedulerGate,
  type SchedulerActivity,
} from './cloud-workflow.scheduler-gate';

export interface SchedulerStatus extends SchedulerGate {
  work: 'pending' | 'busy' | 'idle';
}
// 共用短事务操作，使私有控制复用已批准的有界ExecutionStore池，不再建共享无界等待池。
async function activity(tx: EntityManager): Promise<SchedulerActivity> {
  await tx.query('SELECT id FROM cloud_workflow_slot WHERE id=1 FOR UPDATE');
  const [row] = await tx.query<SchedulerActivity[]>(SCHEDULER_ACTIVITY_SQL);
  return row;
}
export async function schedulerStatusTx(
  tx: EntityManager,
): Promise<SchedulerStatus> {
  return {
    ...(await readSchedulerGate(tx)),
    work: schedulerWork(await activity(tx)),
  };
}
export async function schedulerOpenTx(
  tx: EntityManager,
  value: string,
): Promise<SchedulerGate> {
  const epoch = schedulerEpoch(value),
    gate = await readSchedulerGate(tx);
  if (
    BigInt(epoch) < BigInt(gate.epoch) ||
    (epoch === gate.epoch && !gate.accepting)
  )
    throw new ConflictException('scheduler_epoch_closed_or_stale');
  if (epoch !== gate.epoch)
    await tx.query(
      'UPDATE cloud_workflow_scheduler_gate SET epoch=$1,accepting=true WHERE id=1',
      [epoch],
    );
  return { epoch, accepting: true };
}
export async function schedulerCloseTx(
  tx: EntityManager,
  value: string,
): Promise<SchedulerStatus> {
  const epoch = schedulerEpoch(value),
    gate = await readSchedulerGate(tx),
    work = schedulerWork(await activity(tx));
  if (BigInt(epoch) < BigInt(gate.epoch) || work !== 'idle')
    return { ...gate, work };
  await tx.query(
    'UPDATE cloud_workflow_scheduler_gate SET epoch=$1,accepting=false WHERE id=1',
    [epoch],
  );
  return { epoch, accepting: false, work };
}
@Injectable()
export class CloudWorkflowSchedulerStore extends CloudWorkflowStore {
  status() {
    return this.locked(schedulerStatusTx);
  }
  open(epoch: string) {
    return this.locked((tx) => schedulerOpenTx(tx, epoch));
  }
  closeIfIdle(epoch: string) {
    return this.locked((tx) => schedulerCloseTx(tx, epoch));
  }
}
