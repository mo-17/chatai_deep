# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This is a multi-package monorepo for a Flutter ChatGPT client (course project from imooc.com class 672) plus its NestJS backend. Packages live as siblings under the repo root and are wired together via `pubspec.yaml` `path:` dependencies.

- `chatgpt_flutter/` — main Flutter app (entry point). Depends via local path on `login_sdk`, `hi_download`, `chat_message`, `openai_flutter`. Pull all five into the same parent directory before running.
- `openai_flutter/` — OpenAI Chat Completions SDK (`AIConfigBuilder`, `AICompletion`, `AIHttp`).
- `chat_message/` — chat-bubble UI + `ChatController` that drives a `Stream<List<MessageModel>>` for the message list.
- `login_sdk/` — login/registration UI + `LoginDao` (account hash, boarding pass) + `hiHeaders()` for backend calls.
- `hi_download/` — APK download helper used by the in-app updater.
- `chatgpt_backend/` — NestJS 11 + TypeORM + Postgres backend (modules: `user`, `notice`, `update`, `test`).
- `chat_db/`, `flutter_network/` — standalone demo packages from the course, **not** depended on by the main app. Don't assume edits here affect `chatgpt_flutter`.

## Common commands

### Flutter app (`chatgpt_flutter/`)
```bash
flutter pub get         # also run inside each path-dependency package after first clone
flutter run             # picks up the connected device
flutter test            # widget tests live under test/
flutter analyze         # uses analysis_options.yaml (flutter_lints)
```
Single test: `flutter test test/widget_test.dart --plain-name "<test name>"`.

### Backend (`chatgpt_backend/`)
The repo root is a **pnpm workspace** (`pnpm-workspace.yaml`) containing `chatgpt_backend` and `chatgpt_admin`. Run `pnpm install` once at the root — it sets up both Node packages and shares dependencies via the central pnpm store.
```bash
pnpm install            # run from repo root, installs backend + admin together
pnpm --filter chatgpt_backend run start:dev   # or: cd chatgpt_backend && pnpm start:dev
pnpm --filter chatgpt_backend run lint
pnpm --filter chatgpt_backend test
pnpm --filter chatgpt_backend run test:e2e
```
Single test: `pnpm --filter chatgpt_backend exec jest <pattern>` or `pnpm --filter chatgpt_backend test -- -t "<test name>"`.

### Admin (`chatgpt_admin/`)
```bash
pnpm --filter chatgpt_admin run dev    # next dev -p 3001
pnpm --filter chatgpt_admin run build
```

The backend expects a local Postgres (`host: localhost`, `port: 5432`, `username: huangzhibin`, no password, db `chatgpt_flutter`) hardcoded in `src/app.module.ts` with `synchronize: true` — schema is auto-created from entities, but you need the DB and role to exist.

## Wiring you must do before the app runs

1. **AI 服务设置**: 首次运行登录后，在「我的 → AI 服务设置」页面填入 OpenAI 或 DeepSeek 的 API key，并选择本地/后端模式。不再通过文件配置 API key。
2. **Backend host**: Flutter DAOs that hit the backend (`NoticeDao`, `ApkUpdateDao`, login) hardcode `localhost:3000` via `BackendConst.host`. When testing on a real device you'll need to change those URIs or run the app on the desktop/simulator.
3. **Windows desktop**: SQLite is initialized via `sqflite_common_ffi` (see `HiDBManager._init`); on macOS/iOS/Android the standard `openDatabase` path is used. Do not remove the `Platform.isWindows` branch.

## Architecture notes

### App initialization (`chatgpt_flutter/lib/main.dart`)
`MyApp` is wrapped in a `FutureBuilder<void>` over `doInit()` — the UI shows a spinner until `LoginConfig.init`, `HiCache.preInit`, `HiAPICache.init`, and `AIConfigBuilder.init` have all run. After that it picks `LoginPage` vs `BottomNavigator` based on `LoginDao.getBoardingPass()`. Anything that needs config (HiCache, AIConfig, login state) must not be touched before `doInit` resolves.

### Per-account SQLite (`lib/db/hi_db_manager.dart`)
`HiDBManager` is a multi-instance singleton keyed by db filename. Each Dao opens its own table inside the manager's `Database`. Tables created on demand:
- `tb_conversation_list` — conversation index, with a unique index on `cid`. Stick/unstick is `stickTime` (millis since epoch, 0 = unpinned).
- `tb_<cid>` — **one message table per conversation**, named via `MessageDao.tableNameByCid(cid)`. Deleting a conversation drops the corresponding message table. New tables are created lazily by `MessageDao`'s constructor, so a re-arrived message after delete may briefly hit "no such table" by design.
- `tb_favorite` — favorited messages (`FavoriteDao`).

`HiDBManager.getAccountHash()` falls back to `"test"` when no account is logged in — this makes it possible to run the app pre-login but means data written then is shared.

### Conversation context (`lib/util/conversation_context_helper.dart`, `lib/dao/completion_dao.dart`)
Chat history is sent to OpenAI as a `Q:/A:` transcript appended to the new prompt. `CompletionDao.createCompletions` strips the leading `A:` and the first `\n\n` from the model reply before storing it. If you change the prompt format, update both `getPromptContext` and the response-stripping code together.

### Networking
- OpenAI/DeepSeek calls go through `openai_flutter/lib/http/ai_http.dart` with per-instance `AIConfigBuilder`.
- Backend calls go through `package:http` directly inside each Dao with `hiHeaders()` from `login_sdk` for auth/UA.
- Backend proxy endpoint: `POST /uapi/chat/completions` (JWT required, body is OpenAI Chat Completions format).
- Response caching is generic and lives in `HiAPICache` (keyed by full URL, stored in `HiCache` as `[timestamp, body]`). DAOs opt in via the `hitCache` callback pattern (see `NoticeDao`).

### State management
`provider` only. The single global provider is `ThemeProvider` registered in `lib/provider/hi_provider.dart`; everything else is local widget state. There is no Bloc/Riverpod despite course chapters discussing them.

### Backend routes (all under `uapi/`)
- `POST /uapi/user/login`, `POST /uapi/user/registration` — accept body **or** query string for `userName`/`password`.
- `GET  /uapi/user/register-page` — server-rendered HTML registration form (loaded inside the app via `url_launcher`).
- `GET  /uapi/notice/banner` — paginated banners (`pageIndex`, `pageSize` are accepted but currently ignored).
- `GET  /uapi/checkUpdate` — APK update check.
- CORS is enabled globally in `main.ts`.

## Conventions worth preserving

- Path dependencies in `pubspec.yaml` use `../<package>` — keep all five Flutter packages siblings.
- Comments in Dart files are predominantly Chinese. Match the existing language when adding comments.
- DAOs follow an "interface + impl in one file" pattern (e.g. `IConversationList` / `ConversationListDao`). Keep that shape when adding new tables.
- `ITable` is a marker mixin from `lib/db/table_name.dart`; every Dao that owns a table implements it and assigns `tableName` in its constructor — also where the `CREATE TABLE IF NOT EXISTS` runs.
