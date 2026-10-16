import { readFileSync } from 'fs';
import { resolve } from 'path';

const repoRoot = resolve(__dirname, '../../..');
const readRepoFile = (path: string) =>
  readFileSync(resolve(repoRoot, path), 'utf8');

describe('Cloudflare backend deployment contract', () => {
  it('TigrisFS 固定版本并校验各架构 SHA-256', () => {
    const dockerfile = readRepoFile('Dockerfile.cloudflare-backend');

    expect(
      dockerfile.match(/^FROM node:22-bookworm-slim@sha256:/gm),
    ).toHaveLength(3);
    expect(dockerfile).toContain('ARG TIGRISFS_VERSION=1.2.1');
    expect(dockerfile).toMatch(/ARG TIGRISFS_SHA256_AMD64=[a-f0-9]{64}/);
    expect(dockerfile).toMatch(/ARG TIGRISFS_SHA256_ARM64=[a-f0-9]{64}/);
    expect(dockerfile).toContain('sha256sum -c -');
    expect(dockerfile).toContain('--prod --frozen-lockfile --ignore-scripts');
    expect(dockerfile).not.toContain('/releases/latest');
    expect(dockerfile).not.toContain('api.github.com');
  });

  it('生产容器 fail-closed，并用带全局锁的 runner 执行 migration', () => {
    const script = readRepoFile('cloudflare/backend/start-container.sh');

    expect(script).toContain('REQUIRE_PRODUCTION_MODE');
    expect(script).toContain('REQUIRE_PERSISTENT_UPLOADS');
    expect(script).toContain('APP_SECRET_KEY');
    expect(script).toContain('CHANGE_ME*');
    expect(script).toContain('ADMIN_DEFAULT_PASSWORD');
    expect(script).toContain('admin123');
    expect(script).toContain('dist/src/database/migration-main.js');
    expect(script).toContain('--fsync-on-close');
    expect(script).toContain('--memory-limit 128');
    expect(script).toContain('--entry-limit 20000');
    expect(script).toContain('--max-flushers 4');
    expect(script).toContain('--read-ahead-large 8192');
    expect(script).toContain('/proc/$1/stat');
    expect(script).toContain('SUPERVISOR_STOP_TIMEOUT_SECONDS');
    expect(script).toContain('setsid node dist/src/database/migration-main.js');
    expect(script).toContain('setsid node dist/src/main.js');
    expect(script).toContain('trap on_signal TERM INT');
    expect(script).toContain('R2_MOUNT_DIR="${R2_MOUNT_DIR:-/mnt/r2}"');
    expect(script).toContain('fusermount3 -u "$R2_MOUNT_DIR"');
    expect(script).not.toContain('exec node dist/src/main.js');
    expect(script).not.toContain('node_modules/typeorm/cli.js');
  });

  it('生产启动日志不泄露默认管理员密码，并启用 Nest shutdown hooks', () => {
    const userModule = readRepoFile('chatgpt_backend/src/user/user.module.ts');
    const main = readRepoFile('chatgpt_backend/src/main.ts');

    expect(userModule).not.toContain('${username}/${password}');
    expect(userModule).toContain('默认管理员 ${username} 已创建');
    expect(main).toContain('app.enableShutdownHooks()');
  });

  it('apply 与 revert 的正式脚本都走 advisory-lock runner', () => {
    const packageJson = JSON.parse(
      readRepoFile('chatgpt_backend/package.json'),
    ) as { scripts: Record<string, string> };

    expect(packageJson.scripts['migration:run']).toContain('migration-main.ts');
    expect(packageJson.scripts['migration:run:prod']).toContain(
      'migration-main.js',
    );
    expect(packageJson.scripts['migration:revert']).toContain(
      'migration-revert-main.ts',
    );
    expect(packageJson.scripts['migration:revert:prod']).toContain(
      'migration-revert-main.js',
    );
    expect(packageJson.scripts['migration:revert']).not.toContain('typeorm');
  });

  it('Cloudflare 默认要求持久化，同时保持 Sync v2 shadow 关闭', () => {
    const config = JSON.parse(
      readRepoFile('cloudflare/backend/wrangler.jsonc'),
    ) as { vars: Record<string, string> };

    expect(config.vars.REQUIRE_PRODUCTION_MODE).toBe('true');
    expect(config.vars.REQUIRE_PERSISTENT_UPLOADS).toBe('true');
    expect(config.vars.SYNC_V2_SHADOW_ENABLED).toBe('false');
    expect(config.vars.SYNC_V2_SHADOW_USER_IDS).toBe('');
  });

  it('CI 明确断言 compiled migration 结果，并给 supervisor gate 设置超时', () => {
    const workflow = readRepoFile('.github/workflows/ci.yml');

    expect(workflow).toContain("grep -Fq 'Applied 10 migration(s)'");
    expect(workflow).toContain("grep -Fq 'No migrations are pending'");
    expect(workflow).toContain(
      'timeout 60s pnpm backend:cloudflare:supervisor-test',
    );
    expect(workflow).toMatch(
      /- run: pnpm --filter chatgpt_backend exec jest --runInBand\s+env:\s+JWT_SECRET:\s+\S+\s+APP_SECRET_KEY:\s+\S+/,
    );
  });
});
