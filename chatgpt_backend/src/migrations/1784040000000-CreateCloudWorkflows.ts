import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreateCloudWorkflows1784040000000 implements MigrationInterface {
  name = 'CreateCloudWorkflows1784040000000';
  async up(q: QueryRunner): Promise<void> {
    await q.query(`CREATE TABLE cloud_workflow_parents (
      id uuid PRIMARY KEY, owner_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      idempotency_key uuid NOT NULL, payload_hash char(64) NOT NULL, payload jsonb,
      client_instance_id uuid NOT NULL, state text NOT NULL DEFAULT 'queued',
      revision integer NOT NULL DEFAULT 1 CHECK(revision > 0), reason text,
      security_version integer NOT NULL, grant_version integer NOT NULL DEFAULT 1,
      grant_expires_at timestamptz NOT NULL, deadline_at timestamptz NOT NULL,
      max_attempts integer NOT NULL CHECK(max_attempts BETWEEN 1 AND 8),
      token_limit integer NOT NULL CHECK(token_limit BETWEEN 2048 AND 32000),
      output_tokens integer NOT NULL CHECK(output_tokens BETWEEN 1 AND 2048),
      attempts_used integer NOT NULL DEFAULT 0 CHECK(attempts_used BETWEEN 0 AND 8),
      estimated_tokens integer NOT NULL DEFAULT 0 CHECK(estimated_tokens BETWEEN 0 AND 32000),
      usage_unknown boolean NOT NULL DEFAULT false,
      reworks integer NOT NULL DEFAULT 0 CHECK(reworks BETWEEN 0 AND 1),
      fence bigint NOT NULL DEFAULT 0, lease_owner uuid, lease_expires_at timestamptz,
      publication_id uuid NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE(owner_id,idempotency_key), UNIQUE(id,owner_id),
      CHECK(state IN ('queued','running','paused','needs_configuration','budget_exhausted','cancelling','cancelled','failed','complete','deleted')),
      CHECK(attempts_used <= max_attempts AND estimated_tokens <= token_limit),
      CHECK((state='deleted') = (payload IS NULL))
    )`);
    await q.query(`CREATE UNIQUE INDEX cloud_workflow_owner_active ON cloud_workflow_parents(owner_id)
      WHERE state IN ('queued','running','paused','needs_configuration','budget_exhausted','cancelling')`);
    await q.query(
      `CREATE INDEX cloud_workflow_owner_page ON cloud_workflow_parents(owner_id,created_at DESC,id DESC)`,
    );
    await q.query(`CREATE TABLE cloud_workflow_steps (
      id uuid PRIMARY KEY, parent_id uuid NOT NULL, owner_id integer NOT NULL,
      role text NOT NULL CHECK(role IN ('analysis','writing','review')), ordinal integer NOT NULL CHECK(ordinal BETWEEN 0 AND 2),
      provider_id integer NOT NULL, model_row_id integer NOT NULL, profile_hash char(64) NOT NULL,
      state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','failed','unknown','complete')),
      revision integer NOT NULL DEFAULT 1, result_version integer NOT NULL DEFAULT 0,
      checkpoint jsonb, UNIQUE(parent_id,role), UNIQUE(id,parent_id,owner_id),
      FOREIGN KEY(parent_id,owner_id) REFERENCES cloud_workflow_parents(id,owner_id) ON DELETE CASCADE
    )`);
    await q.query(`CREATE TABLE cloud_workflow_attempts (
      id uuid PRIMARY KEY, parent_id uuid NOT NULL, step_id uuid NOT NULL, owner_id integer NOT NULL,
      fence bigint NOT NULL, number integer NOT NULL CHECK(number BETWEEN 1 AND 8),
      state text NOT NULL CHECK(state IN ('dispatched','succeeded','failed','unknown')),
      estimated_tokens integer NOT NULL, input_tokens integer, output_tokens integer,
      created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz,
      UNIQUE(parent_id,number), UNIQUE(id,parent_id,owner_id),
      FOREIGN KEY(step_id,parent_id,owner_id) REFERENCES cloud_workflow_steps(id,parent_id,owner_id) ON DELETE CASCADE
    )`);
    await q.query(`CREATE TABLE cloud_workflow_results (
      id uuid PRIMARY KEY, parent_id uuid NOT NULL, owner_id integer NOT NULL, step_id uuid NOT NULL,
      attempt_id uuid NOT NULL UNIQUE, version integer NOT NULL, content text NOT NULL,
      content_hash char(64) NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE(step_id,version),
      FOREIGN KEY(step_id,parent_id,owner_id) REFERENCES cloud_workflow_steps(id,parent_id,owner_id) ON DELETE CASCADE,
      FOREIGN KEY(attempt_id,parent_id,owner_id) REFERENCES cloud_workflow_attempts(id,parent_id,owner_id) ON DELETE CASCADE
    )`);
    await q.query(`CREATE TABLE cloud_workflow_events (
      sequence bigserial PRIMARY KEY, parent_id uuid NOT NULL, owner_id integer NOT NULL,
      code text NOT NULL, revision integer NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
      FOREIGN KEY(parent_id,owner_id) REFERENCES cloud_workflow_parents(id,owner_id) ON DELETE CASCADE
    )`);
    await q.query(`CREATE TABLE cloud_workflow_operations (
      owner_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, operation_id uuid NOT NULL,
      parent_id uuid NOT NULL, kind text NOT NULL, request_hash char(64) NOT NULL, response jsonb NOT NULL,
      PRIMARY KEY(owner_id,operation_id),
      FOREIGN KEY(parent_id,owner_id) REFERENCES cloud_workflow_parents(id,owner_id) ON DELETE CASCADE
    )`);
    await q.query(`CREATE TABLE cloud_workflow_client_operations (
      owner_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, operation_id uuid NOT NULL,
      request_hash char(64) NOT NULL, response jsonb NOT NULL, PRIMARY KEY(owner_id,operation_id)
    )`);
    // 撤权/删正文后仍占自己的执行槽，直到实际结算或租约过期，防在途与后继并发。
    await q.query(`CREATE TABLE cloud_workflow_slot (
      id integer PRIMARY KEY CHECK(id=1), parent_id uuid, lease_owner uuid, fence bigint, expires_at timestamptz
    )`);
    await q.query('INSERT INTO cloud_workflow_slot(id) VALUES(1)');
  }
  async down(q: QueryRunner): Promise<void> {
    for (const table of [
      'cloud_workflow_slot',
      'cloud_workflow_client_operations',
      'cloud_workflow_operations',
      'cloud_workflow_events',
      'cloud_workflow_results',
      'cloud_workflow_attempts',
      'cloud_workflow_steps',
      'cloud_workflow_parents',
    ]) {
      await q.query(`DROP TABLE ${table}`);
    }
  }
}
