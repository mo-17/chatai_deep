import type { QueryRunner } from 'typeorm';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';

const baselineTables = [
  'users',
  'banners',
  'app_versions',
  'conversations',
  'messages',
  'usage',
  'ai_providers',
  'ai_models',
  'ai_global_config',
  'mcp_servers',
  'sync_changes',
  'ak_verification_codes',
  'ak_smtp_providers',
  'ak_auth_settings',
  'ak_email_templates',
];

describe('CreateCoreBaseline migration', () => {
  it('幂等创建全部旧功能表，并把 sha256 留给后续 migration', async () => {
    const queries: string[] = [];
    const queryRunner = {
      query: jest.fn((sql: string) => {
        queries.push(sql);
        return Promise.resolve();
      }),
    } as unknown as QueryRunner;

    await new CreateCoreBaseline1783990000000().up(queryRunner);

    const sql = queries.join('\n');
    for (const table of baselineTables) {
      expect(sql).toContain(`CREATE TABLE IF NOT EXISTS "${table}"`);
    }
    expect(sql).toContain('"userName" varchar NOT NULL');
    expect(sql).toContain('"emailVerifiedAt" timestamptz');
    expect(sql).toContain('"supportsTool" boolean NOT NULL DEFAULT false');
    expect(sql).toContain(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_model',
    );
    expect(sql).toContain(
      'CREATE UNIQUE INDEX IF NOT EXISTS "UQ_97672ac88f789774dd47f7c8be3"',
    );
    expect(sql).toContain(
      'CREATE UNIQUE INDEX IF NOT EXISTS "UQ_f16ef2287f1aa63faad2f2ba7fe"',
    );
    expect(sql).toContain(
      'CREATE UNIQUE INDEX IF NOT EXISTS "UQ_76365ad4b0ed1d58215399d51cd"',
    );
    expect(sql).toContain('FK_e5663ce0c730b2de83445e2fd19');
    expect(sql).not.toContain('sha256');
    expect(sql).not.toContain('DROP TABLE');
  });

  it('baseline 不允许自动回滚删除旧用户数据', async () => {
    await expect(
      new CreateCoreBaseline1783990000000().down({} as QueryRunner),
    ).rejects.toThrow('irreversible baseline');
  });
});
