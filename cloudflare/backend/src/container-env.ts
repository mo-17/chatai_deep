export interface ContainerBindings {
  NODE_ENV?: string;
  CORS_ORIGINS?: string;
  LOG_LEVEL?: string;
  DB_HOST?: string;
  DB_PORT?: string;
  DB_USER?: string;
  DB_PASSWORD?: string;
  DB_NAME?: string;
  DB_LOGGING?: string;
  DB_POOL_MAX?: string;
  DB_SSL?: string;
  DB_SSL_REJECT_UNAUTHORIZED?: string;
  DB_SYNCHRONIZE?: string;
  MIGRATION_LOCK_TIMEOUT_MS?: string;
  JWT_SECRET?: string;
  APP_SECRET_KEY?: string;
  ADMIN_DEFAULT_USERNAME?: string;
  ADMIN_DEFAULT_PASSWORD?: string;
  BCRYPT_ROUNDS?: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
  DEEPSEEK_API_KEY?: string;
  DEEPSEEK_BASE_URL?: string;
  MCP_SERVERS?: string;
  AWS_ACCESS_KEY_ID?: string;
  AWS_SECRET_ACCESS_KEY?: string;
  R2_ACCOUNT_ID?: string;
  R2_BUCKET_NAME?: string;
  REQUIRE_PRODUCTION_MODE?: string;
  REQUIRE_PERSISTENT_UPLOADS?: string;
  SYNC_V2_SHADOW_ENABLED?: string;
  SYNC_V2_SHADOW_USER_IDS?: string;
}

function defined(values: Record<string, string | undefined>) {
  return Object.fromEntries(
    Object.entries(values).filter((entry): entry is [string, string] => {
      return typeof entry[1] === 'string' && entry[1].length > 0;
    }),
  );
}

/** 只把显式 allow-list 中的配置传入 Container，避免泄露其他 binding。 */
export function buildContainerEnv(bindings: ContainerBindings) {
  return defined({
    PORT: '3000',
    NODE_ENV: bindings.NODE_ENV ?? 'production',
    CORS_ORIGINS: bindings.CORS_ORIGINS,
    LOG_LEVEL: bindings.LOG_LEVEL,
    DB_HOST: bindings.DB_HOST,
    DB_PORT: bindings.DB_PORT,
    DB_USER: bindings.DB_USER,
    DB_PASSWORD: bindings.DB_PASSWORD,
    DB_NAME: bindings.DB_NAME,
    DB_LOGGING: bindings.DB_LOGGING,
    DB_POOL_MAX: bindings.DB_POOL_MAX,
    DB_SSL: bindings.DB_SSL,
    DB_SSL_REJECT_UNAUTHORIZED: bindings.DB_SSL_REJECT_UNAUTHORIZED,
    DB_SYNCHRONIZE: bindings.DB_SYNCHRONIZE,
    MIGRATION_LOCK_TIMEOUT_MS: bindings.MIGRATION_LOCK_TIMEOUT_MS,
    JWT_SECRET: bindings.JWT_SECRET,
    APP_SECRET_KEY: bindings.APP_SECRET_KEY,
    ADMIN_DEFAULT_USERNAME: bindings.ADMIN_DEFAULT_USERNAME,
    ADMIN_DEFAULT_PASSWORD: bindings.ADMIN_DEFAULT_PASSWORD,
    BCRYPT_ROUNDS: bindings.BCRYPT_ROUNDS,
    OPENAI_API_KEY: bindings.OPENAI_API_KEY,
    OPENAI_BASE_URL: bindings.OPENAI_BASE_URL,
    DEEPSEEK_API_KEY: bindings.DEEPSEEK_API_KEY,
    DEEPSEEK_BASE_URL: bindings.DEEPSEEK_BASE_URL,
    MCP_SERVERS: bindings.MCP_SERVERS,
    AWS_ACCESS_KEY_ID: bindings.AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY: bindings.AWS_SECRET_ACCESS_KEY,
    R2_ACCOUNT_ID: bindings.R2_ACCOUNT_ID,
    R2_BUCKET_NAME: bindings.R2_BUCKET_NAME,
    REQUIRE_PRODUCTION_MODE: bindings.REQUIRE_PRODUCTION_MODE,
    REQUIRE_PERSISTENT_UPLOADS: bindings.REQUIRE_PERSISTENT_UPLOADS,
    SYNC_V2_SHADOW_ENABLED: bindings.SYNC_V2_SHADOW_ENABLED,
    SYNC_V2_SHADOW_USER_IDS: bindings.SYNC_V2_SHADOW_USER_IDS,
  });
}
