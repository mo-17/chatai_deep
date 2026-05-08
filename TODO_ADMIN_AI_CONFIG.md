# 管理后台 · AI 服务与模型配置

本文件供另一个模型按顺序执行。所有路径相对仓库根目录 `/Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep/`。

> 前置条件：`TODO_ADMIN_DASHBOARD.md` 与 `TODO_DEEPSEEK_AND_BACKEND_TOGGLE.md` 已经全部完成。本文件只补缺口，不重复已有任务。

---

## 1. 背景与目标

### 现状（已经做完的部分，不要再做）
- **后端**：`chatgpt_backend/src/chat/chat.service.ts` 已经实现 `/uapi/chat/completions` JWT 转发；`apiKey / baseUrl` 来自 `ConfigService.get('OPENAI_API_KEY')` 等 **env 变量**；provider 路由用 model 前缀正则（`^gpt-|^o1-|^chatgpt-` → openai，`^deepseek-` → deepseek）。
- **后端**：`Usage` 实体已经在记录每次调用的 token 量。
- **Admin**：`chatgpt_admin/` 已有 Dashboard / 用户 / Banner / 版本 / 用量明细 / 设置共 6 个页面，技术栈 Next.js 15 + HeroUI + React Query + Zustand。
- **Flutter App**：`lib/util/model_catalog.dart` 写死了 OpenAI 与 DeepSeek 的常用模型清单；`AISettings` 里的 model 字段是 `String`，支持「自定义...」输入任意模型 ID。
- **Admin 鉴权**：所有 `/uapi/admin/**` 端点都已套 `AdminGuard`；JWT secret 已统一到 `src/auth/jwt.const.ts`。

### 缺口（本任务要解决的）
1. 运营人员**没有可视化界面**配置 OpenAI / DeepSeek 的 `apiKey`、`baseUrl`、是否启用。改 key 必须 SSH 到服务器改 `.env` 然后重启 NestJS——不可接受。
2. **后端模型路由表写死在代码里**：用前缀正则判断 provider，新加一个 `qwen-*` 上游就要改代码再发版。
3. **App 端模型下拉是硬编码**：上游出新模型（GPT-5、DeepSeek V4）App 必须发版才能选；用户只能走「自定义...」手填字符串，体验差。
4. **没有"默认模型"配置**：当前后端模式下，如果 App 端发来的 model 字符串既不匹配 OpenAI 也不匹配 DeepSeek，会落到 `BACKEND_DEFAULT_PROVIDER`（env 变量），但具体用哪个**模型**仍由 App 决定——后端应该有"兜底默认 provider+model"的能力。

### 目标
- 新增**后台 → AI 配置**模块（侧边栏一级菜单），包含三个子页：
  1. **服务商管理**（Providers）：CRUD OpenAI / DeepSeek / 自定义上游，含 `apiKey`、`baseUrl`、`enabled`、测试连接按钮。
  2. **模型管理**（Models）：CRUD 模型清单，每个模型关联一个 Provider，含 `modelId`、`displayName`、`description`、`enabled`、`sortOrder`、`isDefault`（每个 provider 可设一个默认）。
  3. **全局 AI 配置**（Global）：兜底 provider、兜底 model、是否暴露给 App 拉取（即开关 App 端是否能从后端拉模型清单覆盖本地硬编码）。
- 后端**改造 `ChatService`**：apiKey/baseUrl 从 DB 读（env 作为 fallback，启动时 seed 一次）；model→provider 路由从 DB `AiModel` 表查（前缀正则降级为 fallback）。
- 新增**公开端点 `GET /uapi/ai/catalog`**：返回 `{ providers, models }`，App 端登录后可调用刷新本地下拉清单（无需 admin 权限，但需 JWT）。
- **Flutter App 改造**：`ModelCatalog` 增加"远程拉取 + 本地兜底"能力——启动时尝试从后端拉一次，失败/无网络时用硬编码兜底。**`AISettings` 数据结构不变**。

### 不做的事（划清边界）
- ❌ 不做 apiKey 的加密存储（DB 明文，但 admin API 响应里 mask 成 `sk-***...***xxxx`，写入时支持留空表示"不变"）。生产环境用 KMS 是后续工作。
- ❌ 不做模型计费规则（每千 token 单价等）—— 表里只**预留** `inputPrice`、`outputPrice` 两个 nullable 字段，UI 不展示。
- ❌ 不做配置变更审计日志。
- ❌ 不做"流式响应"——`/uapi/chat/completions` 仍是一次性返回。
- ❌ 不动现有 `Usage` 表结构。
- ❌ 不引入 Redis 缓存——provider/model 配置读频次低，每次查 DB 即可（行数 < 50）。

---

## 2. 架构

### 2.1 数据模型（新增两张表 + 一张配置表）

