import { DataSource, type EntityManager } from 'typeorm';
import { ServiceUnavailableException } from '@nestjs/common';

/** 自有惰性2连接池，仅复用已注入连接/TLS和已加载实体；不继承初始化插件/迁移/日志。 */
export class MicrosoftSmtpStore {
  private readonly pool: DataSource;
  private initializing?: Promise<void>;
  private closing = false;
  private closePromise?: Promise<void>;
  private readonly active = new Set<Promise<unknown>>();
  constructor(source: DataSource) {
    if (source.options.type !== 'postgres')
      throw Error('microsoft_pg_required');
    const s = source.options;
    this.pool = new DataSource({
      type: 'postgres',
      host: s.host,
      port: s.port,
      username: s.username,
      password: s.password,
      database: s.database,
      schema: s.schema,
      ssl: s.ssl,
      entities: source.entityMetadatas
        .map((m) => m.target)
        .filter(
          (t): t is new (...args: never[]) => object => typeof t === 'function',
        ),
      synchronize: false,
      dropSchema: false,
      migrationsRun: false,
      migrations: [],
      subscribers: [],
      cache: false,
      installExtensions: false,
      logging: false,
      extra: {
        max: 2,
        connectionTimeoutMillis: 3000,
        application_name: 'microsoft-smtp-auth',
      },
    });
  }
  private async ready(): Promise<void> {
    if (this.closing)
      throw new ServiceUnavailableException('邮件授权服务已停止');
    if (this.initializing) {
      await this.initializing;
    } else if (!this.pool.isInitialized) {
      const init = this.pool.initialize().then(() => {});
      this.initializing = init;
      try {
        await init;
      } finally {
        if (this.initializing === init) this.initializing = undefined;
      }
    }
    if (this.closing)
      throw new ServiceUnavailableException('邮件授权服务已停止');
  }
  transaction<T>(action: (manager: EntityManager) => Promise<T>): Promise<T> {
    const operation = (async () => {
      try {
        await this.ready();
        return await this.pool.transaction(async (manager) => {
          await manager.query("SET LOCAL lock_timeout='3000ms'");
          await manager.query("SET LOCAL statement_timeout='5000ms'");
          await manager.query('SELECT pg_advisory_xact_lock(178409,1)');
          return action(manager);
        });
      } catch (e) {
        // 禁止原QueryFailedError SQL/绑定密文进入全局异常日志。
        if (
          e instanceof ServiceUnavailableException ||
          (e instanceof Error && e.name === 'MicrosoftSmtpError')
        )
          throw e;
        throw new ServiceUnavailableException('邮件授权存储暂不可用');
      }
    })();
    this.active.add(operation);
    void operation.then(
      () => this.active.delete(operation),
      () => this.active.delete(operation),
    );
    return operation;
  }
  close(): Promise<void> {
    if (this.closePromise) return this.closePromise;
    this.closing = true;
    this.closePromise = (async () => {
      if (this.initializing) await this.initializing.catch(() => {});
      await Promise.allSettled([...this.active]);
      if (this.pool.isInitialized) await this.pool.destroy();
    })();
    return this.closePromise;
  }
}
