import type { MigrationInterface, QueryRunner } from 'typeorm';

/** 向前追加一次性发送意图；旧 attempt 没有上下文，不能获得新发送许可。 */
export class AddCloudDispatchPermit1784050000000 implements MigrationInterface {
  name = 'AddCloudDispatchPermit1784050000000';
  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE cloud_workflow_attempts
      ADD COLUMN request_digest char(64), ADD COLUMN input_refs jsonb,
      ADD COLUMN grant_version integer, ADD COLUMN send_authorized_at timestamptz,
      ADD COLUMN failure_code text, ADD COLUMN http_status integer`);
    await q.query(`ALTER TABLE cloud_workflow_parents ADD COLUMN final_result_id uuid
      REFERENCES cloud_workflow_results(id) ON DELETE SET NULL`);
    await q.query(`ALTER TABLE cloud_workflow_attempts ADD CONSTRAINT cloud_attempt_permit_context
      CHECK(send_authorized_at IS NULL OR
        (request_digest IS NOT NULL AND input_refs IS NOT NULL AND grant_version IS NOT NULL))`);
  }
  async down(q: QueryRunner): Promise<void> {
    await q.query(
      'ALTER TABLE cloud_workflow_parents DROP COLUMN final_result_id',
    );
    await q.query(`ALTER TABLE cloud_workflow_attempts
      DROP CONSTRAINT cloud_attempt_permit_context,
      DROP COLUMN request_digest, DROP COLUMN input_refs, DROP COLUMN grant_version,
      DROP COLUMN send_authorized_at, DROP COLUMN failure_code, DROP COLUMN http_status`);
  }
}