#### `ai_providers`（服务商）
```ts
@Entity('ai_providers')
export class AiProvider {
  @PrimaryGeneratedColumn() id: number;
  @Column({ unique: true }) code: string;        // 'openai' | 'deepseek' | 'qwen' | ...，小写英文，唯一
  @Column() displayName: string;                 // '阿里通义千问'
  @Column() apiKey: string;                      // 明文存储（本任务范围内）
  @Column() baseUrl: string;                     // 'https://api.openai.com/v1'，注意：不带 /chat/completions 后缀
  @Column({ type: 'text', nullable: true }) modelPrefixes: string;  // 'gpt-,o1-,chatgpt-'，逗号分隔；用于"未在 ai_models 表登记的 model 字符串"做兜底匹配
  @Column({ default: true }) enabled: boolean;
  @Column({ default: 0 }) sortOrder: number;     // 越大越靠前
  @CreateDateColumn() createTime: Date;
  @UpdateDateColumn() updateTime: Date;
}
```

#### `ai_models`（模型清单）
```ts
@Entity('ai_models')
export class AiModel {
  @PrimaryGeneratedColumn() id: number;
  @Column() providerId: number;                  // FK → ai_providers.id（不建外键约束，仅逻辑关联）
  @Column() modelId: string;                     // 'gpt-4o-mini'，发给上游的字符串
  @Column() displayName: string;                 // 'GPT-4o mini'
  @Column({ type: 'text', nullable: true }) description: string;  // '小模型，性价比高'
  @Column({ default: true }) enabled: boolean;
  @Column({ default: false }) isDefault: boolean;// 该 provider 下的默认模型；同 providerId 内最多一条 true（service 层保证）
  @Column({ default: 0 }) sortOrder: number;
  @Column({ type: 'decimal', precision: 10, scale: 6, nullable: true }) inputPrice: number;   // 预留
  @Column({ type: 'decimal', precision: 10, scale: 6, nullable: true }) outputPrice: number;  // 预留
  @CreateDateColumn() createTime: Date;
  @UpdateDateColumn() updateTime: Date;

  // (providerId, modelId) 联合唯一，用 @Index 实现
}
```
DDL 提示：在 entity class 上加
```ts
@Index('idx_provider_model', ['providerId', 'modelId'], { unique: true })
```

#### `ai_global_config`（全局配置，单例表，永远只有一行）
```ts
@Entity('ai_global_config')
export class AiGlobalConfig {
  @PrimaryGeneratedColumn() id: number;          // 永远是 1
  @Column({ default: 'deepseek' }) defaultProviderCode: string;
  @Column({ default: 'deepseek-chat' }) defaultModelId: string;
  @Column({ default: true }) catalogPublic: boolean;   // App 端是否允许拉 /uapi/ai/catalog
  @UpdateDateColumn() updateTime: Date;
}
```
> 单例表用 `id=1` 固定行；service 层用 `findOneBy({ id: 1 })`，不存在则插入默认。**不要**用 `synchronize` 配合 seed file，直接在 `OnApplicationBootstrap` 钩子里 `upsert`。

### 2.2 Seed 策略（启动时）
启动时检查：
1. `ai_providers` 表如果**完全空**，插入两条：
   - `{ code: 'openai',   displayName: 'OpenAI',   apiKey: process.env.OPENAI_API_KEY   ?? '', baseUrl: process.env.OPENAI_BASE_URL   ?? 'https://api.openai.com/v1',   modelPrefixes: 'gpt-,o1-,chatgpt-', enabled: true, sortOrder: 100 }`
   - `{ code: 'deepseek', displayName: 'DeepSeek', apiKey: process.env.DEEPSEEK_API_KEY ?? '', baseUrl: process.env.DEEPSEEK_BASE_URL ?? 'https://api.deepseek.com', modelPrefixes: 'deepseek-',         enabled: true, sortOrder: 90 }`
2. `ai_models` 表如果完全空，按 `chatgpt_flutter/lib/util/model_catalog.dart` 的当前清单全量 seed（关联到对应 provider）。具体清单：
   - **OpenAI**：`gpt-3.5-turbo`、`gpt-4o-mini`（`isDefault: true`）、`gpt-4o`、`gpt-4-turbo`、`o1-mini`、`o1`
   - **DeepSeek**：`deepseek-chat`（`isDefault: true`）、`deepseek-reasoner`
3. `ai_global_config` 不存在则插入默认行（`id=1, defaultProviderCode: 'deepseek', defaultModelId: 'deepseek-chat', catalogPublic: true`）。

> Seed 只在表"完全为空"时跑，不要做任何"对比补齐"——管理员手动删掉的模型不应被启动钩子复活。

### 2.3 后端新端点

#### Admin（套 `AdminGuard`，前缀 `/uapi/admin/ai`）

