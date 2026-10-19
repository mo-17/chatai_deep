import type { MigrationInterface, QueryRunner } from 'typeorm';

export class TrialGuardrails1784130000000 implements MigrationInterface {
  async up(runner: QueryRunner): Promise<void> {
    await runner.query(`ALTER TABLE access_policy
      ADD COLUMN "requireVerifiedEmail" boolean NOT NULL DEFAULT true,
      ADD COLUMN "requestsPerMinute" integer NOT NULL DEFAULT 6,
      ADD COLUMN "globalMaxConcurrent" integer NOT NULL DEFAULT 4`);
    await runner.query(
      `ALTER TABLE access_requests ADD COLUMN "createdAt" timestamptz`,
    );
    // 旧请求按原记账日回填，避免发布瞬间被当成本分钟的新请求。
    await runner.query(
      `UPDATE access_requests SET "createdAt"=day::timestamp AT TIME ZONE 'UTC'`,
    );
    await runner.query(
      `ALTER TABLE access_requests ALTER COLUMN "createdAt" SET DEFAULT now(), ALTER COLUMN "createdAt" SET NOT NULL`,
    );
    await runner.query(
      `CREATE INDEX idx_access_recent ON access_requests("createdAt", "userId")`,
    );
  }
  async down(runner: QueryRunner): Promise<void> {
    await runner.query(`DROP INDEX idx_access_recent`);
    await runner.query(`ALTER TABLE access_requests DROP COLUMN "createdAt"`);
    await runner.query(
      `ALTER TABLE access_policy DROP COLUMN "requireVerifiedEmail", DROP COLUMN "requestsPerMinute", DROP COLUMN "globalMaxConcurrent"`,
    );
  }
}
