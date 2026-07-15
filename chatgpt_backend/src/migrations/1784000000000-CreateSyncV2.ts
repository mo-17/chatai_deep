import type { MigrationInterface, QueryRunner } from 'typeorm';

export class CreateSyncV21784000000000 implements MigrationInterface {
  name = 'CreateSyncV21784000000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE "sync_v2_events" (
        "sequence" BIGSERIAL NOT NULL,
        "user_id" integer NOT NULL,
        "change_id" uuid NOT NULL,
        "entity" varchar(64) NOT NULL,
        "sync_id" uuid NOT NULL,
        "parent_change_id" uuid,
        "revision" bigint NOT NULL,
        "op" varchar(8) NOT NULL,
        "payload" jsonb,
        "device_id" uuid NOT NULL,
        "server_created_at" timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT "PK_sync_v2_events" PRIMARY KEY ("sequence"),
        CONSTRAINT "UQ_sync_v2_events_user_change"
          UNIQUE ("user_id", "change_id"),
        CONSTRAINT "UQ_sync_v2_events_user_sequence"
          UNIQUE ("user_id", "sequence"),
        CONSTRAINT "UQ_sync_v2_events_user_entity_revision"
          UNIQUE ("user_id", "entity", "sync_id", "revision"),
        CONSTRAINT "UQ_sync_v2_events_user_sequence_change"
          UNIQUE ("user_id", "sequence", "change_id"),
        CONSTRAINT "CHK_sync_v2_events_revision" CHECK ("revision" >= 1),
        CONSTRAINT "CHK_sync_v2_events_op"
          CHECK ("op" IN ('upsert', 'delete')),
        CONSTRAINT "CHK_sync_v2_events_payload" CHECK (
          ("op" = 'delete' AND "payload" IS NULL) OR
          ("op" = 'upsert' AND "payload" IS NOT NULL
            AND jsonb_typeof("payload") = 'object')
        ),
        CONSTRAINT "FK_sync_v2_events_user" FOREIGN KEY ("user_id")
          REFERENCES "users" ("id") ON DELETE CASCADE,
        CONSTRAINT "FK_sync_v2_events_parent" FOREIGN KEY
          ("user_id", "parent_change_id")
          REFERENCES "sync_v2_events" ("user_id", "change_id")
          ON DELETE CASCADE
      )
    `);
    await queryRunner.query(`
      CREATE TABLE "sync_v2_heads" (
        "id" BIGSERIAL NOT NULL,
        "user_id" integer NOT NULL,
        "entity" varchar(64) NOT NULL,
        "sync_id" uuid NOT NULL,
        "change_id" uuid NOT NULL,
        "revision" bigint NOT NULL,
        "event_sequence" bigint NOT NULL,
        "op" varchar(8) NOT NULL,
        "updated_at" timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT "PK_sync_v2_heads" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_sync_v2_heads_user_entity_sync"
          UNIQUE ("user_id", "entity", "sync_id"),
        CONSTRAINT "CHK_sync_v2_heads_revision" CHECK ("revision" >= 1),
        CONSTRAINT "CHK_sync_v2_heads_op"
          CHECK ("op" IN ('upsert', 'delete')),
        CONSTRAINT "FK_sync_v2_heads_user" FOREIGN KEY ("user_id")
          REFERENCES "users" ("id") ON DELETE CASCADE,
        CONSTRAINT "FK_sync_v2_heads_event" FOREIGN KEY
          ("user_id", "event_sequence", "change_id")
          REFERENCES "sync_v2_events"
            ("user_id", "sequence", "change_id")
          ON DELETE CASCADE
      )
    `);

    await queryRunner.query(`
      CREATE TABLE "sync_v2_receipts" (
        "id" BIGSERIAL NOT NULL,
        "user_id" integer NOT NULL,
        "change_id" uuid NOT NULL,
        "request_hash" char(64) NOT NULL,
        "entity" varchar(64) NOT NULL,
        "sync_id" uuid NOT NULL,
        "parent_change_id" uuid,
        "revision" bigint NOT NULL,
        "op" varchar(8) NOT NULL,
        "result" varchar(16) NOT NULL,
        "reason" varchar(32),
        "expected_revision" bigint NOT NULL,
        "accepted_sequence" bigint,
        "remote_sequence" bigint,
        "created_at" timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT "PK_sync_v2_receipts" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_sync_v2_receipts_user_change"
          UNIQUE ("user_id", "change_id"),
        CONSTRAINT "CHK_sync_v2_receipts_result"
          CHECK ("result" IN ('accepted', 'conflict', 'rejected', 'blocked')),
        CONSTRAINT "CHK_sync_v2_receipts_reason" CHECK (
          "reason" IS NULL OR
          "reason" IN ('remote_ahead', 'revision_gap', 'blocked_by_ancestor')
        ),
        CONSTRAINT "CHK_sync_v2_receipts_links" CHECK (
          ("result" = 'accepted' AND "accepted_sequence" IS NOT NULL
            AND "remote_sequence" IS NULL AND "reason" IS NULL) OR
          ("result" = 'conflict' AND "accepted_sequence" IS NULL
            AND "remote_sequence" IS NOT NULL
            AND "reason" IS NOT NULL
            AND "reason" = 'remote_ahead') OR
          ("result" = 'rejected' AND "accepted_sequence" IS NULL
            AND "reason" IS NOT NULL
            AND "reason" = 'revision_gap') OR
          ("result" = 'blocked' AND "accepted_sequence" IS NULL
            AND "reason" IS NOT NULL
            AND "reason" = 'blocked_by_ancestor')
        ),
        CONSTRAINT "FK_sync_v2_receipts_user" FOREIGN KEY ("user_id")
          REFERENCES "users" ("id") ON DELETE CASCADE,
        CONSTRAINT "FK_sync_v2_receipts_accepted_event" FOREIGN KEY
          ("user_id", "accepted_sequence", "change_id")
          REFERENCES "sync_v2_events"
            ("user_id", "sequence", "change_id")
          ON DELETE CASCADE,
        CONSTRAINT "FK_sync_v2_receipts_remote_event" FOREIGN KEY
          ("user_id", "remote_sequence")
          REFERENCES "sync_v2_events" ("user_id", "sequence")
          ON DELETE CASCADE
      )
    `);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE "sync_v2_receipts"');
    await queryRunner.query('DROP TABLE "sync_v2_heads"');
    await queryRunner.query('DROP TABLE "sync_v2_events"');
  }
}