| 方法 | 路径 | 说明 |
|-|-|-|
| GET    | `/providers` | 列表，apiKey **mask**（仅返回前 4 + 后 4，中间 `****`） |
| POST   | `/providers` | 新增 |
| GET    | `/providers/:id` | 详情，apiKey 同样 mask（编辑表单里展示 mask 串，提交时为空表示不变，非空表示覆写——见 2.4） |
| PATCH  | `/providers/:id` | 编辑 |
| DELETE | `/providers/:id` | 删除（同时级联删 `ai_models` 中 `providerId=:id` 的行；事务包裹） |
| POST   | `/providers/:id/test` | 测试连接：后端用该 provider 的 key/url 发一条 `model=该 provider 的默认模型，messages=[{role:user,content:'ping'}],max_tokens=8` 的请求；成功返回 `{ ok: true, latencyMs, sample: '<上游回复前 50 字>' }`；失败 `{ ok: false, error: '...' }` |
| GET    | `/models` | 列表，可 query：`providerId, enabled, keyword`（匹配 modelId/displayName） |
| POST   | `/models` | 新增 |
| GET    | `/models/:id` | 详情 |
| PATCH  | `/models/:id` | 编辑 |
| DELETE | `/models/:id` | 删除 |
| POST   | `/models/:id/set-default` | 设为该 provider 的默认；service 层把同 providerId 的其他行 `isDefault=false`（事务） |
| GET    | `/global` | 全局配置 |
| PATCH  | `/global` | 更新全局配置；校验 `defaultProviderCode` 与 `defaultModelId` 在表里存在且 `enabled=true`，否则 400 |

#### Public（套 `JwtGuard`，普通用户也能调）

| 方法 | 路径 | 说明 |
|-|-|-|
| GET | `/uapi/ai/catalog` | 返回 `{ providers: [{code, displayName}], models: [{modelId, displayName, description, providerCode, isDefault, sortOrder}], default: {providerCode, modelId} }`；**仅返回 `enabled=true` 的行**；如果 `ai_global_config.catalogPublic=false` 则返 403 |

> **响应字段不含 apiKey / baseUrl**——这两个属服务端机密。

### 2.4 apiKey 写入约定（关键，不要写错）
- POST `/providers`：`apiKey` 必填、原样落库。
- PATCH `/providers/:id`：body 里 `apiKey` 字段
  - **不传** 或 **空字符串** → 保留 DB 原值（service 层 `delete dto.apiKey`）
  - 传非空字符串 → 覆写
- GET 返回时永远 mask；前端表单展示 placeholder = "未变更则留空"。

### 2.5 ChatService 改造
`chatgpt_backend/src/chat/chat.service.ts` 当前 `complete()` 内部：

**新流程**：
1. 注入 `AiProvider`、`AiModel`、`AiGlobalConfig` 三个 Repo。
2. 解析 provider：
   - 先查 `ai_models` 表 `modelId = body.model` 拿 providerId → providerCode
   - 找不到 → 遍历 `ai_providers` 表（按 `enabled=true, ORDER BY sortOrder DESC`），按 `modelPrefixes` 逗号分隔的前缀逐个 `startsWith` 匹配
   - 仍找不到 → 用 `ai_global_config.defaultProviderCode`
3. 取 provider 的 `apiKey` / `baseUrl`：直接读 DB；**env 不再作为运行期 fallback**（仅 seed 期参考）。
4. 如果 `apiKey` 为空 → `BadGatewayException('服务商 ${providerCode} 未配置 API Key，请联系管理员')`。
5. 如果 provider `enabled=false` → 同上文案换成「服务商 ${displayName} 已停用」。
6. 其余 fetch / 写 Usage 逻辑不变。

> 测试连接端点 `POST /admin/ai/providers/:id/test` 复用 ChatService 内部的 fetch 逻辑（抽出一个私有 `callUpstream(provider, body)` 方法供两边复用），但**不写 Usage 表**。

### 2.6 Provider 路由表（变更后）
| 来源 | 优先级 |
|-|-|
| `ai_models` 表里的精确 modelId 映射 | 1（最高） |
| `ai_providers.modelPrefixes` 字段配置的前缀 | 2 |
| `ai_global_config.defaultProviderCode` | 3（兜底） |

env 变量 `BACKEND_DEFAULT_PROVIDER` 在本任务后**作废**——seed 期完成后再不读取，README 与 `.env.example` 移除该项。

---

## 3. 任务列表

### 后端任务

#### 任务 BA1：新增三张表的 Entity + Module 注册

**新增文件**：
- `chatgpt_backend/src/ai/ai-provider.entity.ts`
- `chatgpt_backend/src/ai/ai-model.entity.ts`
- `chatgpt_backend/src/ai/ai-global-config.entity.ts`
- `chatgpt_backend/src/ai/ai.module.ts`（先空模块，后续控制器/服务陆续加进来）

