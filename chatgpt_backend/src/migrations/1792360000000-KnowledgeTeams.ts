import { MigrationInterface, QueryRunner } from 'typeorm';
export class KnowledgeTeams1792360000000 implements MigrationInterface {
  async up(q: QueryRunner) {
    await q.query(`CREATE TABLE knowledge_team (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), "ownerId" integer NOT NULL,
      name varchar(80) NOT NULL, revision integer NOT NULL DEFAULT 1,
      members jsonb NOT NULL DEFAULT '{}', documents jsonb NOT NULL DEFAULT '{}',
      answers jsonb NOT NULL DEFAULT '[]', audit jsonb NOT NULL DEFAULT '[]', "createdAt" bigint NOT NULL,
      CONSTRAINT knowledge_team_members_object CHECK(jsonb_typeof(members) = 'object'),
      CONSTRAINT knowledge_team_documents_object CHECK(jsonb_typeof(documents) = 'object'),
      CONSTRAINT knowledge_team_answers_array CHECK(jsonb_typeof(answers) = 'array'),
      CONSTRAINT knowledge_team_audit_array CHECK(jsonb_typeof(audit) = 'array'))`);
    await q.query(
      'CREATE INDEX knowledge_team_owner_idx ON knowledge_team ("ownerId")',
    );
    await q.query(
      'CREATE INDEX knowledge_team_members_idx ON knowledge_team USING gin (members)',
    );
    await q.query(`CREATE TABLE knowledge_team_invite (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), "teamId" uuid NOT NULL REFERENCES knowledge_team(id) ON DELETE CASCADE,
      "codeHash" varchar(64) NOT NULL UNIQUE, role varchar(10) NOT NULL CHECK(role IN ('editor','viewer')),
      "expiresAt" bigint NOT NULL, consumed boolean NOT NULL DEFAULT false)`);
    await q.query(
      'CREATE INDEX knowledge_team_invite_team_idx ON knowledge_team_invite ("teamId")',
    );
  }
  async down(q: QueryRunner) {
    await q.query('DROP TABLE knowledge_team_invite');
    await q.query('DROP TABLE knowledge_team');
  }
}
