import { ValidationPipe } from '@nestjs/common';
import nodemailer from 'nodemailer';
import * as crypto from 'node:crypto';
import {
  canonicalIdentifier,
  verificationClientIp,
  validateCodePolicy,
} from '../../../libs/auth-kit/src/verification/verification-contract';
import { SendCodeDto } from '../../../libs/auth-kit/src/verification/dto/send-code.dto';
import { AuthRegisterDto } from '../../../libs/auth-kit/src/verification/dto/register.dto';
import {
  UpdateAuthSettingsDto,
  CodeLogQueryDto,
} from '../../../libs/auth-kit/src/controllers/admin-auth.dto';
import { AdminAuthController } from '../../../libs/auth-kit/src/controllers/admin-auth.controller';
import { AuthController } from '../../../libs/auth-kit/src/controllers/auth.controller';
import { EmailSenderManager } from '../../../libs/auth-kit/src/verification/senders/email-sender.manager';
import { EmailSmtpSender } from '../../../libs/auth-kit/src/verification/senders/email-smtp.sender';
import { safeMailFailure } from '../../../libs/auth-kit/src/verification/senders/mail-delivery.error';
import type { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import type { AuthKitModuleOptions } from '../../../libs/auth-kit/src/auth-kit.module';

const secret = 'synthetic-mail-contract-app-key-0123456789abcdef';
const policy = {
  codeTtlSeconds: 300,
  codeResendIntervalSeconds: 60,
  codeMaxAttempts: 5,
  codeDailyLimitPerIdentifier: 10,
  codeHourlyLimitPerIp: 30,
};
const pipe = new ValidationPipe({
  transform: true,
  whitelist: true,
  forbidNonWhitelisted: true,
});
const transform = (
  metatype: new () => object,
  value: unknown,
  type: 'body' | 'query' = 'body',
) => pipe.transform(value, { metatype, type });
const encrypt = (plain: string) => {
  const key = crypto.createHash('sha256').update(secret).digest(),
    iv = crypto.randomBytes(16),
    c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const bytes = Buffer.concat([c.update(plain), c.final()]);
  return [
    iv.toString('hex'),
    c.getAuthTag().toString('hex'),
    bytes.toString('hex'),
  ].join(':');
};
describe('V1 input/policy/admin/safe mail contract (no real SMTP/network)', () => {
  afterEach(() => jest.restoreAllMocks());
  it('only domain and outer whitespace normalize; local case and aliases preserve', () => {
    expect(canonicalIdentifier('email', '  Name+tag@EXAMPLE.COM  ')).toBe(
      'Name+tag@example.com',
    );
    expect(canonicalIdentifier('email', 'name@example.com')).not.toBe(
      canonicalIdentifier('email', 'Name@example.com'),
    );
    expect(canonicalIdentifier('sms', '+86 13800000000')).toBe(
      '+86 13800000000',
    );
  });
  it.each([
    '',
    'Name <a@example.com>',
    'a@example.com\r\nBcc:x@example.com',
    'a@example.com,b@example.com',
    'not-an-email',
  ])('rejects invalid destination %s', (value) => {
    expect(() => canonicalIdentifier('email', value)).toThrow('格式');
  });
  it('all registered email DTOs inherit the canonical destination', async () => {
    expect(
      await transform(SendCodeDto, {
        channel: 'email',
        identifier: 'Name@EXAMPLE.COM',
        purpose: 'register',
      }),
    ).toMatchObject({ identifier: 'Name@example.com' });
    expect(
      await transform(AuthRegisterDto, {
        channel: 'email',
        identifier: 'Name@EXAMPLE.COM',
        code: '123456',
        password: 'synthetic',
      }),
    ).toMatchObject({ identifier: 'Name@example.com' });
    await expect(
      transform(SendCodeDto, {
        channel: 'email',
        identifier: 'bad',
        purpose: 'register',
      }),
    ).rejects.toThrow('邮箱');
    await expect(
      transform(SendCodeDto, {
        channel: 'email',
        identifier: 'a@example.com',
        purpose: 'register',
        owner: 7,
      }),
    ).rejects.toThrow();
  });
  it('caller XFF is ignored even when it differs from actual connection', () => {
    expect(
      verificationClientIp({
        ip: '127.0.0.1',
        socket: { remoteAddress: '127.0.0.1' },
        headers: { 'x-forwarded-for': '1.2.3.4' },
      } as never),
    ).toBe('127.0.0.1');
    expect(
      verificationClientIp({
        socket: { remoteAddress: '::ffff:127.0.0.2' },
      } as never),
    ).toBe('127.0.0.2');
    expect(
      verificationClientIp({
        socket: {},
        headers: { 'x-forwarded-for': '1.2.3.4' },
      } as never),
    ).toBe('unknown');
  });
  it('actual send-code controller forwards canonical destination and actual IP', async () => {
    const send = jest.fn().mockResolvedValue(undefined),
      c = new AuthController(
        { generateAndSendCode: send } as never,
        {} as never,
        {} as never,
      );
    await c.sendCode(
      {
        channel: 'email',
        identifier: ' Name@EXAMPLE.COM ',
        purpose: 'register',
      },
      {
        ip: '127.0.0.1',
        socket: {},
        headers: { 'x-forwarded-for': '8.8.8.8' },
      } as never,
    );
    expect(send).toHaveBeenCalledWith(
      'email',
      'Name@example.com',
      'register',
      '127.0.0.1',
    );
  });
  it('integer policy limits reject zero/null/fraction/old fields instead of silent save', async () => {
    validateCodePolicy(policy);
    expect(() =>
      validateCodePolicy({ ...policy, codeHourlyLimitPerIp: 0 }),
    ).toThrow('策略');
    for (const patch of [
      { codeTtlSeconds: 0 },
      { codeMaxAttempts: 1.5 },
      { codeDailyLimit: 2 },
      { codeResendSeconds: 60 },
    ])
      await expect(transform(UpdateAuthSettingsDto, patch)).rejects.toThrow();
    expect(
      await transform(UpdateAuthSettingsDto, { codeHourlyLimitPerIp: 30 }),
    ).toMatchObject({ codeHourlyLimitPerIp: 30 });
  });
  it('pagination is strict decimal and bounded, never NaN or an unlimited query', async () => {
    expect(
      await transform(CodeLogQueryDto, { page: '2', pageSize: '100' }, 'query'),
    ).toMatchObject({ page: 2, pageSize: 100 });
    for (const patch of [
      { page: 'NaN' },
      { page: '1e2' },
      { page: '0' },
      { pageSize: '101' },
    ])
      await expect(
        transform(CodeLogQueryDto, patch, 'query'),
      ).rejects.toThrow();
  });
  it('SMTP error mapping never copies raw response/secret into error or cause', () => {
    const e = safeMailFailure(
      Object.assign(Error('SMTP_SECRET_RESPONSE_SENTINEL'), {
        code: 'EAUTH',
        response: 'RAW_SMTP_SENTINEL',
      }),
    );
    expect(e.safeCode).toBe('smtp_authentication_failed');
    expect(e.deliveryStatus).toBe('failed');
    expect(JSON.stringify(e)).not.toMatch(/SECRET_RESPONSE|RAW_SMTP/);
    expect(e).not.toHaveProperty('cause');
    expect(safeMailFailure({ code: 'ETIMEDOUT' }).deliveryStatus).toBe(
      'unknown',
    );
  });
  it('same slot config fingerprint replaces sender while each send owns its transport', async () => {
    const previous = process.env.APP_SECRET_KEY;
    process.env.APP_SECRET_KEY = secret;
    const transport = {
      sendMail: jest.fn().mockResolvedValue({}),
      close: jest.fn(),
    };
    const create = jest
      .spyOn(nodemailer, 'createTransport')
      .mockReturnValue(transport as never);
    try {
      const p = {
        key: 'generic',
        host: 'smtp.synthetic.invalid',
        port: 587,
        secure: false,
        username: 'sender@synthetic.invalid',
        passwordEncrypted: encrypt('synthetic-password-1'),
        fromName: '合成',
        fromAddress: 'sender@synthetic.invalid',
      } as SmtpProvider;
      const m = new EmailSenderManager({
        findOne: jest.fn().mockImplementation(() => Promise.resolve(p)),
      } as never);
      const a = await m.getSender();
      const same = await m.getSender();
      expect(a.sender).toBe(same.sender);
      expect(create).not.toHaveBeenCalled();
      await a.sender.send('to@synthetic.invalid', 'fixture', 'fixture');
      expect(transport.close).toHaveBeenCalledTimes(1);
      p.passwordEncrypted = encrypt('synthetic-password-2');
      const b = await m.getSender();
      expect(b.sender).not.toBe(a.sender);
      await expect(
        a.sender.send('to@synthetic.invalid', 'stale', 'fixture'),
      ).rejects.toThrow();
      await b.sender.send('to@synthetic.invalid', 'fixture', 'fixture');
      expect(create).toHaveBeenCalledTimes(2);
      expect(transport.close).toHaveBeenCalledTimes(2);
      m.invalidate('generic');
      expect(transport.close).toHaveBeenCalledTimes(2);
    } finally {
      if (previous === undefined) delete process.env.APP_SECRET_KEY;
      else process.env.APP_SECRET_KEY = previous;
    }
  });
  it('Nodemailer is called once and exposes only safe failure with bounded SMTP timeouts', async () => {
    const transport = {
      sendMail: jest
        .fn()
        .mockRejectedValue(
          Object.assign(Error('RAW_SECRET'), { code: 'ETIMEDOUT' }),
        ),
      close: jest.fn(),
    };
    const create = jest
      .spyOn(nodemailer, 'createTransport')
      .mockReturnValue(transport as never);
    const s = new EmailSmtpSender({
      host: 'smtp.synthetic.invalid',
      port: 465,
      secure: true,
      user: 'sender@synthetic.invalid',
      pass: 'synthetic-password',
      fromName: '合成',
      fromAddress: 'sender@synthetic.invalid',
    });
    await expect(
      s.send('to@synthetic.invalid', '合成', 'text'),
    ).rejects.toMatchObject({ safeCode: 'smtp_delivery_unknown' });
    expect(transport.sendMail).toHaveBeenCalledTimes(1);
    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        connectionTimeout: 10000,
        greetingTimeout: 10000,
        socketTimeout: 15000,
        logger: false,
        debug: false,
      }),
    );
    s.close();
    expect(transport.close).toHaveBeenCalledTimes(1);
  });
  it('admin code listing uses explicit safe projection with no hash or body', async () => {
    const find = jest.fn().mockResolvedValue([[], 0]);
    const c = new AdminAuthController(
      {} as never,
      { findAndCount: find } as never,
      {} as never,
      {} as never,
      {} as never,
      { appSecretKey: secret } as AuthKitModuleOptions,
    );
    await c.listCodes({});
    const call = find.mock.calls[0] as unknown as [
      { select: Record<string, boolean> },
    ];
    const select = call[0].select;
    expect(select).not.toHaveProperty('codeHash');
    expect(select).not.toHaveProperty('note');
    expect(select.deliveryStatus).toBe(true);
    await expect(c.listCodes({ pageSize: 101 })).rejects.toThrow('参数');
  });
  it('existing provider metadata never returns ciphertext or stored raw test errors', async () => {
    const list = [
      {
        id: 1,
        key: 'generic',
        passwordEncrypted: 'CIPHERTEXT_SECRET',
        lastTestError: 'RAW_SMTP_SECRET',
        host: '',
        username: '',
        fromAddress: '',
      },
    ];
    const c = new AdminAuthController(
      { find: jest.fn().mockResolvedValue(list) } as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      { appSecretKey: secret } as AuthKitModuleOptions,
    );
    const result = await c.listProviders();
    expect(JSON.stringify(result)).not.toMatch(
      /CIPHERTEXT_SECRET|RAW_SMTP_SECRET/,
    );
    expect(result.data[0].configured).toBe(false);
  });
  it('admin explicit test shares sender factory and persists a safe code only', async () => {
    const provider = {
        id: 1,
        key: 'generic',
        configRevision: 7,
      } as SmtpProvider,
      update = jest.fn().mockResolvedValue({ affected: 1 });
    const factory = jest.fn().mockReturnValue({
      send: jest
        .fn()
        .mockRejectedValue(
          Object.assign(Error('RAW_SMTP_SECRET'), { code: 'EAUTH' }),
        ),
    });
    const c = new AdminAuthController(
      { findOne: jest.fn().mockResolvedValue(provider), update } as never,
      {} as never,
      {} as never,
      {} as never,
      { senderFor: factory } as never,
      { appSecretKey: secret } as AuthKitModuleOptions,
    );
    const r = await c.testProvider('generic', { to: 'Target@EXAMPLE.COM' });
    expect(factory).toHaveBeenCalledWith(provider);
    expect(r.data.error).toBe('smtp_authentication_failed');
    expect(update).toHaveBeenCalledWith(
      { id: 1, configRevision: 7 },
      expect.objectContaining({
        lastTestError: 'smtp_authentication_failed',
        lastTestRevision: 7,
      }),
    );
    expect(provider.lastTestError).toBeUndefined();
    expect(r.data.persisted).toBe(true);
    await expect(
      c.testProvider('unknown', { to: 'Target@example.com' }),
    ).rejects.toThrow('服务商');
    await expect(
      c.testProvider('generic', {
        to: 'Target@example.com\r\nBcc:other@example.com',
      }),
    ).rejects.toThrow();
  });
  it('settings preserve third-party values and reject null/out-of-range before DB', async () => {
    const update = jest
      .fn()
      .mockImplementation((x) => Promise.resolve({ ...policy, ...x }));
    const c = new AdminAuthController(
      {} as never,
      {} as never,
      {} as never,
      { update } as never,
      {} as never,
      { appSecretKey: secret } as AuthKitModuleOptions,
    );
    expect(
      (await c.updateSettings({ codeHourlyLimitPerIp: 2 })).data
        .codeHourlyLimitPerIp,
    ).toBe(2);
    expect(update).toHaveBeenCalledWith({ codeHourlyLimitPerIp: 2 });
    await expect(
      c.updateSettings({ codeMaxAttempts: null } as never),
    ).rejects.toThrow('参数');
    await expect(c.updateSettings({ codeTtlSeconds: 1 })).rejects.toThrow(
      '参数',
    );
    expect(update).toHaveBeenCalledTimes(1);
  });
});
