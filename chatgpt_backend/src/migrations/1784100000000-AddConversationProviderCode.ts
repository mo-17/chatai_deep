import type { MigrationInterface, QueryRunner } from 'typeorm';

export class AddConversationProviderCode1784100000000 implements MigrationInterface {
  name = 'AddConversationProviderCode1784100000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      'ALTER TABLE "conversations" ADD COLUMN "providerCode" character varying',
    );
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    // 表锁封住检查与 DROP 之间的 CRUD；旧快照隔离不适合此保护检查。
    if (!queryRunner.isTransactionActive) {
      throw new Error('回退需要活动的 READ COMMITTED 事务');
    }
    const isolation = (await queryRunner.query(
      'SHOW transaction_isolation',
    )) as Array<{ transaction_isolation: string }>;
    if (isolation[0]?.transaction_isolation !== 'read committed') {
      throw new Error('回退需要活动的 READ COMMITTED 事务');
    }
    await queryRunner.query(
      'LOCK TABLE "conversations" IN ACCESS EXCLUSIVE MODE',
    );
    const selected = (await queryRunner.query(
      'SELECT id FROM "conversations" WHERE "providerCode" IS NOT NULL LIMIT 1',
    )) as Array<{ id: number }>;
    if (selected.length !== 0) {
      throw new Error('已保存服务商选择，请保留新增列并先备份；回退已拒绝');
    }
    await queryRunner.query(
      'ALTER TABLE "conversations" DROP COLUMN "providerCode"',
    );
  }
}
