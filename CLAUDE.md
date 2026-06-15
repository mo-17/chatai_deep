# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Multi-package monorepo: a Flutter ChatGPT client (Android/iOS/desktop + a separate HarmonyOS shell) plus a NestJS backend and a Next.js admin. Flutter packages live as siblings under the repo root and are wired together via `pubspec.yaml` `path:` dependencies; Node packages are joined by a root `pnpm-workspace.yaml`.

**App shells** (entry points — each has its own `lib/main.dart` and platform folders):
- `chatgpt_flutter/` — Android / iOS / desktop shell. Depends directly on `chatgpt_app_core` + `login_sdk`.
- `chatgpt_flutter_ohos/` — HarmonyOS shell. Same core, but uses `dependency_overrides` to pull OHOS-SIG forks of `sqflite`, `sqflite_common_ffi`, `path_provider`, `url_launcher`, `shared_preferences`. `package_info_plus` has no OHOS impl — handled by runtime branch.

**Shared core**:
- `chatgpt_app_core/` — all business code (pages, DAOs, DB, widgets, providers). Entry point is `lib/app.dart:runChatGptApp`; both app shells just call it. Transitively pulls `login_sdk`, `hi_download`, `chat_message`, `openai_flutter` — these don't need to be listed in the shell's `pubspec.yaml`, but they DO have to exist as siblings on disk for `pub get` to resolve.

**Login + auth**:
- `login_sdk/` — login / register / forgot-password UI + `LoginDao` (boarding pass, account hash) + `hiHeaders()` for backend calls + `BackendConfig` (host/scheme). Three pages share a single `LoginPalette` so chrome colors react to the active background. Plan G+ ships 20 immersive bg variants (`LoginBgVariant`) — both "tabs" (clean) and "bg" (immersive + glass card) styles.
- `auth_kit_flutter/` — reusable auth widgets (verification code, country code picker, etc.). Pulled in by `login_sdk` (not the shell). Backend counterpart is the `@auth-kit` package consumed by `chatgpt_backend`.

**Other Flutter siblings**:
- `openai_flutter/` — direct OpenAI/DeepSeek SDK (`AIConfigBuilder`, `AICompletion`, `AIHttp`). Used when "本地直连" mode is selected; "后端代理" mode bypasses this in favor of `/uapi/chat/completions`.
- `chat_message/` — chat-bubble UI + `ChatController` driving a `Stream<List<MessageModel>>`.
- `hi_download/` — APK download helper used by the in-app updater.

**Server side**:
- `chatgpt_backend/` — NestJS 11 + TypeORM + Postgres. Modules: `user`, `auth` (JWT guards, bcrypt, admin guard), `chat` (conversation + message + usage entities, OpenAI-compatible completions endpoint), `ai` (global config / providers / models + admin CRUD + public lookup), `admin` (banner / version / user / usage / auth admin), `notice`, `update`, `health`, `test` (auto-disabled in production). Pino logger, throttler guard, env-driven config.
- `chatgpt_admin/` — Next.js 16 + React 19 admin console. **Read `chatgpt_admin/AGENTS.md` first** — it warns about breaking Next.js changes vs training data. UI on HeroUI (migrated from NextUI) + Tailwind v4. Data layer: TanStack Query + axios + Zod + React Hook Form + Zustand.

**Demos (not depended on)**:
- `chat_db/`, `flutter_network/` — standalone course demos. Don't assume edits affect the app.

## Common commands

### Flutter Android / iOS / desktop (`chatgpt_flutter/`)
```bash
flutter pub get         # also run inside each path-dep package after first clone
flutter run             # picks up the connected device
flutter test            # widget tests under test/
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

DB config is env-driven (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`) with local defaults (`localhost:5432`, user `huangzhibin`, db `chatgpt_flutter`). `synchronize` is `true` outside production — schema is auto-created from entities, but the DB and role still need to exist.

### Admin (`chatgpt_admin/`)
```bash
pnpm --filter chatgpt_admin run dev         # next dev -p 3001
pnpm --filter chatgpt_admin run build
pnpm --filter chatgpt_admin run lint
pnpm --filter chatgpt_admin run typecheck
```

## Wiring you must do before things run

1. **AI 服务设置**: 首次登录后，在「我的 → AI 服务设置」填入 OpenAI / DeepSeek 的 API key，并选择「本地直连」或「后端代理」模式。**不再通过文件配置 API key**。
2. **Backend host**: All backend DAOs go through `BackendConfig` (`login_sdk/lib/dao/backend_host.dart`). It auto-detects per platform — Android emulator → `10.0.2.2:3000`, iOS sim / macOS / Windows / Linux / web → `localhost:3000`. Override for real devices via either:
   - `flutter run --dart-define=BACKEND_HOST=192.168.x.x:3000 --dart-define=BACKEND_HTTPS=false`
   - Direct assign in `main()`: `BackendConfig.host = '...'` (the OHOS shell does this for LAN testing).
3. **Windows desktop**: SQLite uses `sqflite_common_ffi` (see `HiDBManager._init`); macOS/iOS/Android use the standard `openDatabase` path. Don't remove the `Platform.isWindows` branch.
4. **HarmonyOS**: Always `eval "$(mise activate ...)"` from `chatgpt_flutter_ohos/` before any `flutter` command — without it, the DevEco SDK / ohpm / hvigor binaries aren't on `PATH`.

## Architecture notes

### App initialization (`chatgpt_app_core/lib/app.dart:runChatGptApp`)
`MyApp` is wrapped in a `FutureBuilder<void>` over `doInit()` — UI shows a spinner until `LoginConfig.init`, `HiCache.preInit`, `HiAPICache.init`, and `AIConfigBuilder.init` have all run. After that it picks `LoginPage` vs `BottomNavigator` based on `LoginDao.getBoardingPass()`. Anything that needs config (HiCache, AIConfig, login state) must not be touched before `doInit` resolves. Both shells call `runChatGptApp()` — keep init logic here, not duplicated in the shells.

