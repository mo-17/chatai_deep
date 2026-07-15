# Cloudflare 后端部署

本项目的 NestJS 后端部署到 **Cloudflare Containers**，入口 Worker 只负责路由。不要把后端直接改成普通 Worker：现有 stdio MCP、SMTP、Node.js 文件 API 和 PostgreSQL 驱动都需要完整 Node.js 运行时。

## 已接入的结构

- `cloudflare/backend/src/index.ts`：Worker → Container 转发，并把允许的 vars/secrets 显式传入容器。
- `cloudflare/backend/wrangler.jsonc`：Container、Durable Object 和实例规格配置。
- `Dockerfile.cloudflare-backend`：可复现的 pnpm workspace 多阶段构建；TigrisFS 固定版本并校验 SHA-256。
- `cloudflare/backend/start-container.sh`：挂载并监督 R2，串行执行 migrations，随后启动 NestJS。

当前配置使用 1 个 `basic` 实例并在空闲 10 分钟后休眠。Cloudflare 目前尚无内置无状态自动扩缩；增大实例数前应确认数据库连接池和登录/流式请求的负载行为。

## 前置条件

1. Cloudflare Workers Paid 计划（Containers 不支持 Free 计划）。
2. 本机 Docker 正在运行。
3. Cloudflare 账户已有 Workers 子域名。
4. 一个允许公网连接的 PostgreSQL 数据库；生产环境不要依赖容器内数据库。
5. 一个 R2 bucket（默认名 `chatai-deep-uploads`），用于持久化 `/uploads`。

生产环境必须保持 `NODE_ENV=production` 与 `DB_SYNCHRONIZE=false`。Cloudflare 配置还会
设置 `REQUIRE_PRODUCTION_MODE=true` 与 `REQUIRE_PERSISTENT_UPLOADS=true`，任一生产约束
不满足时容器都会在服务流量前退出。入口通过 PostgreSQL advisory lock 串行执行已提交的
TypeORM migrations，成功后才启动 NestJS；migration 失败时不会用不完整 schema 对外服务。
`APP_SECRET_KEY`、`JWT_SECRET` 与非默认 `ADMIN_DEFAULT_PASSWORD` 也会在 migration 前校验，
避免空库先执行不可逆 baseline 后才因缺密钥退出。不得再通过临时打开
`DB_SYNCHRONIZE` 创建生产表。

## 首次配置

编辑 `cloudflare/backend/wrangler.jsonc`：

- 把 `R2_ACCOUNT_ID` 改成 Cloudflare Account ID。
- 按实际后台域名设置 `CORS_ORIGINS`（也可以用 secret）。
- 如已创建不同名称的 bucket，修改 `R2_BUCKET_NAME`。

必须先完成 R2 Account ID 与下面两项 S3 secret，再部署当前配置。Cloudflare 路径不会再
静默降级到临时磁盘；凭据不完整会产生可见的启动失败，避免头像在实例休眠后悄悄丢失。

登录并创建 R2 bucket：

```bash
pnpm exec wrangler login
pnpm exec wrangler r2 bucket create chatai-deep-uploads
```

在 R2 控制台创建仅对该 bucket 有 Object Read & Write 权限的 S3 API Token，记录 Access Key ID 和 Secret Access Key。

## 写入 secrets

以下为启动必需项：

```bash
pnpm exec wrangler secret put DB_HOST --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put DB_USER --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put DB_PASSWORD --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put DB_NAME --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put JWT_SECRET --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put APP_SECRET_KEY --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put ADMIN_DEFAULT_PASSWORD --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put AWS_ACCESS_KEY_ID --config cloudflare/backend/wrangler.jsonc
pnpm exec wrangler secret put AWS_SECRET_ACCESS_KEY --config cloudflare/backend/wrangler.jsonc
```

按需写入 `OPENAI_API_KEY`、`DEEPSEEK_API_KEY`、`MCP_SERVERS` 等种子值。AI/SMTP/MCP 数据表首次播种后以数据库配置为准。

