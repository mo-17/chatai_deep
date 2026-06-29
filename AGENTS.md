# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Repository layout

Multi-package monorepo: a Flutter ChatGPT/AI client (Android/iOS/desktop + a separate HarmonyOS shell) plus a NestJS backend and a Next.js admin. Flutter packages live as siblings under the repo root and are wired together via `pubspec.yaml` `path:` dependencies; Node packages are joined by a root `pnpm-workspace.yaml`.

**App shells** (entry points — each has its own `lib/main.dart` and platform folders):
- `chatgpt_flutter/` — Android / iOS / desktop shell. Depends directly on `chatgpt_app_core` + `login_sdk`. Current version `1.0.2+3`.
- `chatgpt_flutter_ohos/` — HarmonyOS shell (separately versioned `1.0.0+1`). Same core, but uses `dependency_overrides` to pull OHOS-SIG forks of `sqflite`, `sqflite_common_ffi`, `path_provider`, `url_launcher`, `shared_preferences`, plus three local stubs (see HarmonyOS section). `package_info_plus` has no OHOS impl — handled by runtime branch.

**Shared core**:
- `chatgpt_app_core/` — all business code (pages, DAOs, DB, widgets, providers) **plus the assistant/tool-calling, knowledge-base/RAG, web-search, multi-provider config, and backup subsystems**. Entry point is `lib/app.dart:runChatGptApp`; both app shells just call it. Transitively pulls `login_sdk`, `auth_kit_flutter`, `hi_download`, `chat_message`, `openai_flutter` — these don't need to be listed in the shell's `pubspec.yaml`, but they DO have to exist as siblings on disk for `pub get` to resolve. The chat engine lives under `lib/chat/` split into `application/` (services), `domain/` (types), and `ui/` (block widgets).

