import { EmailTemplate } from '../../libs/auth-kit/src/verification/entities/email-template.entity';
import { AuthSettings } from '../../libs/auth-kit/src/verification/entities/auth-settings.entity';
import { SmtpProvider } from '../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import { VerificationCode } from '../../libs/auth-kit/src/verification/entities/verification-code.entity';
import { buildPostgresOptions } from './postgres-options';

describe('buildPostgresOptions', () => {
  const reader =
    (values: Record<string, string | undefined>) => (key: string) =>
      values[key];

  it('CLI 与 Nest 共享 TLS、连接池和完整 entity 集合', () => {
    const options = buildPostgresOptions(
      reader({
        DB_HOST: 'db.example.com',
        DB_PORT: '6543',
        DB_USER: 'app',
        DB_PASSWORD: 'secret',
        DB_NAME: 'prod',
        DB_SSL: 'true',
        DB_SSL_REJECT_UNAUTHORIZED: 'false',
        DB_POOL_MAX: '7',
        DB_LOGGING: 'true',
      }),
      '/workspace/dist/src',
    );

    expect(options).toMatchObject({
      type: 'postgres',
      host: 'db.example.com',
      port: 6543,
      username: 'app',
      password: 'secret',
      database: 'prod',
      ssl: { rejectUnauthorized: false },
      extra: { max: 7 },
      logging: ['error', 'warn'],
    });
    expect(options.entities).toEqual([
      '/workspace/dist/src/**/*.entity{.ts,.js}',
      VerificationCode,
      SmtpProvider,
      AuthSettings,
      EmailTemplate,
    ]);
  });

  it('无效数字回退安全默认值，未显式启用 TLS 时保持 false', () => {
    const options = buildPostgresOptions(
      reader({ DB_PORT: 'invalid', DB_POOL_MAX: '0' }),
      '/workspace/src',
    );

    expect(options).toMatchObject({
      host: 'localhost',
      port: 5432,
      username: 'huangzhibin',
      password: '',
      database: 'chatgpt_flutter',
      ssl: false,
      extra: { max: 10 },
      logging: ['error'],
    });
  });
});