**改动文件**：
- `chatgpt_backend/src/app.module.ts`：注册 `AiModule`，并把三个 entity 加入 `TypeOrmModule.forRoot.entities` 自动加载（如已用 `autoLoadEntities: true` 则只需 import 模块）。

**步骤**：
1. 三个 entity 按 2.1 节字段定义编写。
2. `ai-model.entity.ts` 用 `@Index('idx_provider_model', ['providerId','modelId'], { unique: true })`。
3. `AiModule` 暂时只 `imports: [TypeOrmModule.forFeature([AiProvider, AiModel, AiGlobalConfig])]`，`exports` 同上（后面 ChatModule 要 inject）。

**验收**：`npm run start:dev` 启动后 Postgres 里出现三张表（`\dt ai_*` 或 `psql -c "\dt"`）。

---

#### 任务 BA2：Seed Service

**新增文件**：`chatgpt_backend/src/ai/ai-seed.service.ts`

**步骤**：
1. `AiSeedService implements OnApplicationBootstrap`。
2. `onApplicationBootstrap()` 顺序执行 2.2 节三段 seed 逻辑，事务包裹。
3. 在 `AiModule` 的 `providers` 里注册它。
4. seed OpenAI/DeepSeek 模型清单时，硬编码列表（与 `model_catalog.dart` 当前内容对齐）；不要从 Flutter 文件读字符串。

**验收**：
- 冷启 DB（`DROP TABLE ai_providers, ai_models, ai_global_config`）后 `npm run start:dev`，`SELECT * FROM ai_providers` 出现 2 行，`SELECT count(*) FROM ai_models` ≥ 8，`SELECT * FROM ai_global_config` 1 行。
- 改其中一行 `enabled=false`，重启后**不被复活**。

---

#### 任务 BA3：ChatService 改造（DB 驱动 provider）

**改动文件**：`chatgpt_backend/src/chat/chat.service.ts` + `chatgpt_backend/src/chat/chat.module.ts`

**步骤**：
1. `ChatModule` 新增 `imports: [TypeOrmModule.forFeature([Usage, AiProvider, AiModel, AiGlobalConfig])]`。
2. `ChatService` 构造函数注入三个新 Repo，移除 `ConfigService`（仅保留 Usage Repo + 三个 AI Repo）。
3. 抽出私有方法：
   ```ts
   private async resolveProvider(model: string): Promise<AiProvider> { ... }
   private async callUpstream(provider: AiProvider, body: CompletionBody): Promise<UpstreamResponse> { ... }
   ```
4. `complete(userId, body)` 用上面两方法 + 写 Usage。
5. **删除** `BACKEND_DEFAULT_PROVIDER`、`OPENAI_API_KEY`、`OPENAI_BASE_URL`、`DEEPSEEK_API_KEY`、`DEEPSEEK_BASE_URL` 在 `chat.service.ts` 的所有引用。
6. `app.module.ts` 不再需要 `ConfigModule.forRoot` 给 ChatModule 用——保留 ConfigModule（仍服务 JWT 等），但 ChatModule 不 inject。
7. `chatgpt_backend/.env.example` 移除上述 5 个变量；保留 `JWT_SECRET`、`ADMIN_DEFAULT_*`。
8. `chatgpt_backend/README.md` 把"环境变量"一节里 5 项删除，新增一句"AI 服务商与模型在管理后台 → AI 配置 中维护"。

**验收**：
- App 端按现有流程发消息仍能收到回复（DB 里 seed 出来的 deepseek key 是空的——临时用 admin UI 填一下再测，**或** 在 `.env.local` 里把 key 写到 `OPENAI_API_KEY/DEEPSEEK_API_KEY`，**删表重启**让 seed 把 key 带进 DB）。
- 把 `ai_providers` 中 deepseek 的 `enabled` 改成 `false`，App 发 `model=deepseek-chat` 应得到 `服务商 DeepSeek 已停用` 错误（502）。

---

#### 任务 BA4：Admin AI 控制器 + 服务

**新增文件**（全部在 `chatgpt_backend/src/ai/`）：
- `admin-ai-provider.controller.ts` + `admin-ai-provider.service.ts`
- `admin-ai-model.controller.ts` + `admin-ai-model.service.ts`
- `admin-ai-global.controller.ts` + `admin-ai-global.service.ts`
- `dto/` 目录下的 `create-provider.dto.ts`、`update-provider.dto.ts`、`create-model.dto.ts`、`update-model.dto.ts`、`update-global.dto.ts`

**步骤**：
1. 全部 controller class 级套 `@UseGuards(AdminGuard)`，路由前缀 `uapi/admin/ai`。
2. DTO 用 `class-validator`：
   - `code`: `@IsString() @Matches(/^[a-z][a-z0-9_-]*$/)`
   - `baseUrl`: `@IsUrl({ require_tld: false })`（允许 localhost）
   - `apiKey` 在 update 里 `@IsOptional() @IsString()`
   - `defaultProviderCode`、`defaultModelId` 在 update-global 里 service 层做存在性 + enabled 校验（class-validator 不直接查 DB）
