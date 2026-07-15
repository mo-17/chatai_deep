import type { MigrationInterface, QueryRunner } from 'typeorm';

export class AddAppVersionSha2561784020000000 implements MigrationInterface {
  name = 'AddAppVersionSha2561784020000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      'ALTER TABLE "app_versions" ADD COLUMN IF NOT EXISTS "sha256" varchar(64)',
    );
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      'ALTER TABLE "app_versions" DROP COLUMN IF EXISTS "sha256"',
    );
  }
}
