import type { DataSourceOptions } from 'typeorm';
import {
  AuthSettings,
  EmailTemplate,
  SmtpProvider,
  VerificationCode,
} from '../../libs/auth-kit/src';

import {
  MicrosoftSmtpConnection,
  MicrosoftSmtpFlow,
} from '../../libs/auth-kit/src/microsoft/microsoft-smtp.entities';

type PostgresOptions = Extract<DataSourceOptions, { type: 'postgres' }>;
export type EnvironmentReader = (key: string) => string | undefined;

function positiveInteger(
  value: string | undefined,
  fallback: number,
  max = Number.MAX_SAFE_INTEGER,
): number {
  if (!value || !/^[1-9]\d*$/.test(value)) return fallback;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed <= max ? parsed : fallback;
}

export function buildPostgresOptions(
  read: EnvironmentReader,
  sourceRoot: string,
): PostgresOptions {
  return {
    type: 'postgres',
    host: read('DB_HOST') ?? 'localhost',
    port: positiveInteger(read('DB_PORT'), 5432, 65_535),
    username: read('DB_USER') ?? 'huangzhibin',
    password: read('DB_PASSWORD') ?? '',
    database: read('DB_NAME') ?? 'chatgpt_flutter',
    entities: [
      `${sourceRoot}/**/*.entity{.ts,.js}`,
      VerificationCode,
      SmtpProvider,
      AuthSettings,
      EmailTemplate,
      MicrosoftSmtpConnection,
      MicrosoftSmtpFlow,
    ],
    // SQL错误含bind密文，认证/OAuth存储不记录原SQL或参数。
    logging: false,
    ssl:
      read('DB_SSL') === 'true'
        ? {
            rejectUnauthorized: read('DB_SSL_REJECT_UNAUTHORIZED') !== 'false',
          }
        : false,
    extra: { max: positiveInteger(read('DB_POOL_MAX'), 10) },
  };
}