3. mask 逻辑放 service 层 helper：
   ```ts
   private maskKey(k: string) {
     if (!k || k.length <= 8) return '****';
     return k.slice(0, 4) + '****' + k.slice(-4);
   }
   ```
   GET 列表/详情前 map 一遍。
4. `set-default` 端点：事务里先 `UPDATE ai_models SET isDefault=false WHERE providerId=?`，再 `UPDATE ai_models SET isDefault=true WHERE id=?`。
5. **provider DELETE**：先删该 providerId 下所有 `ai_models` 行，再删 provider，事务包裹。如果删除后导致 `ai_global_config.defaultProviderCode` 指向被删 provider，`update-global` 校验下次保存时会拦——本任务**不**做主动级联修复，但要 `console.warn` 一句"全局默认 provider 已不可用，请到全局配置页修改"。
6. `POST /providers/:id/test`：调 ChatService 暴露的 `callUpstream` 方法（在 ChatModule 里 `exports: [ChatService]`，AiModule import ChatModule，或者把 `callUpstream` 抽到独立的 `UpstreamCallerService`——选**前者更省事**）。测试用的 model 取该 provider 下 `isDefault=true` 的那一条；若 provider 下没有任何 model，则用 `body.model = provider.code === 'openai' ? 'gpt-4o-mini' : provider.code === 'deepseek' ? 'deepseek-chat' : ''`，仍为空就 400。
7. `AiModule` 注册控制器与服务。

**验收**：
- 用 admin token curl 全部端点。
- `curl -X POST .../providers/<id>/test`：填错 key 返 `{ ok: false }`；填对返 `{ ok: true, latencyMs, sample }`。
- 重置某 provider 默认模型后，`GET /models?providerId=X` 看到 `isDefault` 翻转。

---

#### 任务 BA5：Public Catalog 端点

**新增文件**：
- `chatgpt_backend/src/ai/public-ai.controller.ts`

**步骤**：
1. 路由前缀 `uapi/ai`，`@UseGuards(JwtGuard)`（注意：不是 AdminGuard）。
2. `GET /catalog` 实现按 2.3 节定义：
   - 检查 `ai_global_config.catalogPublic`，false 则 `ForbiddenException`。
   - 返回结构：
     ```ts
     {
       providers: Array<{ code: string; displayName: string }>;
       models: Array<{
         modelId: string; displayName: string; description: string | null;
         providerCode: string; isDefault: boolean; sortOrder: number;
       }>;
       default: { providerCode: string; modelId: string };
     }
     ```
   - 用一次 join 查询拿 modelId + providerCode，避免 N+1。

**验收**：用普通用户 token 调 `/uapi/ai/catalog` 拿到结构正确数据；admin 也能调。

---

### Admin 前端任务

> 全部在 `chatgpt_admin/` 内进行。沿用既有 React Query + Zustand + HeroUI 模式，参考已有的 `users/page.tsx`、`banners/page.tsx` 写法。

#### 任务 FA1：API 类型与客户端

**新增文件**：
- `chatgpt_admin/src/types/ai.ts`
- `chatgpt_admin/src/lib/api/ai.ts`
- `chatgpt_admin/src/hooks/useAi.ts`
- `chatgpt_admin/src/schemas/ai.ts`（zod）

**步骤**：
1. `types/ai.ts` 定义 `AiProvider`、`AiModel`、`AiGlobalConfig`、`TestConnectionResult` TS 接口。注意 `apiKey` 在前端类型里仍是 `string`，后端给的是 mask 串。
2. `lib/api/ai.ts` 导出 `aiApi` 对象，方法：
   ```ts
   listProviders, getProvider, createProvider, updateProvider, deleteProvider, testProvider,
   listModels, getModel, createModel, updateModel, deleteModel, setDefaultModel,
   getGlobal, updateGlobal,
   ```
3. `hooks/useAi.ts` 用 React Query 包装，query key 约定：
   - `['ai','providers', filters]`
   - `['ai','models', filters]`
   - `['ai','global']`
   写入 mutation 成功后 `queryClient.invalidateQueries({ queryKey: ['ai'] })`。
4. zod schema 与后端 DTO 字段对齐：
   - providerCreate：`code`、`displayName`、`apiKey`（必填）、`baseUrl`、`modelPrefixes`、`enabled`、`sortOrder`
   - providerUpdate：同上但 `apiKey` 改 `.optional()`
   - modelCreate/Update、globalUpdate 同理

**验收**：`npm run build` 通过；类型推断在 IDE 里无 `any`。

---

