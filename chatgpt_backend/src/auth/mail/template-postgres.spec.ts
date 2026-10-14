import { DataSource } from 'typeorm';
import {
  privateDatabase,
  pgSuite,
  evidence,
  writeEvidence,
  deferred,
} from './microsoft-private-pg.fixture';
import { VerificationService } from '../../../libs/auth-kit/src/verification/verification.service';
import { VerificationCode } from '../../../libs/auth-kit/src/verification/entities/verification-code.entity';
import { EmailTemplate } from '../../../libs/auth-kit/src/verification/entities/email-template.entity';
import { AuthSettings } from '../../../libs/auth-kit/src/verification/entities/auth-settings.entity';
import { AuthSettingsService } from '../../../libs/auth-kit/src/settings/auth-settings.service';
import type { EmailSenderManager } from '../../../libs/auth-kit/src/verification/senders/email-sender.manager';
pgSuite('A1 real nonce PG template snapshot / synthetic single mail', () => {
  let db: DataSource;
  beforeAll(async () => {
    const base = await privateDatabase();
    const options = base.options;
    await base.destroy();
    db = await new DataSource({
      ...options,
      entities: [VerificationCode, EmailTemplate, AuthSettings],
      migrations: [],
    }).initialize();
  });
  afterAll(async () => {
    if (db?.isInitialized) await db.destroy();
    writeEvidence();
  });
  it('four purposes select controlled key, persist sent and never send on save/read', async () => {
    const messages: Array<{ to: string; subject: string; body: string }> = [];
    const send = jest.fn((to: string, subject: string, body: string) => {
      messages.push({ to, subject, body });
      return Promise.resolve();
    });
    const service = new VerificationService(
      db.getRepository(VerificationCode),
      new AuthSettingsService(db.getRepository(AuthSettings)),
      { send } as unknown as EmailSenderManager,
    );
    for (const purpose of [
      'login',
      'register',
      'bind',
      'reset_password',
    ] as const) {
      await db.getRepository(EmailTemplate).upsert(
        {
          key: 'code-' + purpose,
          subject: purpose + ' {{code}}',
          body: '<p>{{purposeLabel}} {{code}} {{ttlMinutes}}</p>',
        },
        ['key'],
      );
      await db.getRepository(EmailTemplate).find();
      expect(send).toHaveBeenCalledTimes(messages.length);
      await service.generateAndSendCode(
        'email',
        purpose + '@synthetic.invalid',
        purpose,
        'synthetic-' + purpose,
      );
      const last = messages.at(-1)!;
      expect(last.subject).toMatch(new RegExp('^' + purpose + ' \\d{6}$'));
      expect(last.body).toMatch(/\d{6} 5/);
      const record = await db
        .getRepository(VerificationCode)
        .findOneByOrFail({ identifier: purpose + '@synthetic.invalid' });
      expect(record.deliveryStatus).toBe('sent');
    }
    expect(send).toHaveBeenCalledTimes(4);
    evidence.push({
      case: 'four template purpose selections',
      mails: 4,
      realSMTP: false,
    });
  });
  it('template edit during SMTP keeps reserved snapshot; next identifier sees edit, no lock during mail', async () => {
    const entered = deferred(),
      release = deferred();
    const messages: string[] = [];
    const send = jest.fn(async (_to: string, subject: string) => {
      messages.push(subject);
      if (messages.length === 1) {
        entered.resolve();
        await release.promise;
      }
    });
    const service = new VerificationService(
      db.getRepository(VerificationCode),
      new AuthSettingsService(db.getRepository(AuthSettings)),
      { send } as unknown as EmailSenderManager,
    );
    await db.getRepository(EmailTemplate).upsert(
      {
        key: 'code-login',
        subject: 'before {{code}}',
        body: '<p>{{code}}</p>',
      },
      ['key'],
    );
    const sending = service.generateAndSendCode(
      'email',
      'snapshot1@synthetic.invalid',
      'login',
      'synthetic-snapshot-1',
    );
    await entered.promise;
    await db.getRepository(EmailTemplate).upsert(
      {
        key: 'code-login',
        subject: 'after {{code}}',
        body: '<p>{{code}}</p>',
      },
      ['key'],
    );
    release.resolve();
    await sending;
    await service.generateAndSendCode(
      'email',
      'snapshot2@synthetic.invalid',
      'login',
      'synthetic-snapshot-2',
    );
    expect(messages[0]).toMatch(/^before /);
    expect(messages[1]).toMatch(/^after /);
    expect(send).toHaveBeenCalledTimes(2);
    evidence.push({
      case: 'template edit while SMTP paused',
      snapshotPreserved: true,
      sends: 2,
    });
  });
});
