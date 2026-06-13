# 分支 Review 指南 · `worktree-block-message-system`

> 给 reviewer 的导航地图。配套规格见 [`flutter-migration-guide.md`](./flutter-migration-guide.md)，任务/遗留清单见 [`next-session-prompt.md`](./next-session-prompt.md)。

## 范围与规模

- **基线（main）**：`6d5b83a`（docs: rewrite package READMEs + format login page）。
- **改动量**：跟踪文件 60 个变更（**+4960 / −242**）**＋ 27 个新增未跟踪文件** = 共 87 项。
- **全部未提交、单块改动**（无逐 commit 历史）——故本文件即导航地图。
- 两层工作叠在一起：**Cherry Studio → Flutter 迁移的八个阶段**（主体）＋ **本轮 6 个遗留项修复**（#1/#2/#6/#9/#13，并核对纠正了已做的 #4）。两者在文件上有重叠（遗留修复改动了阶段创建的文件），下文都做了标注。

---

## 按包拆解

### `chatgpt_app_core/`（核心 · Flutter 业务逻辑）

**块化消息架构（阶段一、二）**
- `chat/domain/message_block.dart`（+593）—— sealed 块层级 + JSON 往返。**Review 关注**：文件末尾 `FileMetadata.extractedText`（遗留项 #6）。
- `chat/application/{chat_block_store,stream_dispatcher}.dart`、`chat/ui/{block_message_content,thinking_block_view}.dart` —— 规范化块仓库 + 类型化事件分发 + 渲染。
- `chat/domain/stream_event.dart` —— 类型化 `StreamEvent.{text,reasoning,toolCall,toolResult,image,citation}`。

**能力探测（阶段三 ＋ #1）**
- `chat/domain/model_capabilities.dart` —— 按 modelId 家族的启发式。
- `util/model_catalog.dart`（+74）—— **#1**：`ModelOption` 新增 tool/reasoning/pdf 能力位；`capabilitiesFor` 做**加法覆盖**（只加位、不减位）。

**文件 / 附件（阶段四 ＋ #6）**
- `chat/application/file_processor.dart`、`chat/domain/chat_attachments.dart` —— **#6** 重构 `process()`，把每个文件的 `extractedText` 挂到 meta；`extraText` 由 meta 派生（与落库同一份）。

**联网搜索（阶段五）**：`chat/application/{web_search_provider,search_orchestrator}.dart`（已含 Tavily/Exa/Bocha/Zhipu 四 Provider —— 这就是已做的 #4）。

**工具调用（阶段六）**：`chat/application/{tool_registry,tool_loop_runner,tool_call_accumulator}.dart`。

**助手系统（阶段七 ＋ #9）**
- `model/assistant_model.dart`、`db/assistant_dao.dart`、`pages/assistant_{list,edit}_page.dart`、`widget/assistant_picker.dart`。
- **#9 新增**：`data/builtin_assistants.dart`（20 个内置助手，7 个分类）、`pages/assistant_market_page.dart`（助手市场：浏览 → 预填编辑页 → 保存落库成普通助手）。

**备份恢复（阶段八）**：`backup/backup_service.dart`、`pages/backup_restore_page.dart`。

#### ⭐ 高 churn / 重点审查文件（多阶段叠加 ＋ #2/#6）

- `dao/completion_dao.dart`（+291）—— history 构造；**#2/#6** 新增 `_toolHistory` / `_fileHistory` ＋ 静态纯函数 `buildHistory`。
- `pages/conversation_page.dart`（+632）—— 编排层；**#2/#6** 加了 持久化→回放→恢复 的接线。**最该重点 review 的文件**（流式生命周期、dispose 处理、DB hydration）。
- `dao/chat/{chat,direct,backend}_chat_service.dart` —— 服务分流 + tools/extraMessages 串联。

### `chatgpt_backend/`（NestJS · #1 ＋ #13）

- **#1**：`ai/ai-model.entity.ts`（4 个能力布尔列）、`ai/public-ai.controller.ts`（catalog 下发）、`ai/dto/{create,update}-model.dto.ts`、`ai/ai-seed.service.ts`（种子预填能力位）。
- **#13**：`admin/admin-usage.{service,controller}.ts` ＋ `admin/admin-version.controller.ts` —— 给原始 SQL 结果 / query / body 加类型（25 lint errors → 0）；`package.json` 增加 `jest-environment-node` 直接依赖（修复 jest `clearMocksOnScope` 崩溃 —— 详见下文「环境注意」）。
- 阶段工作：`chat/chat.service.ts`、`chat/dto/completion-body.dto.ts`（小改）。

### `chatgpt_admin/`（Next.js · 仅 #1）

