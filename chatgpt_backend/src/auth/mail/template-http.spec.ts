import { Logger, ValidationPipe, type INestApplication } from '@nestjs/common';
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
import { AllExceptionsFilter } from '../../common/all-exceptions.filter';
describe('A1 actual Nest routes/filter + synthetic repositories; no real DB/mail', () => {
  let app: INestApplication;
  const saved = new Map<
    string,
    { key: string; subject: string; body: string }
  >();
  const mail = jest.fn();
  const logs = jest
    .spyOn(Logger.prototype, 'error')
    .mockImplementation(() => {});
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [AdminAuthController],
      providers: [
        {
          provide: AUTH_KIT_OPTIONS,
          useValue: {
            appSecretKey: 'synthetic-a1-http-only',
            accessTokenVerifier: {
              verify: (token: string) =>
                Promise.resolve(
                  token === 'synthetic-a1-admin'
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
        { provide: getRepositoryToken(SmtpProvider), useValue: {} },
        { provide: getRepositoryToken(VerificationCode), useValue: {} },
        {
          provide: getRepositoryToken(EmailTemplate),
          useValue: {
            upsert: (v: { key: string; subject: string; body: string }) => {
              saved.set(v.key, v);
              return Promise.resolve();
            },
            findOneOrFail: ({ where }: { where: { key: string } }) =>
              Promise.resolve(saved.get(where.key)),
            find: () => Promise.resolve([...saved.values()]),
          },
        },
        {
          provide: AuthSettingsService,
          useValue: { update: (body: object) => Promise.resolve(body) },
        },
        { provide: EmailSenderManager, useValue: { send: mail } },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    await app.init();
  });
  afterAll(async () => {
    await app?.close();
    logs.mockRestore();
  });
  const http = () =>
    request(app.getHttpServer() as Parameters<typeof request>[0]);
  it('actual PUT key/subject/body then GET returns usable contract without mail', async () => {
    const put = await http()
      .put('/uapi/admin/auth/templates/code-login')
      .set('Authorization', 'Bearer synthetic-a1-admin')
      .send({
        subject: '{{purposeLabel}}验证码',
        body: '<p>{{code}} {{ttlMinutes}}</p>',
      });
    expect(put.status).toBe(200);
    expect((put.body as { data: unknown }).data).toEqual({
      key: 'code-login',
      subject: '{{purposeLabel}}验证码',
      body: '<p>{{code}} {{ttlMinutes}}</p>',
    });
    const get = await http()
      .get('/uapi/admin/auth/templates')
      .set('Authorization', 'Bearer synthetic-a1-admin');
    expect((get.body as { data: unknown }).data).toEqual([
      (put.body as { data: unknown }).data,
    ]);
    expect(mail).not.toHaveBeenCalled();
  });
  it('actual settings PUT accepts current policy field names', async () => {
    const r = await http()
      .put('/uapi/admin/auth/settings')
      .set('Authorization', 'Bearer synthetic-a1-admin')
      .send({
        codeDailyLimitPerIdentifier: 12,
        codeResendIntervalSeconds: 90,
        codeHourlyLimitPerIp: 20,
      });
    expect(r.status).toBe(200);
    expect((r.body as { data: unknown }).data).toEqual({
      codeDailyLimitPerIdentifier: 12,
      codeResendIntervalSeconds: 90,
      codeHourlyLimitPerIp: 20,
    });
    expect(mail).not.toHaveBeenCalled();
  });
  it('unauthenticated PUT is denied and unsafe body/query never reach response or logs', async () => {
    const before = saved.get('code-login');
    const noauth = await http()
      .put('/uapi/admin/auth/templates/code-login')
      .send({ subject: 'synthetic-secret', body: 'synthetic-code' });
    expect(noauth.status).toBe(401);
    expect(saved.get('code-login')).toBe(before);
    const invalid = await http()
      .put('/uapi/admin/auth/templates/code-login?token=synthetic-token')
      .set('Authorization', 'Bearer synthetic-a1-admin')
      .send({
        subject: 'SELECT synthetic-secret\r\nBcc:synthetic',
        body: '{{secret}}',
      });
    expect(invalid.status).toBe(400);
    expect(JSON.stringify(invalid.body)).not.toMatch(
      /SELECT|synthetic-secret|synthetic-token|\{\{secret/,
    );
    expect(JSON.stringify(logs.mock.calls)).not.toMatch(
      /SELECT|synthetic-secret|synthetic-token/,
    );
    expect(saved.get('code-login')).toBe(before);
    expect(mail).not.toHaveBeenCalled();
  });
});
