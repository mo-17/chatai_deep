# 下一次会话提示词 · Cherry Studio → Flutter 迁移（已全部完成，仅剩遗留项）

> 把本文件整段作为下一次会话的起始提示词。配套规格与各阶段实施记录见 [`flutter-migration-guide.md`](./flutter-migration-guide.md)。

---

## 0. 当前状态

**八个阶段已全部完成**（2026-06-12）：阶段一（块化消息系统）、阶段二（思考展示）、阶段三（多 Provider 抽象 + 能力探测）、阶段四（文件解析 + 图片多模态）、阶段五（智能联网搜索 / 意图编排）、阶段六（工具调用）、阶段七（助手系统）、阶段八（备份恢复）。
每阶段的落地映射、验收与已知限制见指南各节「✅ 实施记录」。最终自检：`chatgpt_app_core` 118 个测试全过、analyze 0 errors；`chatgpt_flutter` 壳层全图 analyze 无 issue。

**下一次会话的任务**：从 §5「遗留项清单」里挑一项（或按用户指定）处理。一次只做一项，做完自检 + 一句话汇报。

## 1. ⚠️ 不可违背的技术栈约束

本仓库 CLAUDE.md 强制：**状态管理只用 `provider`；持久化用 `sqflite`；网络/SSE 用 `package:http`**。
**不要引入 Riverpod / Drift / dio**。Dart 注释用中文（与现有代码一致）。DAO 沿用「接口 + 实现同文件」+ `ITable` 模式。

## 2. 如何恢复到工作区

全部八个阶段的代码在 **git 分支 `worktree-block-message-system`**，对应 worktree 目录 `.claude/worktrees/block-message-system/`（**改动尚未提交、未合并 main**）。

```
# 进入既有 worktree（保留全部未提交改动）继续干活：
EnterWorktree({ path: ".claude/worktrees/block-message-system" })
```

> 若该 worktree 已被清理，则 `git checkout worktree-block-message-system`，或基于它新建 worktree。
> 注意：`docs/` 在 main 是未跟踪文件；带标注的本版指南随该分支走，合并时以分支版为准（必要时删掉 main 工作区里旧的未跟踪副本）。

参考实现仓库（按需重新克隆，上次的临时克隆可能已随任务清理）：
`git clone --depth 1 --branch bugfix/upstream-issues https://github.com/mo-17/cherry-studio-app.git`

## 3. 已落地的地基（处理遗留项时直接复用）

- **块化消息系统**（阶段一/二）：`chat/domain/message_block.dart`（sealed 块层级 + JSON 往返）、`chat/application/chat_block_store.dart`、`stream_dispatcher.dart`、`chat/ui/block_message_content.dart`。
- **类型化流事件**：`StreamEvent.{text,reasoning,toolCall,toolResult,image,citation}` 全部带 payload 且已接分发。
- **会话服务**：`dao/chat/chat_service.dart` —— `ChatService.from(AISettings)` 分流 local/backend；`chatStreamEvents` 带 `tools`/`extraMessages`；`static capabilitiesFor(AISettings)` 是能力探测唯一入口。
- **工具调用**（阶段六）：`chat/application/tool_registry.dart` + `tool_loop_runner.dart`（执行回路，上限 5 轮）+ `tool_call_accumulator.dart`。
- **联网搜索**（阶段五）：`web_search_provider.dart`（Tavily）+ `search_orchestrator.dart`（意图编排，`caps.tool=false` 时的回落路径）。
- **附件通路**（阶段四）：`file_processor.dart` + `chat_attachments.dart`，`CompletionDao` 各方法带可选 `attachments`。
- **助手系统**（阶段七）：`model/assistant_model.dart`（`applyTo` 模型覆盖）+ `db/assistant_dao.dart`（tb_assistant）+ 会话绑定 `ConversationModel.assistantId` + `CompletionDao.injectSystemPrompt` + 管理/选择 UI（`assistant_list_page` / `assistant_edit_page` / `assistant_picker`）。
- **备份恢复**（阶段八）：`backup/backup_service.dart`（zip：manifest + 每表 JSON + settings；覆盖式恢复 + 外键修复 + API key 默认脱敏；`restoreTick` 通知常驻页刷新）+ `pages/backup_restore_page.dart`。
- **设置与持久化范式**：`AISettings`/`AISettingsDao`（HiCache，按账号 key）+ `AISettingsProvider`；DB 侧 `HiDBManager`（按账号分库）+ `ConversationListDao`/`MessageDao`/`FavoriteDao`/`AssistantDao`。**测试可用 `HiDBManager.test(Database)` 注入 ffi 内存库走真实 DAO**（参照 `test/assistant_test.dart`、`test/backup_test.dart`）。

## 4. 每项改动必做的自检

