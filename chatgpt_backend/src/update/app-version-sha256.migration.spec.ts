import type { QueryRunner } from 'typeorm';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';

describe('App version SHA-256 migration', () => {
  it('adds a nullable legacy-compatible column and can roll it back', async () => {
    const queries: string[] = [];
    const queryRunner = {
      query: jest.fn((sql: string) => {
        queries.push(sql);
        return Promise.resolve();
      }),
    } as unknown as QueryRunner;
    const migration = new AddAppVersionSha2561784020000000();

    await migration.up(queryRunner);
    await migration.down(queryRunner);

    expect(queries).toEqual([
      'ALTER TABLE "app_versions" ADD COLUMN IF NOT EXISTS "sha256" varchar(64)',
      'ALTER TABLE "app_versions" DROP COLUMN IF EXISTS "sha256"',
    ]);
  });
});
