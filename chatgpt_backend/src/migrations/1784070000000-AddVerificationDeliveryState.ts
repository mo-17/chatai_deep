import type { MigrationInterface, QueryRunner } from 'typeorm';

/** 向前升级不把旧验证码猜成已送达；所有预留均作为配额事实保留。 */
export class AddVerificationDeliveryState1784070000000 implements MigrationInterface {
  name = 'AddVerificationDeliveryState1784070000000';
  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE ak_verification_codes
      ADD COLUMN "deliveryStatus" varchar(20) NOT NULL DEFAULT 'legacy',
      ADD COLUMN "deliveryErrorCode" varchar(50),
      ADD COLUMN "deliveryDeadlineAt" timestamptz,
      ADD COLUMN "sentAt" timestamptz,
      ADD COLUMN "invalidatedAt" timestamptz,
      ADD COLUMN "invalidationReason" varchar(30)`);
    await q.query(`ALTER TABLE ak_verification_codes ADD CONSTRAINT ak_code_delivery_status_check
      CHECK ("deliveryStatus" IN ('legacy','pending','sent','failed','unknown'))`);
    await q.query(
      `ALTER TABLE ak_auth_settings ADD COLUMN "codeHourlyLimitPerIp" integer NOT NULL DEFAULT 30`,
    );
    await q.query(
      `CREATE INDEX ak_code_identifier_quota ON ak_verification_codes (channel,identifier,"createdAt" DESC,id DESC)`,
    );
    await q.query(
      `CREATE INDEX ak_code_ip_quota ON ak_verification_codes ("ipAddress","createdAt" DESC)`,
    );
  }
  async down(q: QueryRunner): Promise<void> {
    // 老程序没有 deliveryStatus，回退不能让未送达的新码变成可验证。
    await q.query(
      `UPDATE ak_verification_codes SET "consumedAt"=COALESCE("consumedAt",clock_timestamp())`,
    );
    await q.query('DROP INDEX ak_code_ip_quota');
    await q.query('DROP INDEX ak_code_identifier_quota');
    await q.query(
      'ALTER TABLE ak_auth_settings DROP COLUMN "codeHourlyLimitPerIp"',
    );
    await q.query(`ALTER TABLE ak_verification_codes DROP CONSTRAINT ak_code_delivery_status_check,
      DROP COLUMN "deliveryStatus", DROP COLUMN "deliveryErrorCode", DROP COLUMN "deliveryDeadlineAt",
      DROP COLUMN "sentAt", DROP COLUMN "invalidatedAt", DROP COLUMN "invalidationReason"`);
  }
}