#### 任务 FA2：侧边栏新增「AI 配置」一级菜单

**改动文件**：`chatgpt_admin/src/components/layout/Sidebar.tsx`

**步骤**：
1. 在 Banner / 版本 之间或之后插入一项分组（HeroUI `Listbox` 的 `section`）「AI 配置」，含 3 个二级链接：
   - `/ai/providers` — 服务商
   - `/ai/models` — 模型
   - `/ai/global` — 全局配置
2. 图标用 `lucide-react` 的 `Sparkles`（一级）、`Server` / `Boxes` / `Settings2`（三个二级）。
3. 当前路由高亮逻辑沿用已有 `usePathname()`。

**验收**：登录后侧边栏看到新菜单；点击不报 404（先用占位页，FA3-5 实装）。

---

#### 任务 FA3：服务商列表与表单 `app/(dashboard)/ai/providers/page.tsx`

**新增文件**：
- `chatgpt_admin/src/app/(dashboard)/ai/providers/page.tsx`
- `chatgpt_admin/src/components/ai/ProviderForm.tsx`（弹窗内的表单复用，create/edit 共用）

**布局**：
- 顶部 `PageHeader`：标题「服务商管理」+ 右侧按钮「新增服务商」
- `Table` 列：
  - `code`（badge 风格）
  - `displayName`
  - `apiKey`（mask 显示，旁边一个眼睛图标点击切换显隐——因为是 mask，显隐切换只是把整串展开/折叠，不会拿到原文）
  - `baseUrl`（可点击跳转）
  - `modelPrefixes`（chip 列表）
  - `enabled` Switch（点击直接 PATCH `enabled`，不弹窗）
  - `sortOrder`
  - 操作：测试连接 / 编辑 / 删除

**ProviderForm**：
- 字段：code（创建时可填，编辑时只读）、displayName、apiKey（password 输入框 + 显隐切换；编辑时 placeholder='未变更则留空'）、baseUrl、modelPrefixes（字符串输入，用户填逗号分隔）、enabled Switch、sortOrder Number
- zod 校验同 FA1
- 保存：mutation 成功后 toast + 关闭弹窗 + invalidateQueries

**测试连接交互**：
- 点击行内「测试连接」按钮 → 行内出 `Spinner` → 完成后 `Toast` 显示 `✓ 连接成功 (latencyMs ms)，回复样本: ...` 或 `✗ 失败：${error}`

**删除交互**：
- `ConfirmDialog` 二次确认，提示「将同时删除该服务商下所有模型（n 个）」（n 通过 `useQuery(['ai','models',{providerId}])` 拿；如果加载中显示「将级联删除关联模型」）

**验收**：
- 创建一条新 provider（code=qwen，apiKey=空字符串，baseUrl=https://dashscope.aliyuncs.com/compatible-mode/v1），保存成功
- 编辑时 apiKey 留空保存，重新刷新看到 apiKey 仍是 mask 旧值（即未被覆盖）
- 测试连接对错 key 报错、对正确 key 成功
- 删除 deepseek provider 后 models 表对应行也消失（admin 后台 models 列表少 2 条）

---

#### 任务 FA4：模型列表与表单 `app/(dashboard)/ai/models/page.tsx`

**新增文件**：
- `chatgpt_admin/src/app/(dashboard)/ai/models/page.tsx`
- `chatgpt_admin/src/components/ai/ModelForm.tsx`

**布局**：
- 顶部工具栏：providerId Select（含「全部」选项，从 `useProviders` 拉数据填）、`enabled` 三态 Select（全部 / 启用 / 停用）、keyword 搜索（防抖 400ms）、右侧「新增模型」
- `Table` 列：
  - `displayName` + `modelId`（双行单元格）
  - `providerCode`（chip）
  - `description`（最多 2 行，超出 ellipsis）
  - `enabled` Switch
  - `isDefault` 单选 Radio（点击触发 set-default）
  - `sortOrder`
  - 操作：编辑 / 删除

**ModelForm**：
- 字段：providerId（Select，从 providers 拉）、modelId、displayName、description（Textarea）、enabled Switch、isDefault Switch、sortOrder

**验收**：
- 新增一条 `gpt-5`（即使后端不存在该模型，也允许创建——清单只是 UI 提示用）
- 给 deepseek 切换默认模型 `deepseek-reasoner`，再 GET `/admin/ai/models?providerId=<deepseek>` 看到 `deepseek-chat` 的 isDefault 已自动翻成 false
- 用 `keyword=mini` 能筛出 `gpt-4o-mini`、`o1-mini`

---

#### 任务 FA5：全局配置页 `app/(dashboard)/ai/global/page.tsx`

**新增文件**：
- `chatgpt_admin/src/app/(dashboard)/ai/global/page.tsx`