**Login + auth**:
- `login_sdk/` — login / register / forgot-password / **guest login** UI + `LoginDao` (boarding pass, account hash, login/logout hooks) + `hiHeaders()` for backend calls + `BackendConfig` (host/scheme) + a pluggable `LoginSdkConfig` (injectable baseUrl / headers / routes / `TokenStorage`). Three pages share a single `LoginPalette` so chrome colors react to the active background; `LoginBgVariant` ships 20 immersive bg variants. The login pages now drive auth through `auth_kit_flutter`'s `AuthDao` (`/uapi/auth/*`), not the legacy `/uapi/user/*` routes.
- `auth_kit_flutter/` — reusable auth widgets (verification code, country code picker, third-party binding) **and `AuthDao`**, which wraps all `/uapi/auth/*` endpoints (code send, login/code, login/password, register, bind, reset-password, huawei/*, apple/*). Pulled in by `login_sdk` (not the shell). Backend counterpart is the `@auth-kit` package consumed by `chatgpt_backend`.

**Other Flutter siblings**:
- `openai_flutter/` — direct OpenAI/DeepSeek SDK (`AIConfigBuilder`, `AICompletion`, `AIHttp`). Used when "本地直连" mode is selected; "后端代理" mode bypasses this in favor of `/uapi/chat/completions`.
- `chat_message/` — chat-bubble UI + `ChatController` driving a `Stream<List<MessageModel>>`. Now built on `ScrollablePositionedList` (`reverse:true`); `ChatController` requires/owns an `ItemScrollController` + `ItemPositionsListener` and exports them so callers can drive scroll jumps.
- `hi_download/` — APK download helper used by the in-app updater.

**Server side**:
- `chatgpt_backend/` — NestJS 11 + TypeORM + Postgres. Modules: `user`, `auth` (auth-kit multi-channel via `AuthKitModule.forRootAsync` + JWT guards), `chat` (conversation + message + usage entities, OpenAI-compatible completions + SSE proxy), `ai` (global config / providers / models with capability bits + admin CRUD + public catalog), `admin` (banner / version / user / usage analytics / auth admin), `notice`, `update`, `health`, `test` (auto-disabled in production). Pino logger, throttler guard, env-driven config.
- `chatgpt_admin/` — Next.js 16 + React 19 admin console (port 3001). **Read `chatgpt_admin/AGENTS.md` first** — it warns about breaking Next.js changes vs training data. UI on HeroUI (migrated from NextUI) + Tailwind v4. Data layer: TanStack Query + axios + Zod + React Hook Form + Zustand (also ahooks / recharts / dayjs / lucide / framer-motion).

**Demos (not depended on)**:
- `chat_db/`, `flutter_network/` — standalone course demos. Don't assume edits affect the app.

## Common commands

### Flutter Android / iOS / desktop (`chatgpt_flutter/`)
```bash
flutter pub get         # also run inside each path-dep package after first clone
flutter run             # picks up the connected device
flutter test            # widget/unit tests under test/ (chatgpt_app_core has 20+ test files)
flutter analyze
```
Single test: `flutter test test/widget_test.dart --plain-name "<test name>"`.

### Flutter HarmonyOS (`chatgpt_flutter_ohos/`)
Requires DevEco Studio toolchain — `mise.toml` sets `DEVECO_SDK_HOME` + paths. Always activate mise first:
```bash
cd chatgpt_flutter_ohos
eval "$(mise activate bash --shims)"      # or zsh
flutter pub get
flutter build hap                           # OHOS package
flutter run                                  # connected OHOS device
```
See [[project_ohos_build]] in user memory for the full build/install/launch command chain.

### Backend (`chatgpt_backend/`)
Repo root is a **pnpm workspace** (`pnpm-workspace.yaml`). Run `pnpm install` once at the root — installs both backend + admin and shares deps via the pnpm store.
```bash
pnpm install                                              # at repo root
pnpm --filter chatgpt_backend run start:dev               # nest start --watch
pnpm --filter chatgpt_backend run lint
pnpm --filter chatgpt_backend test
pnpm --filter chatgpt_backend run test:e2e
```
Single test: `pnpm --filter chatgpt_backend exec jest <pattern>` or `pnpm --filter chatgpt_backend test -- -t "<test name>"`.

DB config is env-driven (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, plus `DB_LOGGING` and `DB_POOL_MAX` default 10) with local defaults (`localhost:5432`, user `huangzhibin`, db `chatgpt_flutter`). `synchronize` is `true` outside production — schema is auto-created from entities, but the DB and role still need to exist. `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` only matter on first boot (seed time, see `AiSeedService`).

### Admin (`chatgpt_admin/`)
```bash
pnpm --filter chatgpt_admin run dev         # next dev -p 3001
pnpm --filter chatgpt_admin run build
pnpm --filter chatgpt_admin run lint
pnpm --filter chatgpt_admin run typecheck
```

## Wiring you must do before things run

1. **AI 服务设置**: 首次登录后，在「我的 → AI 服务设置」为某个服务商填 API key、选模型，并选择「本地直连」或「后端代理」模式。设置页是多服务商管理（`AiProviderListPage` → `AiProviderDetailPage`），内置 16 家 OpenAI 兼容预设，可增删自定义服务商。**不再通过文件配置 API key**。
2. **Backend host**: All backend DAOs go through `BackendConfig` (`login_sdk/lib/dao/backend_host.dart`), resolved by a 4-level priority: (1) explicit `BackendConfig.host=` setter, (2) `--dart-define=BACKEND_HOST` / `BACKEND_HTTPS`, (3) `LoginSdkConfig.instance.baseUrl` if installed, (4) `autoDetect()` (Android emulator → `10.0.2.2:3000`, everything else → `localhost:3000`). Real devices: use `--dart-define` or assign in `main()` (the OHOS shell does the latter).
3. **iOS/Android on-device OCR**: `chatgpt_flutter/pubspec.yaml` has a `dependency_overrides` block pointing `google_mlkit_text_recognition` and `pdfx` to `../ohos_stubs/...` — a temporary workaround for the Apple-Silicon iOS simulator lacking arm64 ML Kit slices. **This disables OCR on ALL iOS/Android builds until you delete the block** (do so when building on a real device).
4. **Windows desktop**: SQLite uses `sqflite_common_ffi` (see `HiDBManager._init`); macOS/iOS/Android use the standard `openDatabase` path. Don't remove the `Platform.isWindows` branch.
5. **HarmonyOS**: Always `eval "$(mise activate ...)"` from `chatgpt_flutter_ohos/` before any `flutter` command — without it, the DevEco SDK / ohpm / hvigor binaries aren't on `PATH`.

## Architecture notes

### App initialization (`chatgpt_app_core/lib/app.dart:runChatGptApp`)
`MyApp` is wrapped in a `FutureBuilder<void>` over `doInit()` — UI shows a spinner until `LoginConfig.init`, `HiCache.preInit`, `HiAPICache.init`, and `AIConfigBuilder.init` have all run. After that it picks `LoginPage` vs `BottomNavigator` based on `LoginDao.getBoardingPass()`. Anything that needs config (HiCache, AIConfig, login state) must not be touched before `doInit` resolves. Both shells call `runChatGptApp()` — keep init logic here, not duplicated in the shells.

### Per-account SQLite (`chatgpt_app_core/lib/db/hi_db_manager.dart`)
`HiDBManager` is a multi-instance singleton keyed by db filename (one db per account hash). Schema version is `2`. **Messages now live in ONE unified table** — the old per-conversation `tb_<cid>` tables are gone; `_onUpgrade` automatically `INSERT…SELECT`s any legacy `tb_<cid>` tables into `tb_messages` and drops them on upgrade. Tables (created lazily by their DAOs):
- `tb_conversation_list` — conversation index, unique on `cid`. Stick/unstick is `stickTime` (millis since epoch, 0 = unpinned). Has an `assistantId` column (added via guarded `ALTER TABLE`) and a composite sort index `(stickTime, updateAt desc)`. Deleting a conversation now does `DELETE FROM tb_messages WHERE cid=?` (no more `DROP TABLE`).
- `tb_messages` — **all messages for all conversations**, distinguished by a `cid` column, with a composite index `(cid, id desc)`. Has `images` + `blocks` JSON columns (added via guarded `ALTER TABLE`); `MessageDao.saveMessageWithBlocks` / `getBlocksByCreatedAt` back the block renderer.
- `tb_favorite` — favorited messages (`FavoriteDao`).
- `tb_assistant` — saved assistants (`AssistantDao`): `id, name, emoji, prompt, model, useTools, tools (JSON tool-id list), createdAt, updatedAt`. The `tools` column is added via a guarded `ALTER TABLE` for backward-compat. No cascade on delete — a dangling `assistantId` falls back to "no assistant".
- `tb_kb_doc` + `tb_kb_chunk` — knowledge base (`KnowledgeDao`): document metadata + chunk bodies, index on `docId`. **NOT covered by backup** (see Backup section).

`HiDBManager.getAccountHash()` falls back to `"test"` when no account is logged in; guest mode uses the dedicated hash `"guest"`. `HiDBManager.test(db)` is a `@visibleForTesting` ctor that injects an opened `sqflite_common_ffi` database (bypasses platform init + the instance cache) — every DAO unit test uses it. `HiDBManager.closeAll()` is called on logout to release all open handles.

### Assistant system + tool-calling (`chatgpt_app_core/lib/chat/application/`)
An `AssistantModel` (`lib/model/assistant_model.dart`: name, emoji, system `prompt`, optional `model` override, `useTools` master switch, `toolIds` list) is bound to a conversation via `tb_conversation_list.assistantId`. `applyTo(AISettings)` clones settings with the model override applied so capability bits recompute. UI flow: `AssistantListPage` → `AssistantMarketPage` (45 built-in templates across 12 categories in `lib/data/builtin_assistants.dart`, e.g. 去AI味·人话改写 / 辩论红队 / 提示词优化师 / 角色扮演伙伴) → `AssistantEditPage` (templates clone as a new row, `id=null` → INSERT).

Tool calling evolved L1→L4 (design doc: `docs/assistant-tools-roadmap.md`):
- `ToolRegistry` (`tool_registry.dart`) holds the **12-tool catalog** (`ToolDescriptor` with `requiresSearchKey` / `sideEffect` flags). `ToolRegistry.fromAssistant(settings, toolIds, {forceWebSearch, actions})` assembles the runtime `ChatTool` set. Tool ids: `web_search`, `calculator`, `datetime`, `fetch_url` (L2 pure-Dart, no context needed); `search_chat_history`, `list_conversations`, `list_favorites`, `get_conversation_messages` (L3a read-only, **require a `ToolActionContext`**); `save_favorite`, `create_conversation`, `stick_conversation` (L3b write, `sideEffect=true`); `knowledge_search` (L4a RAG). Data tools (L3/L4) are silently skipped when no `ToolActionContext` is supplied.
- `ToolLoopRunner` (`tool_loop_runner.dart`) drives a streaming agentic loop, **max 5 rounds**: stream → `ToolCallAccumulator` reassembles fragmented SSE `tool_calls` deltas → `registry.execute()` (failures returned as text, never thrown) → append `assistant(tool_calls)` + `tool` messages → repeat; the last round sends no tools to force a direct answer. Web-search citations across rounds are de-duped by URL and emitted once.
- **Security guardrail**: write tools call `ToolActionContext.confirm(...)` first; if `confirm == null` (no UI context) it always returns `false`. This blocks prompt-injection from fetched web content from silently mutating local data. `conversation_page.dart` supplies the confirm callback as an `AlertDialog`.

The tool path is active only when `caps.tool` (model capability bit) **AND** stream mode **AND** `assistant.useTools` **AND** the registry is non-empty; otherwise it falls back to the web-search orchestration path.

### Knowledge base + OCR (`chatgpt_app_core/lib/chat/application/`, `lib/db/knowledge_dao.dart`)
Keyword-only RAG (no embeddings/vectors — "vector version left for L4b"). `KnowledgeChunker.split` aggregates paragraphs up to ~600 chars then hard-cuts oversized ones. `KnowledgeDao` stores docs/chunks in `tb_kb_doc` + `tb_kb_chunk` and `search()` does multi-term AND-`LIKE` (default 6 chunks). The `knowledge_search` tool wraps it. `KnowledgeBasePage` (entered from "我的 → 知识库") supports paste-text import and file import:
- `FileProcessor.extractTextForImport()` handles PDFs (syncfusion text layer, 20-page cap) + many text extensions.
- `OcrService` (`ocr_service.dart`) does on-device OCR via `google_mlkit_text_recognition` (`TextRecognitionScript.chinese`) for images, and rasterizes scanned PDFs page-by-page with `pdfx`. **Gated by `OcrService.isSupported` (Android/iOS only)**; `pdfNeedsOcr()` heuristic decides the syncfusion→OCR fallback. The file-import entry is hidden on OHOS (`Platform.operatingSystem == 'ohos'`).

### Conversation context + streaming pipeline (`chatgpt_app_core/lib/dao/completion_dao.dart`)
`CompletionDao.buildHistory` maps `MessageModel` → OpenAI `messages[]`, and additionally **reconstructs cross-turn state**: tool-call pairs (`assistant(tool_calls)` + `tool`) from `_toolHistory`, and file-extracted text appended to user messages from `_fileHistory`. `appendTurn` / `dropLastTurn` maintain these (and back the regenerate feature). The constructor defensively copies the message list to a growable list (it can be rebuilt from an unmodifiable `currentMessages`).

`CompletionDao.injectSystemPrompt` (static) **prepends `dateSystemPrompt()` ("当前日期：<yyyy-MM-dd>…") to EVERY request**, with the assistant prompt appended after — so the model never falls back to its training cutoff for time-relative queries. (Web-search intent classification deliberately skips this to avoid persona bias.)

The streaming path now uses `chatService.chatStreamEvents` (typed `StreamEvent`: reasoning/text/toolCall/toolResult/image/citation), **not** the old plain-text `chatStream`. It routes to `ToolLoopRunner` when the tool path is active, else to the web-search-augmented chat. `ConversationPage` dispatches events through `StreamDispatcher` into a `ChatBlockStore`; `BlockMessageContent` renders typed blocks (`Placeholder → Thinking / MainText / Code / Tool / Citation / Image / File / Error / Translation`) with `Selector`-based precision re-render (only the updating block rebuilds). A `_CharCount` `Selector` shows "字数：N" under assistant replies. The non-streaming path (`createCompletionsWithSearch`) has no tool loop.

**Chat UX gotchas worth preserving**:
- Conversation list AppBar title is "艾普"; new-conversation is an `IconButton(Icons.add)` in its actions (opens the assistant picker first).
- Conversation title is set lazily as `title ??= …last.content` (the first sent message); conversations with `null` title are not persisted.
- **Scroll-jump**: `ConversationPage` holds `ItemScrollController` + `ItemPositionsListener`; `util/scroll_jump.dart`'s pure `computeChatListEdges` drives the floating to-top/to-bottom buttons; the "对话目录" outline sheet loads all history then `scrollTo(index, alignment:0.08)`.
- **SPL first-message bug**: `scrollToLastMessage` is deferred via `addPostFrameCallback`, and `ChatList` guards out-of-range `itemBuilder` indices with `SizedBox.shrink` — both avoid the `-1` anchor crash/blank when the list goes 0→1 item.
- Regenerate: long-press the latest assistant bubble → "重新生成" deletes the old reply (DB/UI/blockStore), calls `dropLastTurn`, and re-sends the original user message.
- Attachments: images max 4, files max 10 (`MessageInputWidget._maxFiles`); both buttons hidden on OHOS.

### Web search (`chatgpt_app_core/lib/chat/application/search_orchestrator.dart`)
`SearchOrchestrator.run`: (1) a lightweight no-system-prompt chat classifies intent → `{needSearch, queries[]}` (fault-tolerant JSON parse, falls back to the raw prompt); (2) calls the provider (`web_search_provider.dart`, Tavily) in parallel per query, de-dupes by URL, caps total results; (3) `buildSearchContext` formats numbered results with a date anchor and passes them as `attachments.extraText`. Toggled by a `travel_explore` button in the input bar, persisted to `AISettings.webSearchEnabled`, only shown when `webSearchConfigured` (a search key is set).

### Multi-provider AI config + model capabilities
`AISettings.providers` is a `List<AiProvider>` (replaced the old openai/deepseek pair). `AISettings.fromJson` migrates the legacy format and appends any missing presets so upgrades surface new providers. `ProviderPresets` (`lib/data/provider_presets.dart`) defines 16 OpenAI-compatible presets (openai, deepseek default-enabled; + siliconflow, openrouter, groq, moonshot, zhipu, dashscope, mistral, grok, perplexity, gemini, together, stepfun, baichuan, ollama). `AiProvider.chatCompletionsUrl` derives the full URL from a bare host (handles `/v1`, full-URL passthrough, and the `#` suffix convention). `AISettingsDao` persists per-account in `HiCache` under `ai_settings_v1_<hash>` (migrates the legacy unsuffixed key on first load). `AISettingsProvider` (ChangeNotifier) wraps CRUD (add/remove/toggle/update + `saveQuietly`) with `resetToDefaults`/`reloadInstance` static hooks fired on logout/login.

`ModelCapabilities` (`lib/chat/domain/model_capabilities.dart`: `image / pdf / tool / reasoning / largeFileUpload / fileSizeLimits`) is the **single capability source** that gates the image/PDF attachment UI, tool-loop routing, and thinking-block rendering. `ModelCatalog.capabilitiesFor(modelId, providerCode)` starts from name-based heuristics, then applies the backend catalog as an **additive overlay** — remote bits can only turn capabilities ON, never OFF.

### Backup / restore + guest migration
`BackupService` (`lib/backup/backup_service.dart`) exports a zip (`manifest.json` formatVersion=1, `conversations.json`, `messages.json`, `assistants.json`, `favorites.json`, `settings.json`). It scrubs all provider API keys + search keys when `includeApiKeys=false`. Import is **overwrite-mode** (single transaction: delete all four tables then bulk insert), repairs dangling `assistantId` FKs, and rejects a newer `formatVersion` without touching data. `BackupService.restoreTick` (a `ValueNotifier<int>`) is bumped after import so `ConversationListPage` reloads without restart. **The knowledge base (`tb_kb_doc` / `tb_kb_chunk`) is NOT included in backups.** UI is `BackupRestorePage` (share_plus export, file_picker import — guarded on OHOS).

`GuestMigrationService` (`lib/migration/guest_migration_service.dart`): guest data lives under `accountHash='guest'`. On first login to a real account, `shouldPrompt()` checks a `guest_migrated_<hash>` done-key, and `mergeGuestData()` does a **row-level append merge** in one transaction — assistants re-inserted with fresh ids (recorded in a map), conversations re-inserted with `cid` conflicts remapped, messages' `cid` rewritten, favorites appended; AI settings imported only if the target account has none.

### Login + auth flow
- **Primary auth routes are `/uapi/auth/*`** (via `auth_kit_flutter`'s `AuthDao` / `AuthDaoBridge`): `login/password`, `login/code`, `code/send`, `register`, `reset-password`, `bind`, `huawei/*`, `apple/*`, plus `public-config`. The legacy `/uapi/user/login` + `/uapi/user/registration` still exist as `LoginRoutes` defaults but are no longer called by the login pages.
- **Guest login**: `LoginDao.loginAsGuest()` writes the sentinel token `LoginDao.kGuestToken='guest-mode'` + `extras={'accountHash':'guest','guest':true}` (no backend call); `LoginDao.isGuest()` checks it. The login page shows a "游客模式，暂不登录 →" link that bypasses the agreement checkbox. Guest features that need a real backend call must be UI-gated (boarding-pass `guest-mode` → backend 401).
- **Third-party login**: `IAppleSignInService` / `IHuaweiLoginService` interfaces (with `…Unavailable` stubs); the login page shows a platform-mandatory button (iOS=Apple, OHOS=Huawei, Android=Google stub) + a social-dot row. A `ThirdPartyLoginResult.needBinding` result pushes `BindIdentityPage`.
- **SDK injection**: `LoginConfig.init()` optionally takes a `LoginSdkConfig` (baseUrl / useHttps / `syncHeaders` / routes / `LoginResponseAdapter` / `TokenStorage` / `onLogoutNavigate`); defaults preserve the original imooc behavior. `hiHeaders()` merges `LoginSdkConfig.instance.syncHeaders()` (auth-token + course-flag) with the boarding-pass. `getAccountHash()` reads `profile['accountHash']` (default `userName.hashCode`, overridable via extras).
- **Hooks**: `LoginDao.addLoginHook` / `addLogoutHook` let the host app clear per-account SQLite state and re-init AI config on login/logout.
- Backend `auth.module` wires `AuthKitModule.forRootAsync` with `ChatGptUserResolver` (`IUserResolver`) + `ChatGptJwtSigner` (`IJwtSigner`, 30d user / 7d admin tokens). The `User` entity carries email/phone + huawei/apple identity columns. `@auth-kit` entities (`VerificationCode`, `SmtpProvider`, `AuthSettings`, `EmailTemplate`) are registered in `app.module.ts`.

### Networking
- OpenAI/DeepSeek direct calls → `openai_flutter/lib/http/ai_http.dart` with a per-instance `AIConfigBuilder`.
- Backend calls → `package:http` inside each Dao, with `hiHeaders()` from `login_sdk` providing auth bearer + boarding-pass + UA.
- Backend proxy completions: `POST /uapi/chat/completions` and `POST /uapi/chat/completions/stream` (JWT required, OpenAI Chat Completions body; `tools[]` is whitelisted and forwarded transparently for function-calling). The stream proxy sets `stream_options.include_usage` and pipes SSE blocks through.
- Response caching is generic and lives in `HiAPICache` (key = full URL, stored in `HiCache` as `[timestamp, body]`). DAOs opt in via the `hitCache` callback pattern (see `NoticeDao`).

### State management
`provider` only. The single global provider is `ThemeProvider` registered in `lib/provider/hi_provider.dart`; `AISettingsProvider` and `ChatBlockStore` are scoped (e.g. `ChangeNotifierProvider.value` per conversation), everything else is local widget state. No Bloc / Riverpod despite course chapters discussing them.

### Backend routes (all under `uapi/`)
- **User** (legacy): `POST /uapi/user/login`, `POST /uapi/user/registration`, `POST /uapi/user/forgot-password/request|confirm`, `GET /uapi/user/register-page` (server-rendered HTML).
- **Auth** (auth-kit, current primary): `POST /uapi/auth/login/password|login/code|code/send|register|reset-password|bind|huawei/*|apple/*`, `GET /uapi/auth/public-config`.
- **Chat**: `GET|POST /uapi/chat/conversations`, `PATCH|DELETE /uapi/chat/conversations/:id`, `GET|POST /uapi/chat/conversations/:id/messages` — **all `AdminGuard`** (these back the admin AI Chat panel, not the app). `POST /uapi/chat/completions[/stream]` are `JwtGuard` and persist **only token usage** (fire-and-forget), not messages.
- **AI public**: `GET /uapi/ai/catalog` (`JwtGuard`, gated by the `catalogPublic` global flag) — enabled providers + models with the four capability bits + global defaults + avatar URL.
- **AI admin** (`AdminGuard`): `GET|POST|PATCH|DELETE /uapi/admin/ai/providers`, `POST /uapi/admin/ai/providers/:id/test` (connection test), `GET|POST|PATCH|DELETE /uapi/admin/ai/models`, `POST /uapi/admin/ai/models/:id/set-default`, `GET|PATCH /uapi/admin/ai/global`, `POST /uapi/admin/ai/global/avatar` (base64 image → `uploads/`, served at `/uploads/`).
- **Admin auth**: `POST /uapi/admin/login`, `GET /uapi/admin/me`, `POST /uapi/admin/change-password`.
- **Admin users**: `GET|PATCH|DELETE /uapi/admin/users[/:id]`, `POST /uapi/admin/users/:id/reset-password`, `…/unbind-email|unbind-phone|unbind-huawei|unbind-apple`.
- **Admin banners / versions**: `GET|POST|PATCH|DELETE /uapi/admin/banners[/:id]` and `…/versions[/:id]`.
- **Admin usage analytics**: `GET /uapi/admin/usage/list|summary|series|by-provider|top-users|export` (CSV, BOM-prefixed).
- **Misc**: `GET /uapi/notice/banner`, `GET /uapi/checkUpdate`, `GET /healthz` (TypeORM ping, not under `uapi/`).
- CORS origins are configurable via `CORS_ORIGINS` env (comma-separated). `ChatService.resolveProvider` does a 3-tier model→provider lookup (exact model row → `modelPrefixes` prefix → global default) cached 30s in `ProviderCacheService` (invalidated on any provider/model mutation). `AiSeedService` seeds 2 providers + 8 models with capability bits on first boot if empty.

### Admin console (`chatgpt_admin/`)
App Router under `src/app/`, a single `(dashboard)` route group behind an auth guard. `next.config.ts` rewrites `/api/* → NEXT_PUBLIC_BACKEND/uapi/*` (so axios uses `baseURL='/api'`, no CORS, and DAOs omit the `/uapi` prefix) and `/uploads/*` direct. **`typescript.ignoreBuildErrors=true` is intentional** (HeroUI `SelectItem` vs React 19 JSX type incompatibility) — don't "fix" it. Sections: Dashboard (recharts KPI/trend/leaderboard), Users, Banners, Versions, Usage (CSV export), AI providers/models/global (the **model capability-bit editor** — `supportsVision/supportsTool/supportsReasoning/supportsPdf` — are additive overrides, false does NOT force-disable on the client), an embedded AI Chat panel (`/ai-chat`, SSE + Web Speech mic), and a full Auth admin (SMTP providers as 3 fixed slots `generic`/`aliyun_dm`/`tencent_ses` with 19 presets, verification-code log, auth settings, email templates with live preview). The 3 SMTP rows must be seeded manually (backend exposes update/activate/test, no create).

### HarmonyOS + platform build specifics
- OHOS-impl plugins are swapped via `dependency_overrides` to `openharmony-sig` gitee forks. Don't bump these to upstream stock versions — the OHOS impls don't exist there.
- Plugins with no OHOS fork are overridden to **local no-op stubs under `ohos_stubs/`** (same package name, Dart-only; methods throw `UnsupportedError` or return null ≈ cancel): `google_mlkit_text_recognition` + `pdfx` (OCR — guarded by `OcrService.isSupported`) and `file_picker` (guarded at each call site by `Platform.operatingSystem == 'ohos'`, which hides the file-pick entry — backup import/export, chat attachments, knowledge-base file import). The OCR two also serve **double duty as the iOS-simulator workaround** referenced from `chatgpt_flutter/pubspec.yaml`. Keep a stub's public API in sync with whatever the core calls.
- **iOS** deploy target is `15.5` (required by `google_mlkit_commons`); **macOS** is `11.0` (required by `speech_to_text`). macOS adds `com.apple.security.device.audio-input` + `…personal-information.speech-recognition` entitlements and `NSSpeechRecognitionUsageDescription` / `NSMicrophoneUsageDescription` Info.plist strings; iOS Info.plist has camera/photo/speech/microphone usage strings.
- **Android**: `compileSdk 36`, `targetSdk 35`, `ndkVersion 27.0.12077973`. `proguard-rules.pro` has ML Kit R8 `-dontwarn` rules for non-Latin recognizer classes missing from the release APK. **Release currently uses `signingConfigs.debug`** and `applicationId` is still `com.example.chatgpt_flutter` — see `docs/android-release-signing.md` before store submission.
- Build artifacts (`.dart_tool/`, `build/`) are gitignored at the repo level; do not re-track them.
- The OHOS shell sets `BackendConfig.host` directly to a LAN IP because OHOS devices can't reach the host's `localhost`.

## Conventions worth preserving

- Path dependencies use `../<package>` — keep all Flutter packages as repo-root siblings; don't move them into subfolders.
- Comments in Dart files are predominantly Chinese. Match the existing language when adding comments.
- DAOs follow an "interface + impl in one file" pattern (e.g. `IConversationList` / `ConversationListDao`). Keep that shape for new tables.
- `ITable` is a marker mixin in `lib/db/table_name.dart`; every Dao that owns a table implements it, assigns `tableName` in its constructor, and runs `CREATE TABLE IF NOT EXISTS` there. Schema additions to existing tables go through a guarded `ALTER TABLE ADD COLUMN` (swallow "duplicate column") for backward-compat upgrades.
- New DAO unit tests use `HiDBManager.test(db)` with `sqflite_common_ffi` (in-memory or temp-file) — see `guest_migration_test`, `backup_test`, `knowledge_base_test`, `provider_presets_test`, `model_capabilities_test`.
- Model capability bits are **additive**: client name-heuristics OR-ed with backend catalog bits; setting a bit false in admin never force-disables.
- When editing login chrome (colors / spacing across login + register + forgot-password), go through `LoginPalette` — derive new colors there so all three pages stay coherent across bg variants.

## docs/ inventory

- `docs/assistant-tools-roadmap.md` — L1–L4a tool-evolution design + implementation records + per-phase test counts.
- `docs/flutter-migration-guide.md` — Cherry Studio → Flutter migration spec (8 phases, all complete).
- `docs/branch-review.md` — reviewer navigation guide for the block-message-system branch.
- `docs/next-session-prompt.md` — session-continuity prompt + legacy-item tracker (13 items, 10 done / 3 open).
- `docs/android-release-signing.md` — how to generate a release keystore and replace `signingConfigs.debug`.
