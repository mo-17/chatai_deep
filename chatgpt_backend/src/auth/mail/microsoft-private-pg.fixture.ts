import { DataSource } from 'typeorm';
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { User } from '../../user/user.entity';
import { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import {
  MicrosoftSmtpConnection,
  MicrosoftSmtpFlow,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.entities';
import { runMigrationsWithAdvisoryLock } from '../../database/migration-runner';
import { CreateCoreBaseline1783990000000 } from '../../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../../migrations/1784020000000-AddAppVersionSha256';
import { AddUserTokenVersion1784030000000 } from '../../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudDispatchPermit1784050000000 } from '../../migrations/1784050000000-AddCloudDispatchPermit';
import { AddCloudSchedulerGate1784060000000 } from '../../migrations/1784060000000-AddCloudSchedulerGate';
import { AddVerificationDeliveryState1784070000000 } from '../../migrations/1784070000000-AddVerificationDeliveryState';
import { AddMicrosoftSmtpOAuth1784080000000 } from '../../migrations/1784080000000-AddMicrosoftSmtpOAuth';

export const pgSuite =
  process.env.MAIL_O1_PG_TEST === '1' ? describe : describe.skip;
export const evidence: unknown[] = [];
export async function privateDatabase(): Promise<DataSource> {
  const e = process.env,
    n = e.MAIL_PG_NONCE,
    s = e.MAIL_PG_SOCKET;
  if (
    !n ||
    !/^[a-f0-9]{12}$/.test(n) ||
    !s?.startsWith('/tmp/chatai-mail-O1-') ||
    !e.MAIL_PG_DATA_DIRECTORY?.startsWith('/tmp/chatai-mail-O1-') ||
    e.MAIL_PG_DATABASE !== 'chatai_mail_test_' + n ||
    e.MAIL_PG_USER !== 'mail_' + n
  )
    throw Error('private_nonce_required');
  if ((statSync(s).mode & 0o777) !== 0o700)
    throw Error('private_socket_required');
  const sentinel = JSON.parse(
    readFileSync(s + '/fixture-sentinel.json', 'utf8'),
  ) as { nonce: string };
  if (sentinel.nonce !== n) throw Error('private_sentinel_required');
  const db = new DataSource({
    type: 'postgres',
    host: s,
    port: Number(e.MAIL_PG_PORT),
    username: e.MAIL_PG_USER,
    database: e.MAIL_PG_DATABASE,
    password: '',
    synchronize: false,
    migrationsRun: false,
    logging: false,
    entities: [User, SmtpProvider, MicrosoftSmtpConnection, MicrosoftSmtpFlow],
    migrations: [
      CreateCoreBaseline1783990000000,
      CreateSyncV21784000000000,
      AddAppVersionSha2561784020000000,
      AddUserTokenVersion1784030000000,
      CreateCloudWorkflows1784040000000,
      AddCloudDispatchPermit1784050000000,
      AddCloudSchedulerGate1784060000000,
      AddVerificationDeliveryState1784070000000,
      AddMicrosoftSmtpOAuth1784080000000,
    ],
    extra: {
      max: 6,
      connectionTimeoutMillis: 3000,
      application_name: 'mail-O1-test',
    },
  });
  await db.initialize();
  const [identity] = await db.query<
    Array<{ db: string; user: string; dir: string; listen: string }>
  >(
    "SELECT current_database() db,current_user user,current_setting('data_directory') dir,current_setting('listen_addresses') listen",
  );
  if (
    identity.db !== e.MAIL_PG_DATABASE ||
    identity.user !== e.MAIL_PG_USER ||
    identity.dir !== e.MAIL_PG_DATA_DIRECTORY ||
    identity.listen !== ''
  )
    throw Error('private_identity_required');
  evidence.push({ identityVerified: true, tcp: false });
  const result = await runMigrationsWithAdvisoryLock(db);
  if (result.length !== 9) throw Error('nine_migrations_required');
  return db;
}
export function writeEvidence(): void {
  if (process.env.MAIL_PG_EVIDENCE)
    writeFileSync(
      process.env.MAIL_PG_EVIDENCE,
      JSON.stringify(
        {
          classification: 'nonce real PG, synthetic OAuth/SMTP only',
          evidence,
        },
        null,
        2,
      ),
    );
}
export function deferred<T = void>() {
  let resolve!: (v?: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = (v?: T) => r(v as T);
  });
  return { promise, resolve };
}
