import {
  BadRequestException,
  Logger,
  ValidationPipe,
  type INestApplication,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import request from 'supertest';
import { AdminAuthController } from '../../../libs/auth-kit/src/controllers/admin-auth.controller';
import { AUTH_KIT_OPTIONS } from '../../../libs/auth-kit/src/auth-kit.tokens';
import { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import { VerificationCode } from '../../../libs/auth-kit/src/verification/entities/verification-code.entity';
import { EmailTemplate } from '../../../libs/auth-kit/src/verification/entities/email-template.entity';
import { AuthSettingsService } from '../../../libs/auth-kit/src/settings/auth-settings.service';
import { EmailSenderManager } from '../../../libs/auth-kit/src/verification/senders/email-sender.manager';
import { MicrosoftSmtpService } from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.service';
import { AllExceptionsFilter } from '../../common/all-exceptions.filter';

const guidance =
  'Microsoft Client ID 必须填写微软应用的“应用程序（客户端）ID”（UUID）';
const clientId = '310e8e4b-b083-45da-9e1d-28d2c79f1ea1';
/** 真实路由/guard/生产pipe/filter；仅仓储与OAuth依赖合成，不连接DB/微软/SMTP。 */
describe('Outlook configuration input contract and safe HTTP feedback', () => {
  let app: INestApplication,
    logs: jest.SpyInstance,
    provider: Record<string, unknown>;
  let readError: Error | undefined;
  const write = jest.fn(),
    mutate = jest.fn(),
    mail = jest.fn(),
    activate = jest.fn();
  const manager = {
    findOne: () => Promise.resolve({ ...provider }),
    update: (_entity: unknown, _where: unknown, fields: object) => {
      write(fields);
      Object.assign(provider, fields);
      return Promise.resolve();
    },
    findOneByOrFail: () => Promise.resolve({ ...provider }),
  };
  beforeAll(async () => {
    logs = jest.spyOn(Logger.prototype, 'error').mockImplementation(() => {});
    const module = await Test.createTestingModule({
      controllers: [AdminAuthController],
      providers: [
        {
          provide: AUTH_KIT_OPTIONS,
          useValue: {
            appSecretKey: 'synthetic-input-fixture',
            accessTokenVerifier: {
              verify: (token: string) =>
                Promise.resolve(
                  token === 'synthetic-input-admin'
                    ? {
                        userId: 7,
                        role: 'admin',
                        tokenVersion: 0,
                        expiresAt: Date.now() + 60000,
                      }
                    : null,
                ),
            },
          },
        },
        {
          provide: getRepositoryToken(SmtpProvider),
          useValue: {
            find: () =>
              readError
                ? Promise.reject(readError)
                : Promise.resolve([{ ...provider }]),
          },
        },
        { provide: getRepositoryToken(VerificationCode), useValue: {} },
        { provide: getRepositoryToken(EmailTemplate), useValue: {} },
        { provide: AuthSettingsService, useValue: {} },
        {
          provide: EmailSenderManager,
          useValue: { send: mail, activate, invalidate: jest.fn() },
        },
        {
          provide: MicrosoftSmtpService,
          useValue: {
            mutate: (fn: (m: typeof manager) => Promise<unknown>) => {
              mutate();
              return fn(manager);
            },
            disconnectWith: () => Promise.resolve(),
            invalidate: jest.fn(),
            cipher: { seal: () => 'synthetic-encrypted-only' },
          },
        },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    await app.init();
  });
  beforeEach(() => {
    readError = undefined;
    logs.mockClear();
    write.mockClear();
    mutate.mockClear();
    mail.mockClear();
    activate.mockClear();
    provider = {
      id: 1,
      key: 'generic',
      displayName: 'Synthetic Outlook',
      authMode: 'microsoft_oauth',
      configRevision: 4,
      microsoftClientId: clientId,
      microsoftClientSecretEncrypted: 'synthetic-existing-encrypted',
      passwordEncrypted: '',
      host: 'smtp-mail.outlook.com',
      port: 587,
      secure: false,
      username: 'fixture@example.test',
      fromName: '',
      fromAddress: 'fixture@example.test',
      enabled: true,
    };
  });
  afterAll(async () => {
    await app?.close();
    logs.mockRestore();
  });
  const http = () =>
    request(app.getHttpServer() as Parameters<typeof request>[0]);
  const body = {
    authMode: 'microsoft_oauth',
    displayName: 'Synthetic Outlook',
    fromAddress: 'fixture@example.test',
    microsoftClientId: clientId,
  };
  it.each(['', 'synthetic-secret-code-token-invalid-id'])(
    'rejects malformed Client ID before mutation with actionable finite message: %s',
    async (id) => {
      const before = { ...provider };
      const r = await http()
        .put('/uapi/admin/auth/providers/generic?token=synthetic-token')
        .set('Authorization', 'Bearer synthetic-input-admin')
        .send({ ...body, microsoftClientId: id });
      expect(r.status).toBe(400);
      expect(r.body).toEqual({
        code: -1,
        message: guidance,
        errorCode: 'AUTH_MICROSOFT_CLIENT_ID_INVALID',
      });
      expect(provider).toEqual(before);
      expect(mutate).not.toHaveBeenCalled();
      expect(write).not.toHaveBeenCalled();
      expect(JSON.stringify(logs.mock.calls)).toContain(
        'authentication_request_failed',
      );
      expect(JSON.stringify(logs.mock.calls)).not.toMatch(
        /synthetic-token|synthetic-secret|\?/,
      );
      expect(mail).not.toHaveBeenCalled();
      expect(activate).not.toHaveBeenCalled();
    },
  );
  it('valid explicit OAuth PUT preserves blank secret, returns safe projection and never sends or activates', async () => {
    const r = await http()
      .put('/uapi/admin/auth/providers/generic')
      .set('Authorization', 'Bearer synthetic-input-admin')
      .send(body);
    expect(r.status).toBe(200);
    expect((r.body as { code: number }).code).toBe(0);
    expect(provider.microsoftClientSecretEncrypted).toBe(
      'synthetic-existing-encrypted',
    );
    expect(provider.configRevision).toBe(5);
    expect(provider.enabled).toBe(false);
    expect(mutate).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(r.body)).not.toContain(
      'synthetic-existing-encrypted',
    );
    expect(mail).not.toHaveBeenCalled();
    expect(activate).not.toHaveBeenCalled();
  });
  it.each(['mixed', 'prefix', 'suffix', 'unknown'] as const)(
    'unknown validation payload %s stays generic in response and logs',
    async (kind) => {
      const secret = 'synthetic-secret SELECT synthetic-code synthetic-token';
      readError = new BadRequestException({
        message:
          kind === 'mixed'
            ? [guidance, secret]
            : kind === 'prefix'
              ? [secret + guidance]
              : kind === 'suffix'
                ? [guidance + secret]
                : [secret],
        target: secret,
        value: secret,
      });
      const r = await http()
        .get('/uapi/admin/auth/providers?code=synthetic-code')
        .set('Authorization', 'Bearer synthetic-input-admin');
      expect(r.status).toBe(400);
      expect(r.body).toEqual({ code: -1, message: '认证请求失败' });
      expect(JSON.stringify([r.body, logs.mock.calls])).not.toMatch(
        /synthetic-secret|synthetic-token|synthetic-code|SELECT|target|value/,
      );
      expect(mutate).not.toHaveBeenCalled();
      expect(mail).not.toHaveBeenCalled();
    },
  );
});
