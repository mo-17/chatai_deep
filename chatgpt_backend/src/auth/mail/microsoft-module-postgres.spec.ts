import { Global, Module, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getDataSourceToken } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import request from 'supertest';
import * as jwt from 'jsonwebtoken';
import {
  AuthKitModule,
  type AuthKitModuleOptions,
} from '../../../libs/auth-kit/src/auth-kit.module';
import { MICROSOFT_SMTP_TRANSPORT } from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.service';
import { MicrosoftSmtpTransport } from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.transport';
import { User } from '../../user/user.entity';
import { ChatGptUserResolver } from '../chatgpt-user.resolver';
import { TokenAuthenticationService } from '../token-authentication.service';
import {
  pgSuite,
  privateDatabase,
  evidence,
  writeEvidence,
} from './microsoft-private-pg.fixture';
pgSuite(
  'O1 real Nest module/guards and safe HTTP callback contract on private PG',
  () => {
    let db: DataSource,
      app: INestApplication,
      bearer: string,
      options: AuthKitModuleOptions,
      networkCalls: number;
    beforeAll(async () => {
      db = await privateDatabase();
      networkCalls = 0;
      const user = await db.getRepository(User).save({
        userName: 'fixture-admin',
        role: 'admin',
        tokenVersion: 0,
        banned: false,
        password: null,
        avatar: '',
      });
      bearer = jwt.sign(
        {
          userId: user.id,
          userName: user.userName,
          role: 'admin',
          tokenVersion: 0,
        },
        process.env.JWT_SECRET!,
        { algorithm: 'HS256', expiresIn: 600 },
      );
      options = {
        appSecretKey: process.env.APP_SECRET_KEY!,
        microsoftSmtpRedirectUri:
          'https://admin.synthetic.invalid/api/auth/microsoft/callback',
        userResolver: new ChatGptUserResolver(db.getRepository(User)),
        jwtSigner: {} as never,
        accessTokenVerifier: new TokenAuthenticationService(
          db.getRepository(User),
        ),
      };
      @Global()
      @Module({
        providers: [{ provide: getDataSourceToken(), useValue: db }],
        exports: [getDataSourceToken()],
      })
      class SyntheticDatabase {}
      const module = await Test.createTestingModule({
        imports: [
          SyntheticDatabase,
          AuthKitModule.forRootAsync({ useFactory: () => options }),
        ],
      })
        .overrideProvider(MICROSOFT_SMTP_TRANSPORT)
        .useValue(
          new MicrosoftSmtpTransport(async () => {
            await Promise.resolve();
            networkCalls++;
            throw Error('synthetic_no_network_expected');
          }),
        )
        .compile();
      app = module.createNestApplication();
      await app.init();
    });
    afterAll(async () => {
      await app?.close();
      writeEvidence();
      await db?.destroy();
    });
    const http = () =>
      request(app.getHttpServer() as Parameters<typeof request>[0]);
    it('options/provider injection initializes without a circular EmailManager dependency', async () => {
      expect(app).toBeDefined();
      const response = await http()
        .get('/uapi/admin/auth/providers')
        .set('Authorization', 'Bearer ' + bearer);
      expect(response.status).toBe(200);
      expect((response.body as { data: unknown[] }).data).toHaveLength(3);
      expect(networkCalls).toBe(0);
    });
    it('AdminGuard rejects missing bearer before start', async () => {
      expect(
        (
          await http()
            .post('/uapi/admin/auth/providers/generic/microsoft/start')
            .set('Origin', 'https://admin.synthetic.invalid')
        ).status,
      ).toBe(401);
    });
    it('PUT config does not expose secrets or send email; secure start binds original JWT', async () => {
      const config = await http()
        .put('/uapi/admin/auth/providers/generic')
        .set('Authorization', 'Bearer ' + bearer)
        .send({
          authMode: 'microsoft_oauth',
          microsoftClientId: 'f03291c6-5cbc-4c03-a67b-5a18934a4321',
          microsoftClientSecret: 'synthetic-hidden-client-secret',
          fromAddress: 'sender@synthetic.invalid',
        });
      expect(config.status).toBe(200);
      expect(JSON.stringify(config.body)).not.toContain(
        'synthetic-hidden-client-secret',
      );
      expect(
        (config.body as { data: { hasMicrosoftClientSecret: boolean } }).data
          .hasMicrosoftClientSecret,
      ).toBe(true);
      const start = await http()
        .post('/uapi/admin/auth/providers/generic/microsoft/start')
        .set('Authorization', 'Bearer ' + bearer)
        .set('Origin', 'https://admin.synthetic.invalid');
      expect(start.status).toBe(200);
      expect(start.headers['set-cookie'][0]).toMatch(/HttpOnly/);
      expect(start.headers['set-cookie'][0]).toMatch(/Secure/);
      expect(start.headers['set-cookie'][0]).toMatch(/SameSite=Lax/);
      expect(
        (start.body as { data: Record<string, unknown> }).data,
      ).not.toHaveProperty('cookie');
      const url = new URL(
          (start.body as { data: { authorizeUrl: string } }).data.authorizeUrl,
        ),
        state = url.searchParams.get('state')!,
        id = (start.body as { data: { flowId: string } }).data.flowId;
      const callback = await http()
        .post('/uapi/auth/microsoft/callback')
        .type('form')
        .send({ state, code: 'synthetic-received-code' });
      expect(callback.status).toBe(303);
      expect(callback.headers.location).toBe(
        'https://admin.synthetic.invalid/auth/microsoft/result',
      );
      expect(callback.headers['cache-control']).toBe('no-store');
      expect(networkCalls).toBe(0);
      const wrong = await http()
        .post('/uapi/admin/auth/providers/generic/microsoft/complete/' + id)
        .set('Authorization', 'Bearer ' + bearer)
        .set('Origin', 'https://admin.synthetic.invalid')
        .set('Cookie', '__Host-ms-smtp-flow=wrong');
      expect(wrong.status).toBe(503);
      expect(networkCalls).toBe(0);
      evidence.push({
        case: 'actual Nest HTTP admin/JWT/callback',
        networkCalls: 0,
        callback303: true,
        secretProjection: true,
      });
    });
    it('state reads do not exchange OAuth or send email', async () => {
      const response = await http()
        .get('/uapi/admin/auth/providers/generic/microsoft/status')
        .set('Authorization', 'Bearer ' + bearer);
      expect(response.status).toBe(200);
      expect(
        (response.body as { data: Record<string, unknown> }).data,
      ).not.toHaveProperty('refreshToken');
      expect(networkCalls).toBe(0);
    });
    it('wrong origin is rejected, including otherwise valid admin bearer', async () => {
      const response = await http()
        .post('/uapi/admin/auth/providers/generic/microsoft/start')
        .set('Authorization', 'Bearer ' + bearer)
        .set('Origin', 'https://other.synthetic.invalid');
      expect(response.status).toBe(503);
      expect(networkCalls).toBe(0);
    });
  },
);
