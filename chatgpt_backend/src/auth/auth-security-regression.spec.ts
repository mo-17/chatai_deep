import { GUARDS_METADATA } from '@nestjs/common/constants';
import { generateKeyPairSync } from 'crypto';
import * as bcrypt from 'bcryptjs';
import * as jwt from 'jsonwebtoken';
import { UserService } from '../user/user.service';
import { AdminAuthController as AuthKitAdminAuthController } from '../../libs/auth-kit/src/controllers/admin-auth.controller';
import { ThirdPartyController } from '../../libs/auth-kit/src/controllers/third-party.controller';
import { AppleService } from '../../libs/auth-kit/src/third-party/apple/apple.service';
import { VerificationService } from '../../libs/auth-kit/src/verification/verification.service';
import { SmsMockSender } from '../../libs/auth-kit/src/verification/senders/sms-mock.sender';
import type { AuthKitModuleOptions } from '../../libs/auth-kit/src/auth-kit.module';
import type { VerificationCode } from '../../libs/auth-kit/src/verification/entities/verification-code.entity';
import { AuthKitAdminGuard } from '../../libs/auth-kit/src/guards/auth-kit-auth.guard';
import { AuthController } from '../../libs/auth-kit/src/controllers/auth.controller';
import { TokenAuthenticationService } from './token-authentication.service';
import { JWT_SECRET } from './jwt.const';
import { ChatGptUserResolver } from './chatgpt-user.resolver';
import { AdminUserService } from '../admin/admin-user.service';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';

const insecureAppSecret = 'CHANGE_ME_CHANGE_ME_CHANGE_ME_32B';