Sync v2 shadow 默认保持关闭。准备灰度时，先把 `SYNC_V2_SHADOW_USER_IDS` 配成明确的
用户 ID allowlist，再把 `SYNC_V2_SHADOW_ENABLED` 改为 `true`；不要用 `*` 做首次灰度。
旧 `/uapi/sync` 不受这两个变量影响。

生成密钥示例：

```bash
openssl rand -base64 48
```

`ADMIN_DEFAULT_PASSWORD` 不能为空或使用公开默认值 `admin123`。已有生产实例必须保留原
`APP_SECRET_KEY`；不要因为重新部署而替换它。

`JWT_SECRET` 和 `APP_SECRET_KEY` 应分别生成、至少 32 字符，不能提交到 Git。Cloudflare
入口会拒绝缺失、过短或仍以 `CHANGE_ME` 开头的密钥，并且会在 migration 之前退出。

升级已有部署时必须继续使用原来的真实 `APP_SECRET_KEY`，否则已保存的 SMTP 密码无法解密。
如果历史部署从未配置该变量、实际使用过旧的公开默认值，应先生成新的随机密钥再升级，
随后到管理后台重新录入各 SMTP provider 的密码。第三方绑定 ticket 是短期数据，无需迁移；
不要为了保留旧 SMTP 密文而继续使用公开默认 key。

## 部署与验证

首次切换到 migration 管理前，先创建 PostgreSQL 可恢复快照，并至少在临时库完成一次恢复演练。
baseline migration 的 `down()` 会主动拒绝删旧表，不能把 `migration:revert` 当作回滚方案；
真正回滚依赖数据库快照与上一版镜像。同时保留原 `JWT_SECRET`、真实 `APP_SECRET_KEY`，
先用 canary/测试域名验证登录、SMTP、头像和旧 `/uapi/sync`，再切正式流量。

```bash
docker info
pnpm backend:build
pnpm backend:cloudflare:types
pnpm backend:cloudflare:check
pnpm backend:cloudflare:deploy
pnpm exec wrangler containers list
curl https://chatai-deep-backend.<你的-workers-subdomain>.workers.dev/healthz
```

首次部署后 Container 预配可能需要数分钟。健康检查成功后，再把 Flutter 的 `BACKEND_HOST` 和管理后台的 `NEXT_PUBLIC_BACKEND` 指向该 HTTPS 域名。

## 自定义域名

先确认 `workers.dev` 地址健康，再在 Cloudflare Dashboard 的 Worker 设置中添加 Custom Domain。绑定后把 `CORS_ORIGINS` 更新为管理后台的最终来源域名并重新部署。

## 注意事项

- 通用 Docker 镜像未设置 `REQUIRE_PERSISTENT_UPLOADS` 时仍保留旧行为：R2 凭据不全会使用临时盘。Cloudflare 配置显式设为 `true`，因此不会降级。
- `UPLOADS_DIR` 同时控制上传写入与 `/uploads/` 静态服务目录；R2 挂载启用 `fsync-on-close`，并限制为 128 MiB data cache / 20000 metadata entries，同时降低 flush 并发与 read-ahead，给 1 GiB `basic` 实例中的 Node 进程保留余量。
- Shell 作为 PID 1 监督 NestJS 与 TigrisFS；migration/backend 在独立进程组运行，
  `TERM/INT` 会转发到整组，并在 10 秒后有界升级为 `KILL`。NestJS 同时启用 shutdown
  hooks；退出时正常 unmount，挂载进程异常（含 zombie）时会停止后端，避免继续接受无法
  持久化的写入。
- PostgreSQL 必须启用 TLS/公网连接，并限制来源与权限。若供应商要求额外 SSL 参数，需要同步到 TypeORM 配置。
- 默认启用 `DB_SSL=true` 与证书校验；只有数据库供应商明确使用无法验证的自签名证书时，才将 `DB_SSL_REJECT_UNAUTHORIZED` 改为 `false`。
- `basic` 实例为 1 GiB 内存；上线后根据 Containers 指标再调整，避免先行扩容。
- 不要把 `.env`、R2 S3 密钥或数据库密码写入 `wrangler.jsonc`。