**布局**（单卡片表单，不是表格）：
- `defaultProviderCode`：Select（来自 providers，仅 enabled=true）
- `defaultModelId`：Select（来自 models，仅 enabled=true，且按当前选中的 providerCode 过滤——切换 provider 时下游 select 自动重置）
- `catalogPublic`：Switch（标题「允许 App 拉取模型清单」，副标题「关闭后 App 端 `/uapi/ai/catalog` 返回 403，App 将仅显示本地硬编码清单」）
- 底部「保存」按钮，loading 态走 RQ mutation

**验收**：
- 改完保存后刷新页面，值能持久
- 把 `defaultProviderCode` 设成一条已停用的 provider → 后端返 400（前端 toast 显示后端 message）
- 关闭 `catalogPublic` 开关后，App 调 `/uapi/ai/catalog` 返 403

---

### Flutter App 任务（可选但建议做）

#### 任务 FF1：远程模型清单与本地兜底

**改动文件**：
- `chatgpt_flutter/lib/util/model_catalog.dart`
- `chatgpt_flutter/lib/main.dart`（doInit 里追加一次远程拉取，失败不阻塞 UI）

**新增文件**：
- `chatgpt_flutter/lib/dao/ai_catalog_dao.dart`

**步骤**：
1. `AiCatalogDao.fetchRemote()`：GET `${BackendConst.host}/uapi/ai/catalog`，带 `hiHeaders()`（JWT）；解析后转成 `ModelCatalog` 期望的结构，写入 `HiCache` key `ai_catalog_v1`。
2. `ModelCatalog` 改成有状态：
   ```dart
   class ModelCatalog {
     static List<ModelOption> _openai = _hardcodedOpenai;
     static List<ModelOption> _deepseek = _hardcodedDeepseek;
     static String? _remoteDefaultProvider;
     static String? _remoteDefaultModel;

     static List<ModelOption> get openai => _openai;
     static List<ModelOption> get deepseek => _deepseek;
     static List<ModelOption> backendAll() => [..._deepseek, ..._openai];

     static void loadFromCache() { /* 启动时同步读 HiCache，覆盖默认 */ }
     static Future<void> refreshFromBackend() async { /* 异步拉，写缓存，更新内存 */ }
   }
   ```
3. `_hardcodedOpenai` / `_hardcodedDeepseek` 即原本写死的清单，**不要删**，作为兜底（首装无网络也要能用）。
4. `main.dart` `doInit()` 末尾：
   - 同步：`ModelCatalog.loadFromCache()`（不阻塞）
   - 异步 fire-and-forget：`unawaited(ModelCatalog.refreshFromBackend())`（不要 `await`，失败 swallow）
5. **未登录时不要发请求**——`refreshFromBackend` 内部检查 `LoginDao.getBoardingPass() == null` 直接返回。

**验收**：
- 后端在 admin 加一个新模型 `gpt-5o`（OpenAI 下），App 重启后下拉里出现；卸载重装后**首次启动**用兜底清单（看不到 `gpt-5o`），登录后再次重启就能看到。
- 关后端服务器，App 仍能正常打开 AI 设置页（用兜底清单）。
- 关 `catalogPublic` 后 App 端不会因为 403 报错弹窗（静默吞掉）。

---

## 4. 执行顺序

按下表顺序，每完成一项跑相应测试：

| # | 任务 | 验证 |
|-|-|-|
| 1 | BA1 三表 entity | `\dt ai_*` 见三张表 |
| 2 | BA2 Seed Service | 删表重启，行数正确 |
| 3 | BA3 ChatService 改造 | App 发消息走通；改 enabled 报错 |
| 4 | BA4 Admin AI 控制器 | curl 全部端点 |
| 5 | BA5 Public catalog | 普通用户 token 拉到清单 |
| 6 | FA1 前端 API 层 | `npm run build` 通过 |
| 7 | FA2 侧边栏 | 菜单可见、能跳转（占位即可） |
| 8 | FA3 Providers UI | 完整 CRUD + 测试连接 |
| 9 | FA4 Models UI | 完整 CRUD + set-default |
| 10 | FA5 Global UI | 保存、校验、catalogPublic 联动 |
| 11 | FF1 Flutter 远程清单 | App 端模型下拉随后台变化 |

> 5 与 11 之间不强制依赖；前端任务可在后端步骤每完成一个就开工对应页面。

---

## 5. 验收清单

执行结束后用以下场景**全部**验证：

### 5.1 服务商 CRUD
- 新增 `qwen` 服务商成功；列表里 apiKey 显示 mask
- 编辑时 apiKey 留空，DB 里旧 key 不变（直接 SQL 验证）
- 删除 deepseek 时弹窗提示「将级联删除 N 个模型」，确认后 `ai_models` 中关联行同步清掉