describe('authentication security regressions', () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('legacy password reset no longer issues a live code', async () => {
    const repo = {
      findOne: jest.fn().mockResolvedValue({ id: 7, userName: 'victim' }),
    };
    const service = new UserService(repo as never);

    await expect(service.requestPasswordReset('victim')).rejects.toMatchObject({
      status: 410,
    });
  });

  it('auth-kit administrative controller has an authentication guard', () => {
    const guards =
      (Reflect.getMetadata(GUARDS_METADATA, AuthKitAdminAuthController) as
        | Array<{ name?: string }>
        | undefined) ?? [];

    expect(guards.map((guard) => guard.name)).toContain('AuthKitAdminGuard');
  });

  it('auth-kit administrative guard accepts only a currently authorized admin', async () => {
    const request = { headers: { authorization: 'Bearer signed-token' } };
    const context = {
      switchToHttp: () => ({ getRequest: () => request }),
    } as never;
    const verifier = { verify: jest.fn() };
    const options = {
      accessTokenVerifier: verifier,
    } as unknown as AuthKitModuleOptions;
    const guard = new AuthKitAdminGuard(options);

    verifier.verify.mockResolvedValueOnce({
      userId: 1,
      userName: 'former-admin',
      role: 'user',
    });
    await expect(guard.canActivate(context)).rejects.toThrow('管理员');

    verifier.verify.mockResolvedValueOnce({
      userId: 2,
      userName: 'current-admin',
      role: 'admin',
    });
    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(request).toHaveProperty(
      'user',
      expect.objectContaining({ userId: 2, role: 'admin' }),
    );
  });

  it('known default APP_SECRET_KEY is rejected before bind tickets are used', () => {
    const options = {
      userResolver: {},
      jwtSigner: {},
      appSecretKey: insecureAppSecret,
    } as AuthKitModuleOptions;

    expect(
      () =>
        new ThirdPartyController(
          { verifyCode: jest.fn() } as never,
          {} as never,
          {} as never,
          options,
        ),
    ).toThrow('APP_SECRET_KEY');
  });

  it('bind tickets cannot be replayed through the wrong provider route', async () => {
    const strongSecret = 'a'.repeat(48);
    const wrongProviderTicket = jwt.sign(
      {
        sub: '42',
        purpose: 'third_party_bind',
        provider: 'apple',
      },
      strongSecret,
      {
        algorithm: 'HS256',
        audience: 'auth-kit:third-party-bind',
        issuer: 'auth-kit',
        jwtid: 'wrong-provider-ticket',
      },
    );
    const resolver = {
      findByEmail: jest.fn().mockResolvedValue(null),
      bindIdentifier: jest.fn(),
      bindPendingThirdPartyIdentifier: jest.fn(),
      markEmailVerified: jest.fn(),
      findById: jest.fn().mockResolvedValue({
        id: 42,
        userName: 'victim',
        email: null,
        emailVerifiedAt: null,
        countryCode: null,
        phoneNumber: null,
        phoneVerifiedAt: null,
        huaweiUnionId: 'huawei-id',
        huaweiOpenId: 'open-id',
        appleSubject: null,
        appleEmailRelay: null,
        password: null,
        role: 'user',
        banned: false,
      }),
    };
    const options = {
      userResolver: resolver,
      jwtSigner: { sign: jest.fn().mockReturnValue('token') },
      appSecretKey: strongSecret,
    } as unknown as AuthKitModuleOptions;
    const controller = new ThirdPartyController(
      { verifyCode: jest.fn().mockResolvedValue(true) } as never,
      {} as never,
      {} as never,
      options,
    );

    await expect(
      controller.huaweiBindAndLogin({
        bindTicket: wrongProviderTicket,
        channel: 'email',
        identifier: 'attacker@example.com',
        code: '123456',
      }),
    ).rejects.toThrow('bindTicket');
    expect(resolver.bindIdentifier).not.toHaveBeenCalled();
    expect(resolver.bindPendingThirdPartyIdentifier).not.toHaveBeenCalled();
  });

  it('a pending third-party binding is atomically consumed once', async () => {
    const pendingUser = {
      id: 42,
      userName: 'pending',
      email: null,
      emailVerifiedAt: null,
      countryCode: null,
      phoneNumber: null,
      phoneVerifiedAt: null,
      huaweiUnionId: 'huawei-union-id',
      huaweiOpenId: 'huawei-open-id',
      appleSubject: null,
      appleEmailRelay: null,
      password: null,
      avatar: null,
      role: 'user',
      banned: false,
      tokenVersion: 0,
    };
    const txRepo = {
      findOne: jest
        .fn()
        .mockImplementation(({ where }: { where: Record<string, unknown> }) => {
          if ('id' in where) return Promise.resolve(pendingUser);
          return Promise.resolve(null);
        }),
      save: jest.fn().mockResolvedValue(pendingUser),
    };
    const transaction = jest.fn(
      async (action: (manager: unknown) => Promise<unknown>) =>
        action({ getRepository: () => txRepo }),
    );
    const resolver = new ChatGptUserResolver({
      manager: { transaction },
    } as never);

    await expect(
      resolver.bindPendingThirdPartyIdentifier(42, 'huawei', {
        channel: 'email',
        email: 'bound@example.com',
      }),
    ).resolves.toMatchObject({ email: 'bound@example.com' });
    expect(txRepo.findOne).toHaveBeenCalledWith(
      expect.objectContaining({ lock: { mode: 'pessimistic_write' } }),
    );

    await expect(
      resolver.bindPendingThirdPartyIdentifier(42, 'huawei', {
        channel: 'email',
        email: 'replay@example.com',
      }),
    ).rejects.toThrow('已使用');
    expect(txRepo.save).toHaveBeenCalledTimes(1);
  });

  it('SMS placeholder never logs or accepts a plaintext OTP', async () => {
    const sender = new SmsMockSender();

    await expect(sender.send('+8613800000000', '123456')).rejects.toThrow(
      '短信验证码服务尚未配置',
    );
  });

  it('Apple token must target an explicitly configured audience', async () => {
    const previousBundleId = process.env.APPLE_BUNDLE_ID;
    const previousServiceId = process.env.APPLE_SERVICE_ID;
    process.env.APPLE_BUNDLE_ID = 'com.example.expected';
    delete process.env.APPLE_SERVICE_ID;
    try {
      const { privateKey, publicKey } = generateKeyPairSync('rsa', {
        modulusLength: 2048,
      });
      const service = new AppleService();
      jest
        .spyOn(service as never, 'fetchPublicKey' as never)
        .mockResolvedValue(
          publicKey.export({ type: 'spki', format: 'pem' }).toString() as never,
        );
      const wrongAudience = jwt.sign({ sub: 'apple-user' }, privateKey, {
        algorithm: 'RS256',
        issuer: 'https://appleid.apple.com',
        audience: 'com.attacker.other-app',
        expiresIn: '5m',
        keyid: 'test-key',
      });

      await expect(service.verifyIdentityToken(wrongAudience)).rejects.toThrow(
        'audience',
      );

      const validAudience = jwt.sign({ sub: 'apple-user' }, privateKey, {
        algorithm: 'RS256',
        issuer: 'https://appleid.apple.com',
        audience: 'com.example.expected',
        expiresIn: '5m',
        keyid: 'test-key',
      });
      await expect(
        service.verifyIdentityToken(validAudience),
      ).resolves.toMatchObject({ subject: 'apple-user' });
    } finally {
      if (previousBundleId === undefined) delete process.env.APPLE_BUNDLE_ID;
      else process.env.APPLE_BUNDLE_ID = previousBundleId;
      if (previousServiceId === undefined) delete process.env.APPLE_SERVICE_ID;
      else process.env.APPLE_SERVICE_ID = previousServiceId;
    }
  });

  it('JWT authorization follows current user state and token version', async () => {
    const token = jwt.sign(
      {
        userId: 7,
        userName: 'snapshot-name',
        role: 'admin',
        tokenVersion: 3,
      },
      JWT_SECRET,
      { algorithm: 'HS256', expiresIn: '5m' },
    );
    const repo = { findOne: jest.fn() };
    const verifier = new TokenAuthenticationService(repo as never);

    repo.findOne.mockResolvedValueOnce({
      id: 7,
      userName: 'current-name',
      role: 'user',
      banned: false,
      tokenVersion: 3,
    });
    await expect(verifier.verify(token)).resolves.toEqual({
      userId: 7,
      userName: 'current-name',
      role: 'user',
    });

    repo.findOne.mockResolvedValueOnce({
      id: 7,
      userName: 'current-name',
      role: 'user',
      banned: true,
      tokenVersion: 3,
    });
    await expect(verifier.verify(token)).resolves.toBeNull();

    repo.findOne.mockResolvedValueOnce(null);
    await expect(verifier.verify(token)).resolves.toBeNull();

    repo.findOne.mockResolvedValueOnce({
      id: 7,
      userName: 'current-name',
      role: 'user',
      banned: false,
      tokenVersion: 4,
    });
    await expect(verifier.verify(token)).resolves.toBeNull();
  });

  it('role and ban changes increment tokenVersion while avatar-only edits do not', async () => {
    const user = {
      id: 7,
      userName: 'user',
      password: 'hash',
      role: 'admin',
      banned: false,
      avatar: 'old',
      tokenVersion: 2,
    };
    const repo = {
      findOne: jest.fn().mockResolvedValue(user),
      save: jest.fn().mockImplementation((value) => Promise.resolve(value)),
    };
    const service = new AdminUserService(repo as never);

    await service.edit(7, { avatar: 'new' });
    expect(user.tokenVersion).toBe(2);

    await service.edit(7, { role: 'user' });
    expect(user.tokenVersion).toBe(3);

    await service.edit(7, { banned: true });
    expect(user.tokenVersion).toBe(4);
  });

  it('the supported reset flow consumes a code and rotates the password state', async () => {
    const verifyCode = jest.fn().mockResolvedValue(true);
    let capturedPasswordHash: string | undefined;
    const updatePassword = jest.fn(
      (_userId: number, newPasswordHash: string): Promise<void> => {
        capturedPasswordHash = newPasswordHash;
        return Promise.resolve();
      },
    );
    const userResolver = {
      findByEmail: jest.fn().mockResolvedValue({ id: 9 }),
      updatePassword,
    };
    const controller = new AuthController(
      { verifyCode } as never,
      {} as never,
      {
        userResolver,
        jwtSigner: {},
        accessTokenVerifier: {},
        appSecretKey: 'b'.repeat(48),
      } as unknown as AuthKitModuleOptions,
    );

    await expect(
      controller.resetPassword({
        channel: 'email',
        identifier: 'user@example.com',
        code: '123456',
        newPassword: 'new-password-123',
      }),
    ).resolves.toEqual({ code: 0, data: null });
    expect(verifyCode).toHaveBeenCalledWith(
      'email',
      'user@example.com',
      'reset_password',
      '123456',
    );
    expect(capturedPasswordHash).toEqual(expect.any(String));
    if (!capturedPasswordHash)
      throw new Error('password hash was not captured');
    await expect(
      bcrypt.compare('new-password-123', capturedPasswordHash),
    ).resolves.toBe(true);
  });

  it('verification code lookup and consumption run under a row lock', async () => {
    const record = {
      id: 1,
      channel: 'email',
      identifier: 'user@example.com',
      purpose: 'login',
      codeHash: await bcrypt.hash('123456', 4),
      expiresAt: new Date(Date.now() + 60_000),
      consumedAt: null,
      attempts: 0,
      ipAddress: null,
      note: null,
      createdAt: new Date(),
    } as VerificationCode;
    const txRepo = {
      findOne: jest.fn().mockResolvedValue(record),
      save: jest.fn().mockImplementation((value) => Promise.resolve(value)),
    };
    const transaction = jest.fn((action: (manager: unknown) => unknown) =>
      action({ getRepository: () => txRepo }),
    );
    const codeRepo = {
      manager: { transaction },
      findOne: jest.fn().mockResolvedValue(record),
      save: jest.fn().mockImplementation((value) => Promise.resolve(value)),
    };
    const service = new VerificationService(
      codeRepo as never,
      { get: jest.fn().mockResolvedValue({ codeMaxAttempts: 5 }) } as never,
      {} as never,
    );

    await expect(
      service.verifyCode('email', 'user@example.com', 'login', '123456'),
    ).resolves.toBe(true);
    expect(transaction).toHaveBeenCalledTimes(1);
    expect(txRepo.findOne).toHaveBeenCalledWith(
      expect.objectContaining({ lock: { mode: 'pessimistic_write' } }),
    );
  });

  it('failed verification attempts persist before the public error is thrown', async () => {
    const record = {
      codeHash: await bcrypt.hash('123456', 4),
      expiresAt: new Date(Date.now() + 60_000),
      consumedAt: null,
      attempts: 0,
    } as VerificationCode;
    const txRepo = {
      findOne: jest.fn().mockResolvedValue(record),
      save: jest.fn().mockImplementation((value) => Promise.resolve(value)),
    };
    const transaction = jest.fn(
      async (action: (manager: unknown) => Promise<unknown>) =>
        action({ getRepository: () => txRepo }),
    );
    const service = new VerificationService(
      { manager: { transaction } } as never,
      { get: jest.fn().mockResolvedValue({ codeMaxAttempts: 5 }) } as never,
      {} as never,
    );

    await expect(
      service.verifyCode('email', 'user@example.com', 'login', '000000'),
    ).rejects.toThrow('剩余 4 次');
    expect(record.attempts).toBe(1);
    expect(txRepo.save).toHaveBeenCalledTimes(1);
  });

  it('tokenVersion production migration is reversible', async () => {
    const query = jest.fn().mockResolvedValue(undefined);
    const migration = new AddUserTokenVersion1784030000000();

    await migration.up({ query } as never);
    expect(query).toHaveBeenLastCalledWith(
      expect.stringContaining('ADD COLUMN IF NOT EXISTS "tokenVersion"'),
    );

    await migration.down({ query } as never);
    expect(query).toHaveBeenLastCalledWith(
      expect.stringContaining('DROP COLUMN IF EXISTS "tokenVersion"'),
    );
  });
});