### Per-account SQLite (`chatgpt_app_core/lib/db/hi_db_manager.dart`)
`HiDBManager` is a multi-instance singleton keyed by db filename. Each Dao opens its own table inside the manager's `Database`. Tables created on demand:
- `tb_conversation_list` — conversation index, unique on `cid`. Stick/unstick is `stickTime` (millis since epoch, 0 = unpinned).
- `tb_<cid>` — **one message table per conversation**, named via `MessageDao.tableNameByCid(cid)`. Deleting a conversation drops the corresponding message table. New tables are created lazily by `MessageDao`'s constructor, so a re-arrived message after delete may briefly hit "no such table" by design.
- `tb_favorite` — favorited messages (`FavoriteDao`).

`HiDBManager.getAccountHash()` falls back to `"test"` when no account is logged in — pre-login data is shared.

### Conversation context (`chatgpt_app_core/lib/dao/completion_dao.dart`)
Chat history is sent to the AI as a standard OpenAI `messages[]` array (`_buildHistory()` maps `MessageModel` → `{role, content}`). Non-streaming and streaming paths share this format via `ChatService.chat` / `ChatService.chatStream`. Backend-proxy mode also stores conversations/messages server-side in `chat.module` (so the same conversation surfaces via `/uapi/chat/conversations`).

### Login + auth flow
- Flutter `login_sdk` posts to `/uapi/user/login` / `/uapi/user/registration` (also forgot-password `/request` + `/confirm`).
- Backend `auth.module` issues JWT via `chatgpt-jwt-signer`; `jwt.guard.ts` / `admin.guard.ts` gate protected endpoints; `chatgpt-user.resolver.ts` extracts the user from the bearer token.
- `auth_kit_flutter` (pulled by `login_sdk`) provides the verification-code / country-code / third-party-binding widgets. Backend counterpart is `@auth-kit` providing four entities: `VerificationCode`, `SmtpProvider`, `AuthSettings`, `EmailTemplate` (registered in `app.module.ts`).

### Networking
- OpenAI/DeepSeek direct calls → `openai_flutter/lib/http/ai_http.dart` with per-instance `AIConfigBuilder`.
- Backend calls → `package:http` inside each Dao, with `hiHeaders()` from `login_sdk` providing auth bearer + UA.
- Backend proxy completions: `POST /uapi/chat/completions` and `POST /uapi/chat/completions/stream` (JWT required, OpenAI Chat Completions body).
- Response caching is generic and lives in `HiAPICache` (key = full URL, stored in `HiCache` as `[timestamp, body]`). DAOs opt in via the `hitCache` callback pattern (see `NoticeDao`).

### State management
`provider` only. The single global provider is `ThemeProvider` registered in `lib/provider/hi_provider.dart`; everything else is local widget state. No Bloc / Riverpod despite course chapters discussing them.

### Backend routes (all under `uapi/`)
- **User**: `POST /uapi/user/login`, `POST /uapi/user/registration`, `POST /uapi/user/forgot-password/request`, `POST /uapi/user/forgot-password/confirm`, `GET /uapi/user/register-page` (server-rendered HTML).
- **Chat**: `GET|POST /uapi/chat/conversations`, `GET|POST /uapi/chat/conversations/:id/messages`, `POST /uapi/chat/completions[/stream]`.
- **AI** (public lookup): `GET /uapi/ai/...` for public provider/model metadata.
- **AI admin**: `/uapi/admin/ai/providers`, `/uapi/admin/ai/models`, `/uapi/admin/ai/global`.
- **Admin**: `/uapi/admin/users`, `/uapi/admin/banners`, `/uapi/admin/versions`, `/uapi/admin/usage`, plus `/uapi/admin` for admin auth.
- **Misc**: `GET /uapi/notice/banner`, `GET /uapi/checkUpdate`, `GET /healthz` (not under `uapi/`).
- CORS is enabled globally in `main.ts`.

### HarmonyOS variant specifics (`chatgpt_flutter_ohos/`)
- All platform-impl plugins that don't yet have OHOS support are swapped via `dependency_overrides` to the `openharmony-sig` forks on gitee. Don't bump these to upstream stock versions — the OHOS impls don't exist there.
- Plugins with **no** OHOS fork either (OCR: `google_mlkit_text_recognition`, `pdfx`) are overridden to **local no-op stub packages** under `ohos_stubs/` (same package name, Dart-only API that throws `UnsupportedError`). They keep the shared core compiling on OHOS; the feature is runtime-guarded (`OcrService.isSupported` → Android/iOS only). Keep a stub's public API in sync with whatever the core actually calls.
- Build artifacts (`.dart_tool/`, `build/`) are gitignored at the repo level; do not re-track them.
- The shell sets `BackendConfig.host` directly to a LAN IP because OHOS devices can't reach the host's `localhost`.

## Conventions worth preserving

- Path dependencies use `../<package>` — keep all Flutter packages as repo-root siblings; don't move them into subfolders.
- Comments in Dart files are predominantly Chinese. Match the existing language when adding comments.
- DAOs follow an "interface + impl in one file" pattern (e.g. `IConversationList` / `ConversationListDao`). Keep that shape for new tables.
- `ITable` is a marker mixin in `lib/db/table_name.dart`; every Dao that owns a table implements it, assigns `tableName` in its constructor, and runs `CREATE TABLE IF NOT EXISTS` there.
- When editing login chrome (colors / spacing across login + register + forgot-password), go through `LoginPalette` — derive new colors there so all three pages stay coherent across bg variants.