- `types/ai.ts`、`schemas/ai.ts`、`components/ai/ModelForm.tsx`（4 个能力开关）、`app/(dashboard)/ai/models/page.tsx`（「能力」列）。

### 其它 Flutter 包（阶段工作，**非本轮改动** —— 按现状 review）

- `openai_flutter/` —— 流式 chunk 模型 + SSE 处理（`core/ai_completions.dart`、`http/ai_http.dart`、`model/ai_stream_chunk.dart`）。
- `chat_message/` —— controller / model / widget 适配块化渲染。
- `login_sdk/` —— `dao/login_dao.dart`、`pages/login_page.dart`（＋ 新增 `test/guest_login_test.dart`）：疑似**游客登录**改动，**与迁移无关**，建议确认是否应在本分支。
- `chatgpt_flutter/` —— macOS/iOS 壳层配置（`Podfile`、`AppDelegate.swift`、pbxproj），为新依赖做平台接线。

### 根目录 / docs / lockfile

- `docs/flutter-migration-guide.md`（+796，完整规格与各阶段实施记录）、`docs/next-session-prompt.md`（任务/遗留清单，含本轮 6 条删除线 + 完成说明）、`docs/branch-review.md`（本文件）。**按 prompt 约定：合并时 `docs/` 以分支版为准。**
- `pnpm-lock.yaml` —— jest-environment-node 依赖（#13）。`chatgpt_app_core/pubspec.yaml`（+3 依赖：archive / syncfusion PDF 等）。

---

## 本轮 6 个遗留项修复速查

| 项 | 一句话 | 主要文件 |
|---|---|---|
| **#1** 后端能力位 | `supportsVision/Tool/Reasoning/Pdf` 全链路下发，客户端加法覆盖 | 后端 ai/* · `model_catalog.dart` · admin ai/* |
| **#2** 工具调用历史跨轮 | 从持久化 `ToolBlock` 重建 `assistant(tool_calls)`+`role:tool` | `completion_dao.dart` · `conversation_page.dart` |
| **#6** 附件文本跨轮 | `FileMetadata.extractedText` 落库 + 回放进 history | `message_block.dart` · `file_processor.dart` · `completion_dao.dart` · `conversation_page.dart` |
| **#9** 内置助手/市场 | 20 个内置模板 + 助手市场「浏览→添加」 | `data/builtin_assistants.dart` · `assistant_market_page.dart` · `assistant_{list,edit}_page.dart` |
| **#13** 后端 lint/jest | 25 lint errors→0；jest `clearMocksOnScope` 根因修复 | 后端 admin/* · `package.json` · `pnpm-lock.yaml` |
| **#4** | 核对确认阶段五已做，纠正陈旧遗留说明 | （无代码改动） |

---

## 自检状态

- **`chatgpt_app_core`**：`flutter analyze` **0 errors**；**149 tests 全过**（11 个测试文件，含新增 `tool_history_test.dart`、`builtin_assistants_test.dart`）。
- **`chatgpt_flutter` 壳层**：全图 `flutter analyze` → **No issues found**。
- **后端**：lint 0 problems、`nest build` ok、单测通过。*e2e 需 `JWT_SECRET` + Postgres（环境前置，非代码问题）。*
- **管理端**：`tsc --noEmit` 通过。

## 重点审查 / 注意事项

1. **`conversation_page.dart`** —— 体量最大、状态最复杂；重点看 流式收尾 → 落库 → `appendTurn` → 恢复 这条链。
2. **history 重建语义**（`completion_dao.dart`）—— 工具调用按「一调用一配对」还原；附件文本拼进 user content。属有意简化（代码内已注释）。
3. **后端能力位是加法覆盖**（管理端无法把能力「关掉」）—— 有意为之，避免 `synchronize` 迁移把存量模型能力清空（默认 false）。
4. **`login_sdk` 游客登录改动** —— 疑似与迁移无关，确认是否应在本分支。
5. **未提交** —— 按要求未 stage 任何内容。
6. **环境注意**：家目录存在游离的 `~/node_modules`（含 jest@27 等，约 1097 项），会污染本机所有 Node 项目的模块解析；#13 的修复已为本仓库屏蔽该问题，但根治需清理 `~/node_modules`。

## 迁移之外的建议下一步（见 prompt §6）

- 本分支 review 后合并 main（`docs/` 以分支版为准）。
- OHOS 壳层（`chatgpt_flutter_ohos`）回归一遍八个阶段功能（注意先 `eval "$(mise activate ...)"`，见 CLAUDE.md）。
- 剩余遗留项 #3/#5/#7/#8/#10/#11/#12 均属「被更大改造/OHOS 插件阻塞」或「价值低且与现有设计冲突」，本轮未动（理由见 `next-session-prompt.md` §5 各条与会话记录）。
