import type { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 把历史上由 TypeORM synchronize 建立的 core/auth schema 纳入 migration 账本。
 *
 * CREATE IF NOT EXISTS 让已有用户库保持原表和数据不动；只有已知可安全补齐的
 * nullable/default 列会被 reconciliation。该 baseline 不播种、不改名、不删数据。
 */
export class CreateCoreBaseline1783990000000 implements MigrationInterface {
  name = 'CreateCoreBaseline1783990000000';

  async up(queryRunner: QueryRunner): Promise<void> {
    const tables = [
      `CREATE TABLE IF NOT EXISTS "users" (
        "id" SERIAL NOT NULL,
        "userName" varchar NOT NULL,
        "password" varchar,
        "avatar" varchar,
        "imoocId" varchar,
        "role" varchar NOT NULL DEFAULT 'user',
        "banned" boolean NOT NULL DEFAULT false,
        "email" varchar,
        "emailVerifiedAt" timestamptz,
        "countryCode" varchar,
        "phoneNumber" varchar,
        "phoneVerifiedAt" timestamptz,
        "huaweiUnionId" varchar,
        "huaweiOpenId" varchar,
        "appleSubject" varchar,
        "appleEmailRelay" varchar,
        CONSTRAINT "PK_a3ffb1c0c8416b9fc6f907b7433" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_226bb9aa7aa8a69991209d58f59" UNIQUE ("userName"),
        CONSTRAINT "UQ_97672ac88f789774dd47f7c8be3" UNIQUE ("email"),
        CONSTRAINT "UQ_f16ef2287f1aa63faad2f2ba7fe" UNIQUE ("huaweiUnionId"),
        CONSTRAINT "UQ_76365ad4b0ed1d58215399d51cd" UNIQUE ("appleSubject")
      )`,
      `CREATE TABLE IF NOT EXISTS "banners" (
        "id" SERIAL NOT NULL,
        "title" varchar NOT NULL,
        "subtitle" varchar,
        "cover" varchar,
        "url" varchar,
        "sticky" integer NOT NULL DEFAULT 0,
        "enabled" boolean NOT NULL DEFAULT true,
        "type" varchar NOT NULL DEFAULT 'banner',
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_e9b186b959296fcb940790d31c3" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "app_versions" (
        "id" SERIAL NOT NULL,
        "versionName" varchar NOT NULL,
        "versionCode" integer NOT NULL,
        "url" varchar,
        "description" text,
        "cid" varchar NOT NULL DEFAULT 'all',
        "forceUpdate" boolean NOT NULL DEFAULT false,
        "enabled" boolean NOT NULL DEFAULT true,
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_8d36b0dcf0c026c7aad923c80fd" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "conversations" (
        "id" SERIAL NOT NULL,
        "userId" integer NOT NULL,
        "title" varchar NOT NULL DEFAULT '',
        "model" varchar NOT NULL,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        "updatedAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_ee34f4f7ced4ec8681f26bf04ef" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "messages" (
        "id" SERIAL NOT NULL,
        "conversationId" integer NOT NULL,
        "role" varchar(16) NOT NULL,
        "content" text NOT NULL,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_18325f38ae6de43878487eff986" PRIMARY KEY ("id"),
        CONSTRAINT "FK_e5663ce0c730b2de83445e2fd19" FOREIGN KEY ("conversationId")
          REFERENCES "conversations" ("id") ON DELETE CASCADE
      )`,
      `CREATE TABLE IF NOT EXISTS "usage" (
        "id" SERIAL NOT NULL,
        "userId" integer NOT NULL,
        "provider" varchar NOT NULL,
        "model" varchar NOT NULL,
        "promptTokens" integer NOT NULL,
        "completionTokens" integer NOT NULL,
        "totalTokens" integer NOT NULL,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_7bc33e71ab6c3b71eac72950b44" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "ai_providers" (
        "id" SERIAL NOT NULL,
        "code" varchar NOT NULL,
        "displayName" varchar NOT NULL,
        "apiKey" varchar NOT NULL,
        "baseUrl" varchar NOT NULL,
        "modelPrefixes" text,
        "enabled" boolean NOT NULL DEFAULT true,
        "sortOrder" integer NOT NULL DEFAULT 0,
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_de28ebefc0fb425c37b27a4c0a7" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_f8b4f9be8cb3a69f1a7d413fda2" UNIQUE ("code")
      )`,
      `CREATE TABLE IF NOT EXISTS "ai_models" (
        "id" SERIAL NOT NULL,
        "providerId" integer NOT NULL,
        "modelId" varchar NOT NULL,
        "displayName" varchar NOT NULL,
        "description" text,
        "enabled" boolean NOT NULL DEFAULT true,
        "isDefault" boolean NOT NULL DEFAULT false,
        "sortOrder" integer NOT NULL DEFAULT 0,
        "inputPrice" numeric(10,6),
        "outputPrice" numeric(10,6),
        "supportsVision" boolean NOT NULL DEFAULT false,
        "supportsTool" boolean NOT NULL DEFAULT false,
        "supportsReasoning" boolean NOT NULL DEFAULT false,
        "supportsPdf" boolean NOT NULL DEFAULT false,
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_3d254744f0bcf6f35be5826e25e" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "ai_global_config" (
        "id" SERIAL NOT NULL,
        "defaultProviderCode" varchar NOT NULL DEFAULT 'deepseek',
        "defaultModelId" varchar NOT NULL DEFAULT 'deepseek-chat',
        "catalogPublic" boolean NOT NULL DEFAULT true,
        "avatarPath" varchar,
        "updateTime" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_bf9ad037710bc693231ab207be9" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "mcp_servers" (
        "id" SERIAL NOT NULL,
        "code" varchar NOT NULL,
        "name" varchar NOT NULL DEFAULT '',
        "transport" varchar NOT NULL DEFAULT 'http',
        "url" varchar NOT NULL DEFAULT '',
        "headers" text,
        "command" varchar NOT NULL DEFAULT '',
        "args" text,
        "env" text,
        "enabled" boolean NOT NULL DEFAULT true,
        "sortOrder" integer NOT NULL DEFAULT 0,
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_c781b3dc7cb2a5d19460b71914d" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_53c1b84bbd33c9e364fcb3287d3" UNIQUE ("code")
      )`,
      `CREATE TABLE IF NOT EXISTS "sync_changes" (
        "id" SERIAL NOT NULL,
        "userId" integer NOT NULL,
        "entity" varchar NOT NULL,
        "entityId" varchar NOT NULL,
        "op" varchar NOT NULL DEFAULT 'upsert',
        "updatedAt" bigint NOT NULL,
        "payload" jsonb,
        "deviceId" varchar,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_0a14710c731b5f3aa7715a1c478" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "ak_verification_codes" (
        "id" SERIAL NOT NULL,
        "channel" varchar(20) NOT NULL,
        "identifier" varchar(320) NOT NULL,
        "purpose" varchar(20) NOT NULL,
        "codeHash" varchar(100) NOT NULL,
        "expiresAt" timestamp NOT NULL,
        "consumedAt" timestamptz,
        "attempts" integer NOT NULL DEFAULT 0,
        "ipAddress" varchar,
        "note" varchar,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_1d0b30ed2a9bda12818d76f41f7" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "ak_smtp_providers" (
        "id" SERIAL NOT NULL,
        "key" varchar(50) NOT NULL,
        "displayName" varchar(100) NOT NULL,
        "host" varchar(255) NOT NULL,
        "port" integer NOT NULL,
        "secure" boolean NOT NULL,
        "username" varchar(255) NOT NULL,
        "passwordEncrypted" varchar(500) NOT NULL,
        "fromName" varchar(100) NOT NULL,
        "fromAddress" varchar(320) NOT NULL,
        "enabled" boolean NOT NULL DEFAULT false,
        "lastTestedAt" timestamptz,
        "lastTestStatus" varchar(20),
        "lastTestError" varchar,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        "updatedAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_f0691fe01d69e8c6becf900b3b3" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_61702e87a2dbef3447848fbbf4a" UNIQUE ("key")
      )`,
      `CREATE TABLE IF NOT EXISTS "ak_auth_settings" (
        "id" SERIAL NOT NULL,
        "huaweiPrimaryFlow" varchar(20) NOT NULL DEFAULT 'getAuthCode',
        "huaweiQuickLoginEnabled" boolean NOT NULL DEFAULT false,
        "huaweiGetAuthCodeEnabled" boolean NOT NULL DEFAULT false,
        "appleSignInEnabled" boolean NOT NULL DEFAULT false,
        "smsMockHighlight" boolean NOT NULL DEFAULT true,
        "codeTtlSeconds" integer NOT NULL DEFAULT 300,
        "codeResendIntervalSeconds" integer NOT NULL DEFAULT 60,
        "codeMaxAttempts" integer NOT NULL DEFAULT 5,
        "codeDailyLimitPerIdentifier" integer NOT NULL DEFAULT 10,
        "updatedAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_79a90e93ce7e0a1a0c436e3471b" PRIMARY KEY ("id")
      )`,
      `CREATE TABLE IF NOT EXISTS "ak_email_templates" (
        "id" SERIAL NOT NULL,
        "key" varchar(50) NOT NULL,
        "subject" varchar(200) NOT NULL,
        "body" text NOT NULL,
        "updatedAt" timestamp NOT NULL DEFAULT now(),
        CONSTRAINT "PK_00a7c39a52b4ee5b626e0d87969" PRIMARY KEY ("id"),
        CONSTRAINT "UQ_f271fcd03bdc1b58f1c11c32291" UNIQUE ("key")
      )`,
    ];

    for (const sql of tables) await queryRunner.query(sql);

    // 只补历史上可无损升级的列；不为旧数据伪造新的必填业务值。
    const reconciliation = [
      'ALTER TABLE "users" ALTER COLUMN "password" DROP NOT NULL',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "email" varchar',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "emailVerifiedAt" timestamptz',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "countryCode" varchar',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "phoneNumber" varchar',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "phoneVerifiedAt" timestamptz',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "huaweiUnionId" varchar',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "huaweiOpenId" varchar',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "appleSubject" varchar',
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "appleEmailRelay" varchar',
      'ALTER TABLE "ai_models" ADD COLUMN IF NOT EXISTS "supportsVision" boolean NOT NULL DEFAULT false',
      'ALTER TABLE "ai_models" ADD COLUMN IF NOT EXISTS "supportsTool" boolean NOT NULL DEFAULT false',
      'ALTER TABLE "ai_models" ADD COLUMN IF NOT EXISTS "supportsReasoning" boolean NOT NULL DEFAULT false',
      'ALTER TABLE "ai_models" ADD COLUMN IF NOT EXISTS "supportsPdf" boolean NOT NULL DEFAULT false',
    ];
    for (const sql of reconciliation) await queryRunner.query(sql);

    const indexes = [
      `CREATE UNIQUE INDEX IF NOT EXISTS "IDX_daa66ad111cdc29c3c14e6dee1"
        ON "users" ("countryCode", "phoneNumber")
        WHERE "phoneNumber" IS NOT NULL`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_226bb9aa7aa8a69991209d58f59"
        ON "users" ("userName")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_97672ac88f789774dd47f7c8be3"
        ON "users" ("email")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_f16ef2287f1aa63faad2f2ba7fe"
        ON "users" ("huaweiUnionId")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_76365ad4b0ed1d58215399d51cd"
        ON "users" ("appleSubject")`,
      `CREATE INDEX IF NOT EXISTS "IDX_08bf8a82c11e16633acaf15ff2"
        ON "banners" ("enabled", "sticky", "createTime")`,
      `CREATE INDEX IF NOT EXISTS "IDX_6e1fc25c9e988cd5688b39f14f"
        ON "conversations" ("userId", "updatedAt")`,
      `CREATE INDEX IF NOT EXISTS "IDX_5f4bdad11e7e208e41b9dc1c67"
        ON "messages" ("conversationId", "id")`,
      `CREATE INDEX IF NOT EXISTS "IDX_83fba0e6be475e32da66a85370"
        ON "usage" ("createdAt")`,
      `CREATE INDEX IF NOT EXISTS "IDX_4eca2a1e72564bfdec6c88dcf3"
        ON "usage" ("provider", "createdAt")`,
      `CREATE INDEX IF NOT EXISTS "IDX_3b5f7176c00a59a347ac3d0eb5"
        ON "usage" ("userId", "createdAt")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_model
        ON "ai_models" ("providerId", "modelId")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_f8b4f9be8cb3a69f1a7d413fda2"
        ON "ai_providers" ("code")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_53c1b84bbd33c9e364fcb3287d3"
        ON "mcp_servers" ("code")`,
      `CREATE INDEX IF NOT EXISTS "IDX_b9fd5ed757e1c54aa1d54902d8"
        ON "sync_changes" ("userId", "id")`,
      `CREATE INDEX IF NOT EXISTS "IDX_b94055fb22c47cb7cdfd13441b"
        ON "sync_changes" ("userId", "entity", "entityId", "id")`,
      `CREATE INDEX IF NOT EXISTS "IDX_2edaed6ec9fd683c40ca29068a"
        ON "ak_verification_codes"
          ("channel", "identifier", "purpose", "createdAt")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_61702e87a2dbef3447848fbbf4a"
        ON "ak_smtp_providers" ("key")`,
      `CREATE UNIQUE INDEX IF NOT EXISTS "UQ_f271fcd03bdc1b58f1c11c32291"
        ON "ak_email_templates" ("key")`,
    ];
    for (const sql of indexes) await queryRunner.query(sql);
  }

  down(_queryRunner: QueryRunner): Promise<void> {
    return Promise.reject(
      new Error('irreversible baseline: refusing to drop legacy tables'),
    );
  }
}
