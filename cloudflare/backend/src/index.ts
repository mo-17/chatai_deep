import { Container, getRandom } from "@cloudflare/containers";
import { buildContainerEnv } from "./container-env";

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
      R2_BUCKET_NAME: string;
      REQUIRE_PRODUCTION_MODE?: string;
      REQUIRE_PERSISTENT_UPLOADS?: string;
      SYNC_V2_SHADOW_ENABLED?: string;
      SYNC_V2_SHADOW_USER_IDS?: string;
    }
  }
}

export class BackendContainer extends Container<Cloudflare.Env> {
  defaultPort = 3000;
  sleepAfter = "10m";

  // Worker secrets/vars are not inherited by Containers automatically.
  // Keep this allow-list explicit so an unrelated binding is never leaked.
  envVars = buildContainerEnv(this.env);
}

export default {
  async fetch(request: Request, env: Cloudflare.Env): Promise<Response> {
    const instance = await getRandom(env.BACKEND, INSTANCE_COUNT);
    return instance.fetch(request);
  },
};
