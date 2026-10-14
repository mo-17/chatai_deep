import type { MigrationInterface, QueryRunner } from 'typeorm';
import {
  SCHEDULER_ACTIVITY_SQL,
  schedulerWork,
  type SchedulerActivity,
} from '../cloud-workflow/cloud-workflow.scheduler-gate';

/** 单行关闭种子；不会读取配置/调度或修改既有任务授权。 */
export class AddCloudSchedulerGate1784060000000 implements MigrationInterface {
  name = 'AddCloudSchedulerGate1784060000000';
  async up(q: QueryRunner): Promise<void> {
    await q.query(`CREATE TABLE cloud_workflow_scheduler_gate (
      id smallint PRIMARY KEY CHECK(id=1), epoch bigint NOT NULL CHECK(epoch>=0),
      accepting boolean NOT NULL DEFAULT false)`);
    await q.query(
      'INSERT INTO cloud_workflow_scheduler_gate VALUES(1,0,false)',
    );
  }
  async down(q: QueryRunner): Promise<void> {
    await q.query("SET LOCAL lock_timeout='2000ms'");
    await q.query("SET LOCAL statement_timeout='3000ms'");
    await q.query('SELECT pg_advisory_xact_lock(178404,1)');
    const [gate] = (await q.query(
      'SELECT accepting FROM cloud_workflow_scheduler_gate WHERE id=1 FOR UPDATE',
    )) as Array<{ accepting: boolean }>;
    const [activity] = (await q.query(
      SCHEDULER_ACTIVITY_SQL,
    )) as SchedulerActivity[];
    if (!gate || gate.accepting !== false || schedulerWork(activity) !== 'idle')
      throw Error('scheduler_down_requires_closed_idle');
    await q.query('DROP TABLE cloud_workflow_scheduler_gate');
  }
}
