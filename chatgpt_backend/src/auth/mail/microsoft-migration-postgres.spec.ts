import { DataSource } from 'typeorm';
import { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import { revertLastMigrationWithAdvisoryLock } from '../../database/migration-runner';
import {
  pgSuite,
  privateDatabase,
  evidence,
  writeEvidence,
} from './microsoft-private-pg.fixture';
pgSuite(
  'O1 additive migration rollback contract on own nonce PostgreSQL',
  () => {
    let db: DataSource;
    beforeAll(async () => {
      db = await privateDatabase();
    });
    afterAll(async () => {
      writeEvidence();
      await db?.destroy();
    });
    it('migration 9 down disables OAuth and clears old password before removing OAuth columns/tables', async () => {
      await db.getRepository(SmtpProvider).save({
        key: 'generic',
        displayName: 'fixture',
        authMode: 'microsoft_oauth',
        host: 'smtp-mail.outlook.com',
        port: 587,
        secure: false,
        username: 'sender@synthetic.invalid',
        fromName: 'fixture',
        fromAddress: 'sender@synthetic.invalid',
        passwordEncrypted: 'synthetic-previous-password',
        enabled: true,
      });
      await revertLastMigrationWithAdvisoryLock(db);
      const [p] = await db.query<
        Array<{ enabled: boolean; passwordEncrypted: string }>
      >(
        'SELECT enabled,"passwordEncrypted" FROM ak_smtp_providers WHERE key=$1',
        ['generic'],
      );
      expect(p.enabled).toBe(false);
      expect(p.passwordEncrypted).toBe('');
      const [count] = await db.query<Array<{ count: number }>>(
        'SELECT count(*)::int count FROM migrations',
      );
      expect(count.count).toBe(8);
      const [tables] = await db.query<
        Array<{ connection: string | null; flow: string | null }>
      >(
        "SELECT to_regclass('ak_microsoft_smtp_connections') connection,to_regclass('ak_microsoft_smtp_flows') flow",
      );
      expect(tables.connection).toBeNull();
      expect(tables.flow).toBeNull();
      evidence.push({
        case: 'migration 9 down',
        disabled: true,
        passwordCleared: true,
        migrationsRemaining: 8,
      });
    });
  },
);
