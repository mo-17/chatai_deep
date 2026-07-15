import { join } from 'path';

/**
 * 统一上传文件的写入目录与静态服务目录。
 * 未配置时保留历史上的 `<cwd>/uploads`，避免影响现有部署。
 */
export function resolveUploadsDir(
  configuredDir = process.env.UPLOADS_DIR,
  cwd = process.cwd(),
): string {
  const normalized = configuredDir?.trim();
  return normalized ? join(normalized) : join(cwd, 'uploads');
}
