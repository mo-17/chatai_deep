import { join } from 'path';
import { resolveUploadsDir } from './uploads-path';

describe('resolveUploadsDir', () => {
  it('未配置时保持历史 cwd/uploads 行为', () => {
    expect(resolveUploadsDir(undefined, '/srv/backend')).toBe(
      join('/srv/backend', 'uploads'),
    );
  });

  it('显式 UPLOADS_DIR 同时供静态服务与写入端使用', () => {
    expect(resolveUploadsDir('/mnt/r2/uploads', '/srv/backend')).toBe(
      join('/mnt/r2/uploads'),
    );
  });

  it('空白配置不覆盖历史目录', () => {
    expect(resolveUploadsDir('   ', '/srv/backend')).toBe(
      join('/srv/backend', 'uploads'),
    );
  });
});
