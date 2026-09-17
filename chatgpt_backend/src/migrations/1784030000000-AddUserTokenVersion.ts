import type { MigrationInterface, QueryRunner } from 'typeorm';

export class AddUserTokenVersion1784030000000 implements MigrationInterface {
  name = 'AddUserTokenVersion1784030000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "tokenVersion" integer NOT NULL DEFAULT 0',
    );
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      'ALTER TABLE "users" DROP COLUMN IF EXISTS "tokenVersion"',
    );
  }
}
