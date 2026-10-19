import type { MigrationInterface, QueryRunner } from 'typeorm';
export class AddProductOperations1784120000000 implements MigrationInterface {
  async up(runner: QueryRunner): Promise<void> {
    await runner.query(`CREATE TABLE IF NOT EXISTS access_policy (
      id integer PRIMARY KEY DEFAULT 1 CHECK(id=1), "limitsEnabled" boolean NOT NULL DEFAULT false,
      "trialEnabled" boolean NOT NULL DEFAULT false, "trialProviderCode" varchar NOT NULL DEFAULT '', "trialModel" varchar NOT NULL DEFAULT '',
      "dailyRequests" integer NOT NULL DEFAULT 100, "dailyTokens" integer NOT NULL DEFAULT 10000, "globalDailyTokens" integer NOT NULL DEFAULT 100000,
      "globalDailyRequests" integer NOT NULL DEFAULT 500, "maxConcurrent" integer NOT NULL DEFAULT 1, "maxOutputTokens" integer NOT NULL DEFAULT 2048)`);
    await runner.query(`CREATE TABLE IF NOT EXISTS access_requests (
      id uuid PRIMARY KEY, "userId" integer NOT NULL, day date NOT NULL, model varchar NOT NULL,
      "chargedTokens" integer NOT NULL DEFAULT 0, "activeUntil" timestamptz NULL)`);
    await runner.query(
      `CREATE INDEX IF NOT EXISTS idx_access_day_user ON access_requests(day,"userId")`,
    );
    await runner.query(
      `CREATE INDEX IF NOT EXISTS idx_access_active ON access_requests("userId","activeUntil")`,
    );
    await runner.query(`CREATE TABLE IF NOT EXISTS user_feedback (
      id SERIAL PRIMARY KEY, "userId" integer NOT NULL, "requestId" uuid NOT NULL, category varchar(20) NOT NULL,
      content text NOT NULL, diagnostics jsonb NOT NULL DEFAULT '{}', status varchar NOT NULL DEFAULT 'open', reply text NOT NULL DEFAULT '',
      "createdAt" timestamp NOT NULL DEFAULT now(), "updatedAt" timestamp NOT NULL DEFAULT now(), UNIQUE("userId","requestId"))`);
    await runner.query(
      `CREATE INDEX IF NOT EXISTS idx_feedback_user_date ON user_feedback("userId","createdAt")`,
    );
    await runner.query(
      `ALTER TABLE app_versions ADD COLUMN IF NOT EXISTS artifacts jsonb NOT NULL DEFAULT '{}'`,
    );
    await runner.query(
      `ALTER TABLE app_versions ADD COLUMN IF NOT EXISTS "rolloutPercent" integer NOT NULL DEFAULT 100 CHECK("rolloutPercent" BETWEEN 0 AND 100)`,
    );
    await runner.query(
      `ALTER TABLE app_versions ADD COLUMN IF NOT EXISTS "rolloutSalt" varchar NOT NULL DEFAULT ''`,
    );
  }
  async down(runner: QueryRunner): Promise<void> {
    await runner.query(
      'ALTER TABLE app_versions DROP COLUMN IF EXISTS "rolloutSalt", DROP COLUMN IF EXISTS "rolloutPercent", DROP COLUMN IF EXISTS artifacts',
    );
    await runner.query(
      'DROP TABLE IF EXISTS user_feedback, access_requests, access_policy',
    );
  }
}