### 5.2 测试连接
- 把 OpenAI 的 baseUrl 故意写错 → 测试连接显示失败，不写 Usage 表
- 改回正确值 → 显示 `✓ 连接成功 (xxx ms)`，sample 字段含 ping 回复
- DeepSeek key 留空 → 测试连接返 `服务商未配置 API Key` 错误

### 5.3 模型 CRUD
- 创建 `claude-sonnet-4-6`（关联 anthropic provider，需先在 5.1 创建 anthropic provider+key）
- 给 OpenAI 切换默认模型从 `gpt-4o-mini` 到 `gpt-4o`，DB 里 `isDefault` 翻转无双写
- keyword 搜索 / providerId 筛选 / enabled 筛选三种条件单独/组合都生效

### 5.4 全局配置
- 把 `defaultModelId` 改成不存在的 `xxx` → 后端 400，前端 toast 显示
- `catalogPublic` 关闭后，curl `/uapi/ai/catalog` 返 403（用普通用户 token）

### 5.5 路由表
- App 用 model=`deepseek-reasoner` 发消息 → 走 deepseek（`Usage.provider='deepseek'`）
- App 用 model=`gpt-4o` 发消息 → 走 openai
- App 用 model=`unknown-model-xyz`（既不在 ai_models 表也不匹配任何 modelPrefixes）→ 走全局默认 provider；后端日志能看到「fallback to default provider」

### 5.6 Flutter App 同步
- admin 加新模型 → App 重启后下拉看到
- admin 停用某模型 → App 重启后下拉不再展示该模型，但**已选中**该模型的会话仍能发出（model 字符串原样发，后端按精确匹配仍能路由）

### 5.7 通用稳定性
- 后端 `npm run lint` 通过
- 前端 `npm run build` 通过
- Flutter `flutter analyze`（chatgpt_flutter）通过

---

## 6. 风险与注意事项

- **apiKey 明文存 DB**：本任务范围内沿用现状，列表/详情接口必须 mask；切勿在日志或错误响应里 echo 原文。后续接 KMS 是另开任务。
- **mask 后无法"复制"原 key**：admin UI 上不要提供"复制 apiKey"按钮，免得用户期待复制出原文。
- **`ai_global_config` 单例约束**：service 层永远 `findOneBy({ id: 1 })` + `update` / 兜底 `insert(id=1,...)`；不要做 `find()` 后 `[0]`。
- **删除 provider 不要级联到 Usage 表**：Usage 历史记录与当前 provider 表解耦（`Usage.provider` 是 string 快照，不存 FK）；删 provider 不影响历史用量统计。
- **`set-default` 必须事务**：先清同 providerId 下所有 isDefault=false，再设目标行 true。如果不事务，并发可能让 0 条或 2 条 isDefault=true。
- **Flutter 远程拉清单失败时绝不能弹窗或报错**：用户没登录、网络断、后端宕、catalog 关闭 → 全部 swallow，回到硬编码兜底。`unawaited` 保证 doInit 不阻塞。
- **`modelPrefixes` 字段空字符串 vs null**：service 层把 `null` 与 `''` 视作"无前缀匹配"；前端表单初始化时把 `null` 转成 `''` 给 controlled input。
- **Seed 时机**：seed 必须在 ChatService 初始化**之前**完成？——不需要，`OnApplicationBootstrap` 钩子在所有 Module init 完成后跑；ChatService 第一次被 HTTP 请求调用一定晚于 bootstrap。但**首次启动后立刻发请求**的极小窗口内 seed 可能未跑完——本任务不处理这个边界（生产实际不会出现）。
- **DTO `class-validator` 全局 Pipe**：确认 `main.ts` 已经 `app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }))`（`TODO_ADMIN_DASHBOARD.md` 任务 B5 应该已配；如未配本任务必须补上）。
- **路径冲突**：现有路由前缀 `/uapi/ai/...` 与 `/uapi/admin/ai/...` 不要写反；前者是普通用户的 catalog，后者是 admin。
- **JWT secret 仍来自 `jwt.const.ts`**：本任务不动这部分。
- **Model entity 的 `providerId` 不建外键**：避免 TypeORM `synchronize: true` 时跨表迁移的复杂度；逻辑约束在 service 层（删除/更新时校验存在性）。
- **`recharts` / 图表**：本任务无图表需求，不要节外生枝。

---

## 7. 完成后输出

请在执行结束时给出一份摘要报告：
- 每个任务（BA1–BA5、FA1–FA5、FF1）的状态（done / partial / blocked）
- 新增 / 修改的文件清单（按 backend / admin / flutter 三栏分组）
- 验收清单 5.1–5.7 每条的实测结果（curl 输出 / SQL / 截图描述）
- 实际执行命令与默认值（admin 默认账号、起前后端的命令）
- 任何发现的、本文档未覆盖的边界情况或后续待办（例如 KMS、apiKey 加密、流式响应等）
