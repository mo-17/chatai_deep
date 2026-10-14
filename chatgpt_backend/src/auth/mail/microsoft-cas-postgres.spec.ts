import { DataSource } from 'typeorm';
import { createCipheriv, createHash, randomBytes } from 'node:crypto';
import { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import { AdminAuthController } from '../../../libs/auth-kit/src/controllers/admin-auth.controller';
import { EmailSenderManager } from '../../../libs/auth-kit/src/verification/senders/email-sender.manager';
import type { AuthKitModuleOptions } from '../../../libs/auth-kit/src/auth-kit.module';
import {
  pgSuite,
  privateDatabase,
  deferred,
  evidence,
  writeEvidence,
} from './microsoft-private-pg.fixture';
const secret = 'synthetic-mail-contract-app-key-0123456789abcdef';
function encrypted(value: string) {
  const iv = randomBytes(16),
    c = createCipheriv(
      'aes-256-gcm',
      createHash('sha256').update(secret).digest(),
      iv,
    );
  const data = Buffer.concat([c.update(value), c.final()]);
  return [
    iv.toString('hex'),
    c.getAuthTag().toString('hex'),
    data.toString('hex'),
  ].join(':');
}
pgSuite(
  'O1 CAS old SMTP entity cannot overwrite concurrent configuration/activation',
  () => {
    let db: DataSource,
      manager: EmailSenderManager,
      controller: AdminAuthController;
    beforeAll(async () => {
      db = await privateDatabase();
      manager = new EmailSenderManager(db.getRepository(SmtpProvider));
      controller = new AdminAuthController(
        db.getRepository(SmtpProvider),
        {} as never,
        {} as never,
        {} as never,
        manager,
        { appSecretKey: secret } as AuthKitModuleOptions,
      );
    });
    beforeEach(async () => {
      await db
        .getRepository(SmtpProvider)
        .createQueryBuilder()
        .delete()
        .execute();
      for (const key of ['generic', 'aliyun_dm', 'tencent_ses'] as const)
        await db.getRepository(SmtpProvider).save({
          key,
          displayName: key,
          authMode: 'password',
          configRevision: 0,
          host: 'smtp.synthetic.invalid',
          port: 587,
          secure: false,
          username: 'sender@synthetic.invalid',
          passwordEncrypted: encrypted('synthetic-before'),
          fromName: 'fixture',
          fromAddress: 'sender@synthetic.invalid',
          enabled: key === 'generic',
        });
    });
    afterEach(() => {
      jest.restoreAllMocks();
      manager.invalidate();
    });
    afterAll(async () => {
      writeEvidence();
      await db?.destroy();
    });
    it('late test result cannot revert a changed host/password or contaminate new revision', async () => {
      const entered = deferred(),
        release = deferred();
      jest.spyOn(manager, 'senderFor').mockReturnValue({
        send: async () => {
          entered.resolve();
          await release.promise;
        },
      });
      const test = controller.testProvider('generic', {
        to: 'to@synthetic.invalid',
      });
      await entered.promise;
      await controller.updateProvider('generic', {
        host: 'smtp.new-synthetic.invalid',
        password: 'synthetic-after',
      });
      const updated = await db
        .getRepository(SmtpProvider)
        .findOneByOrFail({ key: 'generic' });
      release.resolve();
      await test;
      const row = await db
        .getRepository(SmtpProvider)
        .findOneByOrFail({ key: 'generic' });
      evidence.push({
        case: 'CAS changed host/password',
        hostPreserved: row.host === updated.host,
        passwordPreserved: row.passwordEncrypted === updated.passwordEncrypted,
        revision: row.configRevision,
        oldTestIgnored: row.lastTestStatus === null,
      });
      expect(row.host).toBe(updated.host);
      expect(row.passwordEncrypted).toBe(updated.passwordEncrypted);
      expect(row.configRevision).toBe(1);
      expect(row.lastTestStatus).toBeNull();
    });
    it('late test result cannot reactivate old slot after activation changes', async () => {
      const entered = deferred(),
        release = deferred();
      jest.spyOn(manager, 'senderFor').mockReturnValue({
        send: async () => {
          entered.resolve();
          await release.promise;
        },
      });
      const test = controller.testProvider('generic', {
        to: 'to@synthetic.invalid',
      });
      await entered.promise;
      await controller.activateProvider('aliyun_dm');
      release.resolve();
      await test;
      const rows = await db
        .getRepository(SmtpProvider)
        .find({ where: { enabled: true } });
      evidence.push({
        case: 'CAS slot switch',
        enabled: rows.map((r) => r.key),
      });
      expect(rows.map((r) => r.key)).toEqual(['aliyun_dm']);
    });
    it('config update and activate serialize without carrying stale enabled fields', async () => {
      const qr = db.createQueryRunner();
      await qr.connect();
      await qr.startTransaction();
      await qr.query('SELECT pg_advisory_xact_lock(178409,1)');
      const update = controller.updateProvider('generic', {
          fromName: 'changed',
        }),
        activate = controller.activateProvider('tencent_ses');
      await qr.commitTransaction();
      await qr.release();
      await Promise.all([update, activate]);
      const rows = await db.getRepository(SmtpProvider).find();
      expect(rows.filter((r) => r.enabled).map((r) => r.key)).toEqual([
        'tencent_ses',
      ]);
      expect(rows.find((r) => r.key === 'generic')!.fromName).toBe('changed');
      evidence.push({
        case: 'CAS concurrent update/activate',
        uniqueEnabled: true,
      });
    });
  },
);
