import type { MigrationInterface, QueryRunner } from 'typeorm';
export class AddMicrosoftSmtpOAuth1784080000000 implements MigrationInterface {
  name = 'AddMicrosoftSmtpOAuth1784080000000';
  async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE ak_smtp_providers ADD COLUMN "authMode" varchar NOT NULL DEFAULT 'password',
      ADD COLUMN "configRevision" integer NOT NULL DEFAULT 0 CHECK ("configRevision">=0),
      ADD COLUMN "lastTestRevision" integer, ADD COLUMN "microsoftClientId" uuid,
      ADD COLUMN "microsoftClientSecretEncrypted" text,
      ADD CONSTRAINT ak_smtp_auth_mode_check CHECK ("authMode" IN ('password','microsoft_oauth')),
      ADD CONSTRAINT ak_smtp_ms_generic_check CHECK ("authMode"='password' OR key='generic')`);
    await q.query(`CREATE TABLE ak_microsoft_smtp_connections (
      "providerId" integer PRIMARY KEY REFERENCES ak_smtp_providers(id) ON DELETE CASCADE,
      "schemaVersion" integer NOT NULL DEFAULT 1 CHECK ("schemaVersion"=1),
      generation integer NOT NULL DEFAULT 0 CHECK(generation>=0), "configRevision" integer NOT NULL DEFAULT 0,
      status varchar NOT NULL DEFAULT 'not_connected' CHECK(status IN ('not_connected','connected','needs_reauth')),
      "adminId" integer, "securityVersion" integer, subject text, issuer text, "emailHint" varchar(320),
      "accessEncrypted" text, "refreshEncrypted" text, "expiresAt" timestamptz,
      "leaseOwner" uuid, "leaseExpiresAt" timestamptz, fence integer NOT NULL DEFAULT 0 CHECK(fence>=0), "errorCode" varchar(64))`);
    await q.query(`CREATE TABLE ak_microsoft_smtp_flows (
      id uuid PRIMARY KEY, "providerId" integer NOT NULL REFERENCES ak_smtp_providers(id) ON DELETE CASCADE,
      "schemaVersion" integer NOT NULL DEFAULT 1 CHECK("schemaVersion"=1),
      generation integer NOT NULL, "configRevision" integer NOT NULL, "adminId" integer NOT NULL,
      "securityVersion" integer NOT NULL, "authorizationExpiresAt" timestamptz NOT NULL, "bearerHash" char(64) NOT NULL, "cookieHash" char(64) NOT NULL,
      "stateHash" char(64) NOT NULL UNIQUE, "nonceHash" char(64) NOT NULL, "redirectUri" text NOT NULL,
      "verifierEncrypted" text, "codeEncrypted" text,
      status varchar NOT NULL CHECK(status IN ('started','received','exchanging','connected','failed','unknown','cancelled','expired')),
      "expiresAt" timestamptz NOT NULL, "leaseOwner" uuid, "leaseExpiresAt" timestamptz,
      fence integer NOT NULL DEFAULT 0 CHECK(fence>=0), "errorCode" varchar(64))`);
    await q.query(
      'CREATE INDEX ak_ms_smtp_flow_provider ON ak_microsoft_smtp_flows ("providerId",generation)',
    );
  }
  async down(q: QueryRunner): Promise<void> {
    // 回退后旧密码程序也不得接管 OAuth 凭据或突然启用基本认证。
    await q.query(
      `UPDATE ak_smtp_providers SET enabled=false,"passwordEncrypted"='' WHERE "authMode"='microsoft_oauth'`,
    );
    await q.query('DROP TABLE ak_microsoft_smtp_flows');
    await q.query('DROP TABLE ak_microsoft_smtp_connections');
    await q.query(`ALTER TABLE ak_smtp_providers DROP CONSTRAINT ak_smtp_ms_generic_check, DROP CONSTRAINT ak_smtp_auth_mode_check,
      DROP COLUMN "authMode", DROP COLUMN "configRevision", DROP COLUMN "lastTestRevision", DROP COLUMN "microsoftClientId", DROP COLUMN "microsoftClientSecretEncrypted"`);
  }
}