```bash
# 在各受影响包目录下：
flutter pub get
flutter analyze        # 必须 0 errors
flutter test           # 含新增的验收测试

# 全图类型检查（最稳）：在 chatgpt_flutter 壳层跑 flutter analyze
```
受影响包通常是 `chatgpt_app_core`，以及壳层 `chatgpt_flutter`。
新功能写对应的单元/Widget 测试（DB 相关用 `sqflite_common_ffi` 内存库 + `HiDBManager.test`）。
改完代码若用户要求再 `commit`（默认不提交），提交信息结尾加 `Co-Authored-By` 行；处理完某项遗留项后在本文件 §5 划掉对应条目。

## 5. 遗留项清单（按优先级排序，择机处理）

1. ~~**【major，需后端配合】后端能力位缺失**（阶段三遗留）——`/uapi/ai/catalog` 不下发 `supportsVision/supportsTool` 等能力位，后端模式能力全靠 modelId 家族启发式。~~ ✅ **已完成（2026-06-13）**：`AiModel` 加 `supportsVision/supportsTool/supportsReasoning/supportsPdf` 四列（默认 false，`synchronize` 自动迁移）→ `public-ai.controller.ts` catalog map 下发 → Flutter `ModelOption`/`applyRemote`（三处构造点）/`capabilitiesFor` 接字段；合并语义为**加法覆盖**——catalog 位只把启发式判不出的能力「往上加」，绝不因默认 false 而「减位」，故迁移后存量模型不丢能力。管理端 `ModelForm` 加四个开关 + 列表加「能力」列；`ai-seed.service.ts` 同步预填能力位。验收：`model_capabilities_test.dart` 新增「遗留项 1」组（四位各自强制开 + 全 false 不减位）；`chatgpt_app_core` analyze 0 errors、130 tests 全过；`chatgpt_flutter` 壳层 analyze 无 issue；backend `nest build` + admin `tsc --noEmit` 通过。未做：`supportsWebSearch`（`ModelCapabilities` 无对应位，联网搜索走 `tool` 能力 + 搜索 Provider 配置，见 §3/§4）。
2. ~~**工具调用历史不跨轮**（阶段六限制）——assistant(tool_calls)/role:tool 只在当轮请求内回灌，落库 history 仍是正文。~~ ✅ **已完成（2026-06-13）**：`CompletionDao` 新增 `_toolHistory`（`createdAt → List<ToolBlock>`）；`appendTurn(..., assistantBlocks:)` 在收尾时把该轮 ToolBlock 记入历史；`buildHistory` 对带工具的 assistant 在其正文消息前插入「assistant(tool_calls) + role:tool」配对（一调用一配对，满足「tool 须紧跟声明该 id 的 assistant」）。重开会话时 `_loadToolHistory` 从持久化块（`tb_messages.blocks`）重建工具历史；settings/助手切换重建 dao 时经 `currentToolHistory` 透传。`buildHistory`/`toolCallMessages` 抽成静态纯函数。验收：`test/tool_history_test.dart`（8 用例：配对结构 / arguments JSON 串 / 多调用逐对 / 跨轮只重建带工具的轮 / 图片 vision 回归）；`chatgpt_app_core` analyze 0 errors、138 tests 全过；`chatgpt_flutter` 壳层 analyze 无 issue。说明：块列表里穿插的中间正文已并入该 assistant 的 content，重建只取工具调用、不还原 text↔tool 的精确交错（对历史上下文足够）。
3. **正文引用标注联动**（阶段五限制）——正文里的 `[n]` 与来源列表未做点击联动，挪到正文 Markdown 化时一并做。
4. ~~**更多搜索 Provider**（阶段五限制）——Exa/Bocha/智谱在 `WebSearchProvider.fromSettings` 扩展。~~ ✅ **已完成（实为阶段五落地时已做，此条为陈旧遗留）**：`web_search_provider.dart` 已实现 `Exa/Bocha/Zhipu` 三个 Provider 并接入 `fromSettings`；`ai_settings_page.dart` 已有服务商下拉 + 各自 API Key 输入；`web_search_providers_test.dart` 覆盖三者的鉴权/请求体/解析。2026-06-13 核对确认无遗留。
5. **超限 PDF 的 File API 上传**（阶段四限制）——统一降级抽文本，待接入 Anthropic/Gemini 直连时再补。
6. ~~**附件文本不进 history**（阶段四限制）——跨轮文件上下文需要时从 FileBlock 重建。~~ ✅ **已完成（2026-06-13）**：`FileMetadata` 加 `extractedText`（降级抽取的包裹文本，随 FileBlock 落库；原生直发/图片为 null）；`FileProcessor.process` 把文本挂到各 meta，`extraText` 改由 meta 派生（与落库同一份）。`CompletionDao` 加 `_fileHistory`（`createdAt → 附件文本`）：`appendTurn(..., userFileText:)` 记录当轮；`buildHistory` 把文本拼回该 user 消息 content（格式与 `ChatAttachments.buildUserContent` 一致：`正文\n\n文本`，含 vision 文本 part）；重开会话经 `_loadBlockHistory` 从持久化 FileBlock 重建，settings/助手切换经 `currentFileHistory` 透传。验收：`tool_history_test.dart` 加「附件文本跨轮」组（拼接/空正文/图片+文本/不命中回归）+ `file_attachments_test.dart` 加 extractedText 落库回读断言；`chatgpt_app_core` analyze 0 errors、142 tests 全过；壳层 analyze 无 issue。说明：仅降级文本跨轮；原生 PDF base64 跨轮重发成本过高，不在此项范围（属 §5.5 File API）。
7. **生成图片存相册（gal）**——`StreamDispatcher.onImage` 通路已就绪，待有产生图片输出的 provider 时接 `gal` 并补权限配置。
8. **助手模型覆盖不切服务商**（阶段七限制）——本地模式只换模型名，覆盖的模型须与当前服务商兼容；完整形态（Assistant.model 带 provider）待多 Provider 配置抽象后再做。
9. ~~**内置助手 / 助手市场未迁移**（阶段七限制）——目前仅用户自建助手；源参考 `src/config/assistants.ts`、`AssistantMarketScreen.tsx`。~~ ✅ **已完成（2026-06-13）**：新增 `data/builtin_assistants.dart`——`BuiltinAssistant`（category/name/emoji/prompt/useTools，纯静态数据）+ 精选目录（20 条，7 个分类：写作/编程/翻译/学习/职场/生活/思维）+ `grouped()` + `toAssistant()`（每次返回新 `AssistantModel`，id=null、model 留空跟随全局）。新增 `pages/assistant_market_page.dart`（助手市场，按分类陈列，点一项 → 预填 `AssistantEditPage` → 保存即插入 `tb_assistant`，之后即普通可编辑助手）；`assistant_list_page` 加「助手市场」AppBar 入口（关闭后刷新列表）；`AssistantEditPage._isNew` 改以 `assistant?.id == null` 判定，使市场预填模板正确显示「新建/创建」。验收：`test/builtin_assistants_test.dart`（7 用例：目录完整性/名称唯一/grouped 不丢条目/映射/独立实例/克隆落库全链路/多次添加各自独立 id）；`chatgpt_app_core` analyze 0 errors、149 tests 全过；`chatgpt_flutter` 壳层 analyze 无 issue。说明：源项目目录上百条且多语言，这里收一组高频实用的中文预设，`BuiltinAssistants.all` 可继续扩；「按分类浏览」已实现，未做搜索/收藏等市场增强。
10. **备份 zip 非流式**（阶段八限制）——内存中组装/解析，数万条消息时峰值内存偏高；`archive` 包有流式接口，需要时再换。
11. **OHOS 端备份/附件的 file_picker 缺位**（阶段四/八限制）——file_picker 无鸿蒙实现，相关入口仅提示「敬请期待」；待插件支持或接平台文件选择。
12. **备份不含附件原始文件**（阶段八限制）——图片 base64 已随消息行导出；本地文件路径跨设备失效，FileBlock 仅展示元信息。
13. ~~**后端 lint/jest 存量失败**——admin-usage 系列文件的 `no-unsafe-*` lint 错误、jest 运行时版本不匹配（`clearMocksOnScope is not a function`），与迁移无关，择机修。~~ ✅ **已完成（2026-06-13）**：① Lint——`admin-usage.service.ts` 给 `getRawOne/getRawMany` 加泛型类型参数（原始 SQL 聚合结果不再是 `any`），`admin-usage.controller.ts` 的 `@Query() query: any` 改为 `ExportUsageQuery` 接口，顺带把 `admin-version.controller.ts` 的 `@Body() body: any` 收成 `Partial<AppVersion>`；25 errors → **0 problems**。② Jest——根因**不是版本不匹配**而是**模块解析逃逸**：jest 的 `testEnvironment: 'node'` 从 backend 根按名解析 `jest-environment-node` 时向上走到家目录的游离安装 `~/node_modules/jest-environment-node@27.5.1`（其 `ModuleMocker` 来自 jest-mock@27.5.1，无 `clearMocksOnScope`），被 jest-runtime@30 调用即报错；项目自身的 pnpm 树解析是对的。修法：把 `jest-environment-node` 提为 `chatgpt_backend` 的**直接 devDependency**，使其 symlink 进 `chatgpt_backend/node_modules`、解析在逃逸到家目录前命中项目版本。验收：backend `lint` EXIT 0、`build` EXIT 0、`test`（单测）通过。注：`test:e2e` 仍需 `JWT_SECRET` 环境变量 + Postgres（`jwt.const.ts` 启动即校验）方能跑通——属环境前置，不在本条范围；jest 修复后 e2e 已能正常启动 jest 并进入应用初始化。另注：家目录 `~/node_modules`（约 1097 项，疑似在家目录误跑过 npm/pnpm install）会污染所有子项目的 Node 解析，根治需清理它，但属用户环境、未擅自删除。

## 6. 建议的下一步（迁移之外）

- 把分支 `worktree-block-message-system` 的全部改动 review 后合并 main（`docs/` 以分支版为准）。
- OHOS 壳层（`chatgpt_flutter_ohos`）回归一遍八个阶段的功能（注意 mise 激活，见 CLAUDE.md）。
