import {
  DataSource,
  MoreThan,
  type EntityManager,
  type EntityTarget,
  type ObjectLiteral,
  type FindOneOptions,
  type FindManyOptions,
  type QueryRunner,
} from 'typeorm';
import { readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import { AdminAiProviderService } from '../ai/admin-ai-provider.service';
import { ChatService } from './chat.service';
const suite =
  process.env.R1_SNAPSHOT_PG_TEST === '1' ? describe : describe.skip;
const evidence: unknown[] = [];
jest.setTimeout(12_000);
async function privateDatabase(instance: string): Promise<DataSource> {
  const e = process.env;
  const nonce = e.R1_SNAPSHOT_PG_NONCE;
  const root = `/tmp/chatai-routing-snapshot-${nonce}`;
  if (
    !nonce ||
    !/^[a-f0-9]{12}$/.test(nonce) ||
    e.R1_SNAPSHOT_PG_SOCKET !== `${root}/socket` ||
    e.R1_SNAPSHOT_PG_DATA !== `${root}/data` ||
    e.R1_SNAPSHOT_PG_USER !== `snapshot_${nonce}` ||
    e.R1_SNAPSHOT_PG_DATABASE !== `snapshot_${nonce}`
  )
    throw new Error('private_nonce_required');
  for (const path of [root, `${root}/socket`, `${root}/data`]) {
    if (
      (statSync(path).mode & 0o777) !== 0o700 ||
      realpathSync(path) !== `/private${path}`
    )
      throw new Error('private_directory_required');
  }
  const sentinel = JSON.parse(
    readFileSync(`${root}/socket/fixture-sentinel.json`, 'utf8'),
  ) as { nonce: string };
  if (sentinel.nonce !== nonce) throw new Error('private_sentinel_required');
  const db = new DataSource({
    type: 'postgres',
    host: `${root}/socket`,
    port: Number(e.R1_SNAPSHOT_PG_PORT),
    username: e.R1_SNAPSHOT_PG_USER,
    database: e.R1_SNAPSHOT_PG_DATABASE,
    password: '',
    entities: [AiProvider, AiModel],
    synchronize: false,
    migrationsRun: false,
    logging: false,
    extra: {
      max: 4,
      connectionTimeoutMillis: 3000,
      application_name: `routing-snapshot-${instance}`,
      options: '-c statement_timeout=5000 -c lock_timeout=4000',
    },
  });
  try {
    await db.initialize();
    const [identity] = await db.query<
      Array<{ db: string; user: string; dir: string; listen: string }>
    >(
      "SELECT current_database() db,current_user user,current_setting('data_directory') dir,current_setting('listen_addresses') listen",
    );
    if (
      identity.db !== e.R1_SNAPSHOT_PG_DATABASE ||
      identity.user !== e.R1_SNAPSHOT_PG_USER ||
      realpathSync(identity.dir) !== realpathSync(`${root}/data`) ||
      identity.listen !== ''
    )
      throw new Error('private_identity_required');
    evidence.push({ instance, identityVerified: true, tcp: false });
    return db;
  } catch (error) {
    if (db.isInitialized) await db.destroy();
    throw error;
  }
}

suite(
  'R1 consistent selection on two DataSources in one owned nonce PostgreSQL',
  () => {
    let reader: DataSource;
    let writer: DataSource;
    let chat: ChatService;
    let admin: AdminAiProviderService;
    let send: jest.SpyInstance<
      ReturnType<ChatService['callUpstream']>,
      Parameters<ChatService['callUpstream']>
    >;
    let fetchSpy: jest.SpyInstance;
    let gate:
      | {
          target: EntityTarget<ObjectLiteral>;
          method: string;
          reached: () => void;
          ready: Promise<void>;
          release: () => void;
          wait: Promise<void>;
          fired: boolean;
        }
      | undefined;
    let commitFailure: boolean;
    const runners: QueryRunner[] = [];
    const pending: Array<Promise<unknown>> = [];
    function deferred() {
      let resolve!: () => void;
      const promise = new Promise<void>((done) => {
        resolve = done;
      });
      return { promise, resolve };
    }
    function hold(target: EntityTarget<ObjectLiteral>, method: string) {
      const ready = deferred(),
        wait = deferred();
      gate = {
        target,
        method,
        reached: ready.resolve,
        ready: ready.promise,
        release: wait.resolve,
        wait: wait.promise,
        fired: false,
      };
    }
    async function maybeHold(
      manager: EntityManager,
      target: EntityTarget<ObjectLiteral>,
      method: string,
    ) {
      if (
        !gate ||
        gate.fired ||
        gate.target !== target ||
        gate.method !== method
      )
        return;
      gate.fired = true;
      const runner = manager.queryRunner;
      const isolationRows = runner?.isTransactionActive
        ? ((await runner.query('SHOW transaction_isolation')) as Array<{
            transaction_isolation: string;
          }>)
        : [{ transaction_isolation: 'autocommit' }];
      const row = isolationRows[0];
      evidence.push({
        firstSelectCompleted: true,
        method,
        entity: target === AiProvider ? 'AiProvider' : 'AiModel',
        isolation: row.transaction_isolation,
        transactionActive: runner?.isTransactionActive ?? false,
      });
      gate.reached();
      await gate.wait;
    }
    function instrument(manager: EntityManager) {
      const findOne = manager.findOne.bind(manager) as typeof manager.findOne;
      const find = manager.find.bind(manager) as typeof manager.find;
      manager.findOne = async function <T extends ObjectLiteral>(
        target: EntityTarget<T>,
        options: FindOneOptions<T>,
      ): Promise<T | null> {
        const result = await findOne(target, options);
        await maybeHold(manager, target, 'findOne');
        return result;
      };
      manager.find = async function <T extends ObjectLiteral>(
        target: EntityTarget<T>,
        options?: FindManyOptions<T>,
      ): Promise<T[]> {
        const result = await find(target, options);
        await maybeHold(manager, target, 'find');
        return result;
      };
      return () => {
        manager.findOne = findOne;
        manager.find = find;
      };
    }
    let restoreManager: () => void;
    beforeAll(async () => {
      reader = await privateDatabase('reader');
      await reader.synchronize();
      writer = await privateDatabase('writer');
    });
    afterAll(async () => {
      if (writer?.isInitialized) await writer.destroy();
      if (reader?.isInitialized) await reader.destroy();
      if (process.env.R1_SNAPSHOT_PG_EVIDENCE)
        writeFileSync(
          process.env.R1_SNAPSHOT_PG_EVIDENCE,
          JSON.stringify(
            {
              classification:
                'owned nonce PG, synthetic rows, controlled first-SELECT barrier; commit failure is injected before COMMIT; no model network',
              evidence,
              dataSourcesDestroyed:
                !reader?.isInitialized && !writer?.isInitialized,
            },
            null,
            2,
          ),
        );
    });
    beforeEach(async () => {
      gate = undefined;
      commitFailure = false;
      runners.length = 0;
      pending.length = 0;
      await reader.getRepository(AiModel).delete({ id: MoreThan(0) });
      await reader.getRepository(AiProvider).delete({ id: MoreThan(0) });
      await reader.query(
        `INSERT INTO ai_providers (id,code,"displayName","apiKey","baseUrl",enabled) VALUES (1,'alpha','A','synthetic-a-key','http://synthetic.invalid',true),(2,'beta','B','synthetic-b-key','http://synthetic.invalid',true)`,
      );
      await reader.query(
        `INSERT INTO ai_models (id,"providerId","modelId","displayName",enabled,"isDefault") VALUES (101,1,'same','M',true,true)`,
      );
      restoreManager = instrument(reader.manager);
      const createRunner = reader.createQueryRunner.bind(
        reader,
      ) as typeof reader.createQueryRunner;
      jest.spyOn(reader, 'createQueryRunner').mockImplementation((mode) => {
        const runner = createRunner(mode);
        runners.push(runner);
        instrument(runner.manager);
        const commit = runner.commitTransaction.bind(
          runner,
        ) as typeof runner.commitTransaction;
        runner.commitTransaction = async () => {
          if (commitFailure) {
            evidence.push({ injectedCommitFailure: true });
            throw new Error('synthetic_commit_failure');
          }
          await commit();
        };
        return runner;
      });
      chat = new ChatService(
        {} as never,
        {} as never,
        {} as never,
        reader.getRepository(AiProvider),
        reader.getRepository(AiModel),
        {} as never,
        new ProviderCacheService(),
    { admit: (_id: number, body: unknown) => Promise.resolve({ id: null, body }), finish: async () => {} } as never,
      );
      send = jest
        .spyOn(chat, 'callUpstream')
        .mockImplementation((provider, body) => {
          const released = runners.every(
            (runner) => !runner.isTransactionActive && runner.isReleased,
          );
          evidence.push({
            beforeSyntheticSend: true,
            providerCode: provider.code,
            model: body.model,
            allReaderConnectionsReleased: released,
          });
          expect(released).toBe(true);
          return Promise.resolve({
            choices: [{ message: { content: provider.code } }],
          });
        });
      admin = new AdminAiProviderService(
        reader.getRepository(AiProvider),
        reader.getRepository(AiModel),
        reader,
        chat,
        new ProviderCacheService(),
      );
      fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
        throw new Error('model network forbidden');
      });
    });
    afterEach(async () => {
      gate?.release();
      await Promise.all(pending);
      expect(fetchSpy).not.toHaveBeenCalled();
      restoreManager();
      jest.restoreAllMocks();
      expect(
        runners.every(
          (runner) => runner.isReleased && !runner.isTransactionActive,
        ),
      ).toBe(true);
    });
    function settle(promise: Promise<unknown>) {
      const result = promise.then(
        (value) => ({ value }),
        (error) => ({ error: error as Error & { safeCode?: string } }),
      );
      pending.push(result);
      return result;
    }
    async function firstRead() {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        await Promise.race([
          gate!.ready,
          new Promise<never>((_, reject) => {
            timer = setTimeout(
              () => reject(new Error('first_select_barrier_not_reached')),
              2500,
            );
          }),
        ]);
      } finally {
        if (timer) clearTimeout(timer);
      }
    }
    async function flip() {
      await writer.transaction(async (manager) => {
        await manager.update(AiProvider, 1, { enabled: false });
        await manager.update(AiModel, 101, { enabled: true });
      });
      evidence.push({
        writerCommit:
          'A enabled/M disabled -> A disabled/M enabled; never simultaneous valid pair',
      });
    }
    it('explicit flip cannot combine an old provider with a newly enabled model', async () => {
      await reader.getRepository(AiModel).update(101, { enabled: false });
      hold(AiProvider, 'findOne');
      const result = settle(
        chat.complete(17, {
          providerCode: 'alpha',
          model: 'same',
          messages: [],
        }),
      );
      await firstRead();
      await flip();
      gate!.release();
      expect(await result).toMatchObject({
        error: { safeCode: 'model_unavailable' },
      });
      expect(send).not.toHaveBeenCalled();
    });
    it('legacy move cannot combine old ownership with a newly enabled former provider', async () => {
      await reader.getRepository(AiProvider).update(1, { enabled: false });
      hold(AiModel, 'find');
      const result = settle(chat.complete(17, { model: 'same', messages: [] }));
      await firstRead();
      await writer.transaction(async (manager) => {
        await manager.update(AiModel, 101, { providerId: 2 });
        await manager.update(AiProvider, 1, { enabled: true });
      });
      evidence.push({
        writerCommit:
          'M A/enabled,A disabled -> M B/enabled then A enabled; original A pair never valid',
      });
      gate!.release();
      expect(await result).toMatchObject({
        error: { safeCode: 'model_unavailable' },
      });
      expect(send).not.toHaveBeenCalled();
    });
    it('connection default flip cannot combine an old provider with a newly enabled default', async () => {
      await reader.getRepository(AiModel).update(101, { enabled: false });
      hold(AiProvider, 'findOne');
      const result = settle(admin.testConnection(1));
      await firstRead();
      await flip();
      gate!.release();
      expect(await result).toMatchObject({
        error: { message: '该服务商默认模型无效，请明确设置一个可用默认模型' },
      });
      expect(send).not.toHaveBeenCalled();
    });
    it('an initially valid legacy snapshot may finish after later move/disable/new ambiguity', async () => {
      hold(AiModel, 'find');
      const result = settle(chat.complete(17, { model: 'same', messages: [] }));
      await firstRead();
      await writer.transaction(async (manager) => {
        await manager.update(AiModel, 101, { providerId: 2 });
        await manager.update(AiProvider, 1, { enabled: false });
        await manager.query(
          `INSERT INTO ai_models (id,"providerId","modelId","displayName",enabled) VALUES (102,99,'same','orphan',false)`,
        );
      });
      evidence.push({
        writerCommit:
          'initial snapshot unique valid A; afterwards moved B, disabled A, inserted disabled orphan same model',
        expectation:
          'original valid snapshot may complete; no immediate revocation claim',
      });
      gate!.release();
      expect(await result).toMatchObject({ value: { content: 'alpha' } });
      expect(send).toHaveBeenCalledTimes(1);
      expect(send.mock.calls[0][0].code).toBe('alpha');
    });
    it.each([2, 99])(
      'legacy includes disabled candidate with provider %s when counting ambiguity',
      async (providerId) => {
        await reader.query(
          `INSERT INTO ai_models (id,"providerId","modelId","displayName",enabled) VALUES (102,$1,'same','disabled candidate',false)`,
          [providerId],
        );
        await expect(chat.resolveProvider('same')).rejects.toMatchObject({
          safeCode: 'model_ambiguous',
        });
        expect(send).not.toHaveBeenCalled();
      },
    );
    it('connection default count includes a second disabled default', async () => {
      await reader.query(
        `INSERT INTO ai_models (id,"providerId","modelId","displayName",enabled,"isDefault") VALUES (102,1,'other','disabled',false,true)`,
      );
      await expect(admin.testConnection(1)).rejects.toThrow('默认模型');
      expect(send).not.toHaveBeenCalled();
    });
    it('blank enabled default is rejected before any send', async () => {
      await reader.getRepository(AiModel).update(101, { modelId: ' ' });
      await expect(admin.testConnection(1)).rejects.toThrow('默认模型');
      expect(send).not.toHaveBeenCalled();
    });
    it('legal exact default identifier is preserved and connection is released before send', async () => {
      await reader.getRepository(AiModel).update(101, { modelId: ' exact ' });
      expect((await admin.testConnection(1)).ok).toBe(true);
      expect(send).toHaveBeenCalledTimes(1);
      expect(send.mock.calls[0][1].model).toBe(' exact ');
    });
    it.each(['completion', 'connection'])(
      '%s commit failure rejects without send or retry',
      async (kind) => {
        commitFailure = true;
        const promise =
          kind === 'completion'
            ? chat.complete(17, {
                providerCode: 'alpha',
                model: 'same',
                messages: [],
              })
            : admin.testConnection(1);
        await expect(promise).rejects.toThrow('synthetic_commit_failure');
        expect(send).not.toHaveBeenCalled();
      },
    );
  },
);
