# 艾普 · 多端 AI 聊天助手（chatai_deep）

一个全栈、跨端的 AI 聊天应用单仓库（monorepo）：**Flutter 客户端**（Android / iOS / 桌面 + 独立的 HarmonyOS 壳）+ **NestJS 后端** + **Next.js 管理后台**。
从一个 ChatGPT 课程项目演进而来，现已扩展为支持多服务商、工具调用（Agent）、本地知识库、联网搜索与多渠道登录的完整产品。

> 客户端会话列表的品牌名为「**艾普**」。

---

## ✨ 功能特性

- **多服务商接入**：内置 16 家 OpenAI 兼容服务商预设（OpenAI / DeepSeek / 硅基流动 / OpenRouter / Groq / 月之暗面 / 智谱 / 通义 / Mistral / Grok / Perplexity / Gemini / Together / 阶跃 / 百川 / Ollama），可改 key/host、增删模型、新建自定义服务商。支持「本地直连」与「后端代理」两种模式。
- **流式对话 + 分块渲染**：助手回复以「思考 / 正文 / 工具调用 / 引用 / 图片 / 文件 / 错误」等**类型化区块**实时渲染，思考过程可折叠，回复底部显示生成字数。
- **助手系统 + 工具调用（L1–L4）**：可为助手绑定工具，模型按需多轮调用（计算器 / 日期时间 / 网页抓取 / 历史检索 / 收藏 / 新建会话 / 知识库检索等），写操作需**人工确认**。内置 45 个助手模板、12 个分类（含「去 AI 味·人话改写」「辩论红队」「提示词优化师」「角色扮演伙伴」等）。
- **本地知识库（轻量 RAG）**：粘贴文本或导入 PDF / 文本 / 图片（端上 OCR），关键词检索后由 `knowledge_search` 工具喂给模型。
- **联网搜索**：意图识别 → 并行检索（Tavily 等）→ 注入当前日期，让模型正确理解「今天 / 最近」。
- **多渠道登录 + 游客模式**：邮箱密码 / 邮箱验证码 / 手机短信 / 第三方（Apple、华为）；**游客模式**免登录即用，登录后一次性行级合并游客数据。
- **备份与恢复**：会话 / 消息 / 助手 / 收藏 + AI 设置一键导出为 zip，可选脱敏 API Key。
- **真正多端**：同一套核心代码跑在 Android / iOS / macOS / Windows / Linux，外加独立的 **HarmonyOS** 壳。
- **管理后台**：用量分析（KPI + 图表 + CSV 导出）、用户管理、Banner / 版本、AI 服务商与模型（含能力位编辑）、SMTP / 验证码 / 鉴权策略，以及内嵌的 AI Chat 调试面板。

---

## 🗂 仓库结构

Flutter 各包以**仓库根目录同级**的形式存在，通过 `pubspec.yaml` 的 `path:` 依赖互联；Node 各包由根 `pnpm-workspace.yaml` 串联。

| 包 / 目录 | 角色 |
| --- | --- |
| `chatgpt_flutter/` | **Android / iOS / 桌面壳**。`main.dart` 调 `chatgpt_app_core` 的 `runChatGptApp()`。 |
| `chatgpt_flutter_ohos/` | **HarmonyOS 壳**。同一核心，用 `dependency_overrides` 换 OHOS-SIG 分支 + 本地 stub。 |
| `chatgpt_app_core/` | **共享核心**：所有页面、DAO、数据库、组件、Provider，以及助手 / 工具 / 知识库 / 备份逻辑。 |
| `login_sdk/` | 登录 / 注册 / 找回密码 / 游客登录 + `BackendConfig`（host/scheme）+ `hiHeaders()`。 |
| `auth_kit_flutter/` | 复用鉴权组件（验证码、国家码、第三方绑定），驱动 `/uapi/auth/*`。 |
| `openai_flutter/` | OpenAI / DeepSeek 直连 SDK（「本地直连」模式）。 |
| `chat_message/` | 聊天气泡 UI + `ChatController`（`ScrollablePositionedList`）。 |
| `hi_download/` | 应用内更新的 APK 下载助手。 |
| `chatgpt_backend/` | **NestJS 11 + TypeORM + Postgres** 后端，所有接口在 `uapi/` 前缀下。 |
| `chatgpt_admin/` | **Next.js 16 + React 19** 管理后台（HeroUI + Tailwind v4）。 |
| `ohos_stubs/` | OHOS / iOS 模拟器用的本地 stub 包（`file_picker`、`google_mlkit_text_recognition`、`pdfx`）。 |
| `chat_db/`、`flutter_network/` | 课程演示，不被主工程依赖。 |

---

## 🚀 快速开始

> 首次 clone 后，需保证所有 Flutter 包都在同一父目录下，并在每个 `path:` 依赖包内各跑一次 `flutter pub get`。

### Flutter（Android / iOS / 桌面）
```bash
cd chatgpt_flutter
flutter pub get
flutter run            # 连接的设备
flutter test           # test/ 下的单测
flutter analyze
```

