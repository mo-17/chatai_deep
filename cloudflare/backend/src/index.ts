import { Container, getRandom } from "@cloudflare/containers";

const INSTANCE_COUNT = 1;

declare global {
  namespace Cloudflare {
    interface Env {
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
      R2_BUCKET_NAME: string;
    }
  }
}

function defined(values: Record<string, string | undefined>) {
  return Object.fromEntries(
    Object.entries(values).filter((entry): entry is [string, string] => {
      return typeof entry[1] === "string" && entry[1].length > 0;
    }),
  );
}

export class BackendContainer extends Container<Cloudflare.Env> {
  defaultPort = 3000;
  sleepAfter = "10m";

  // Worker secrets/vars are not inherited by Containers automatically.
  // Keep this allow-list explicit so an unrelated binding is never leaked.
  envVars = defined({
    PORT: "3000",
    NODE_ENV: this.env.NODE_ENV ?? "production",
    CORS_ORIGINS: this.env.CORS_ORIGINS,
    LOG_LEVEL: this.env.LOG_LEVEL,
    DB_HOST: this.env.DB_HOST,
    DB_PORT: this.env.DB_PORT,
    DB_USER: this.env.DB_USER,
    DB_PASSWORD: this.env.DB_PASSWORD,
    DB_NAME: this.env.DB_NAME,
    DB_LOGGING: this.env.DB_LOGGING,
    DB_POOL_MAX: this.env.DB_POOL_MAX,
    DB_SSL: this.env.DB_SSL,
    DB_SSL_REJECT_UNAUTHORIZED: this.env.DB_SSL_REJECT_UNAUTHORIZED,
    DB_SYNCHRONIZE: this.env.DB_SYNCHRONIZE,
    JWT_SECRET: this.env.JWT_SECRET,
    APP_SECRET_KEY: this.env.APP_SECRET_KEY,
    ADMIN_DEFAULT_USERNAME: this.env.ADMIN_DEFAULT_USERNAME,
    ADMIN_DEFAULT_PASSWORD: this.env.ADMIN_DEFAULT_PASSWORD,
    BCRYPT_ROUNDS: this.env.BCRYPT_ROUNDS,
    OPENAI_API_KEY: this.env.OPENAI_API_KEY,
    OPENAI_BASE_URL: this.env.OPENAI_BASE_URL,
    DEEPSEEK_API_KEY: this.env.DEEPSEEK_API_KEY,
    DEEPSEEK_BASE_URL: this.env.DEEPSEEK_BASE_URL,
    MCP_SERVERS: this.env.MCP_SERVERS,
    AWS_ACCESS_KEY_ID: this.env.AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY: this.env.AWS_SECRET_ACCESS_KEY,
    R2_ACCOUNT_ID: this.env.R2_ACCOUNT_ID,
    R2_BUCKET_NAME: this.env.R2_BUCKET_NAME,
  });
}

export default {
  async fetch(request: Request, env: Cloudflare.Env): Promise<Response> {
    const instance = await getRandom(env.BACKEND, INSTANCE_COUNT);
    return instance.fetch(request);
  },
};