### Flutter（HarmonyOS）
```bash
cd chatgpt_flutter_ohos
eval "$(mise activate zsh --shims)"   # 必须先激活，否则 DevEco SDK 不在 PATH
flutter pub get
flutter build hap
flutter run
```

### 后端（NestJS）
仓库根是 **pnpm workspace**，在根目录跑一次 `pnpm install` 同时装好后端与后台。
```bash
pnpm install                                       # 在仓库根
pnpm --filter chatgpt_backend run start:dev        # nest start --watch
pnpm --filter chatgpt_backend test
```
DB 由环境变量驱动（`DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME`，本地默认 `localhost:5432` / `chatgpt_flutter`）。非生产环境 `synchronize=true`，但库与角色仍需先存在。

### 管理后台（Next.js）
```bash
pnpm --filter chatgpt_admin run dev    # next dev -p 3001
```
唯一环境变量 `NEXT_PUBLIC_BACKEND`（默认 `http://localhost:3000`）；前端经 `/api/* → 后端 /uapi/*` 的 rewrite 访问后端。

---

## ⚙️ 运行前必须的配置

1. **AI 服务设置**：首次登录后，在「我的 → AI 服务设置」里为某个服务商填 API Key、选模型，并选择「本地直连」或「后端代理」。**不再通过文件配置 Key**。
2. **后端 Host**：所有后端 DAO 走 `BackendConfig`（`login_sdk/lib/dao/backend_host.dart`），按优先级解析：显式 setter > `--dart-define=BACKEND_HOST/BACKEND_HTTPS` > `LoginSdkConfig` 注入 > 自动探测（Android 模拟器 `10.0.2.2:3000`，其余 `localhost:3000`）。真机经 `--dart-define` 或 `main()` 里直接赋值覆盖。
3. **iOS / Android 端上 OCR**：`chatgpt_flutter/pubspec.yaml` 的 `dependency_overrides` 暂时把 `google_mlkit_text_recognition`、`pdfx` 指向 `ohos_stubs/`（规避 Apple Silicon iOS 模拟器缺 arm64 预编译）。**真机构建若要启用 OCR，需删掉该 override 块**。
4. **HarmonyOS**：在 `chatgpt_flutter_ohos/` 下任何 `flutter` 命令前都要先 `eval "$(mise activate ...)"`。

---

## 🧭 架构速览

更详细的工程约定与「踩坑点」见仓库根的 **[CLAUDE.md](./CLAUDE.md)**。要点：

- **每账号独立 SQLite**（`HiDBManager`，按 db 文件名做多实例单例）。统一消息表 `tb_messages`（按 `cid` 区分会话，schema v2 已从旧的 `tb_<cid>` 自动迁移）；另有 `tb_conversation_list` / `tb_favorite` / `tb_assistant` / `tb_kb_doc` / `tb_kb_chunk`。游客数据存在 `accountHash='guest'` 分区。
- **对话编排**在 `chatgpt_app_core/lib/dao/completion_dao.dart`：构建 OpenAI `messages[]` 历史（含工具调用对与文件抽取文本的跨轮重建）、**每轮都注入当前日期系统提示**、流式走 `chatStreamEvents` 并在模型支持工具时路由到 `ToolLoopRunner`（最多 5 轮）。
- **状态管理**只用 `provider`；唯一全局 Provider 是 `ThemeProvider`，其余为局部状态。
- **后端**所有路由在 `uapi/` 下，JWT / Admin 守卫；AI 模块支持多服务商、模型能力位下发与连通性测试。

---

## 📚 docs/ 文档索引

| 文件 | 内容 |
| --- | --- |
| `docs/assistant-tools-roadmap.md` | 助手工具演进（L1–L4a）设计与实现记录、各阶段测试数。 |
| `docs/flutter-migration-guide.md` | Cherry Studio → Flutter 迁移规格（8 个阶段，已全部完成）。 |
| `docs/branch-review.md` | 区块消息系统分支的评审导航指南。 |
| `docs/next-session-prompt.md` | 会话延续提示 + 遗留项清单（13 项，10 完成 / 3 待办）。 |
| `docs/android-release-signing.md` | 生成 release 签名密钥并替换 `signingConfigs.debug` 的步骤。 |

---

## 🖥 平台支持矩阵

| 能力 | Android | iOS | macOS / Win / Linux | HarmonyOS |
| --- | :-: | :-: | :-: | :-: |
| 对话 / 助手 / 工具 / 知识库（文本） | ✅ | ✅ | ✅ | ✅ |
| 端上 OCR（图片 / 扫描件 PDF） | ✅\* | ✅\* | ❌ | ❌(stub) |
| 文件选择（备份导入、附件、知识库文件） | ✅ | ✅ | ✅ | ❌(stub) |
| 语音输入（speech_to_text） | ✅ | ✅ | ✅(macOS 11+) | — |

\* 受 `chatgpt_flutter/pubspec.yaml` 的 OCR override 影响：默认被 stub 顶替，删掉 override 块后在真机生效。

---

## 当前版本

`chatgpt_flutter` 版本 **1.0.2+3**；`chatgpt_flutter_ohos` 独立版本 1.0.0+1。
