# ChatAI Deep 产品优化路线图

> 生成日期：2026-06-29
>
> 范围：聚焦 Flutter 客户端现有功能的产品化、数据可靠性、模型配置体验和稳定性优化。Android 发布质量专项暂不展开，仅保留后续入口。

## 0. 2026-06-30 能力补齐判断

当前应用已经具备成熟 AI 客户端的基础骨架，后续不应继续只堆“聊天功能”。更高价值的方向是把现有能力做成可长期使用、可解释、可恢复、可协作、可发布的 AI 工作台。

### 近期最值得执行的 5 项

1. **用户侧用量 / 成本统计**：按服务商、模型、项目、会话、日期展示 token 和估算成本；后端代理优先使用真实 usage，本地直连使用估算。
2. **正文引用点击联动**：正文 `[n]` 与来源列表一致，可点击打开来源，提升联网搜索和知识库回答可信度。
3. **会话模板 / 工作流模板**：把项目、助手、模型、工具、联网搜索和知识库组合成一键开始的工作流。
4. **向量知识库 / RAG 升级**：在现有关键词检索基础上增加 embedding/vector search、引用片段定位和索引重建。
5. **跨设备云同步**：在手动备份之外增加账号级增量同步、冲突合并和可选加密。

### 中长期能力池

- **附件与文件能力升级**：超限 PDF File API、附件原始文件备份、跨设备恢复附件、长 PDF 分页摘要。
- **图片生成与相册保存**：接入可产生图片输出的 provider，复用 `StreamDispatcher.onImage` 通路并补权限。
- **助手模型覆盖升级**：助手模型覆盖从单一 modelId 升级为 provider + model 组合，避免多服务商错配。
- **MCP / 工具生态增强**：OAuth MCP、工具权限分级、调用审计、按项目启用工具、失败重试、市场质量评分。
- **语音输入 / 朗读**：移动端长按语音输入、ASR、回答朗读和会话级语音偏好。
- **可靠性与回归体系**：补聊天发送、模型切换、备份导入导出、工具确认、知识库检索等自动化路径。
- **正式发布专项**：release signing、正式 applicationId、OCR stub override 拆分、隐私权限和崩溃诊断。

### 本次执行记录

2026-06-30 已落地：

- 正文引用点击联动：`BlockMessageContent` 会将同一条消息里的 `CitationBlock.webResults` 映射到正文 `[n]` 标记；命中有效 URL 的标记可点击用系统浏览器打开来源。
- 新增引用标记分段测试，覆盖有效来源、空 URL 来源和越界来源的退化行为。
- 第二批能力 MVP 地基：新增 `capability/product_capabilities.dart`，把用户侧用量/成本估算、会话模板、轻量向量 RAG、跨设备同步合并策略、附件升级策略、图片保存计划、助手 provider/model 路由、工具权限/审计、语音偏好、自动化回归清单收敛成可测试的纯业务合同。
- 新增 `product_capabilities_test.dart`，覆盖上述能力的最小验收。真实 embedding provider、真实相册写入、真实 ASR 和 MCP OAuth 仍属于后续外部集成；TTS 已接入 `flutter_tts`，剩余真机发声、系统语音包和音频焦点验证。
- 新增「我的 → AI 能力中心」入口，展示内置工作流模板、已落地能力地基状态和自动化回归清单；工作流模板已可点击「开始」，会自动创建/复用模板助手并打开预填首条提示词的新会话。
- 工作流模板启动继续补齐上下文注入：预填首条提示会携带模板项目名、知识库文档范围、联网搜索和工具清单，避免模板字段只停留在展示层。
- 工作流模板继续补齐用户自定义能力：`WorkflowTemplate` 支持 JSON 持久化，新增 `WorkflowTemplateStore` 保存自定义模板；「AI 能力中心」支持新增模板、从内置/自定义模板复制副本、自定义模板上移/下移排序和删除，并保持「开始」入口可复用同一启动通路。
- 工作流模板启动时已真正落到工作空间：`WorkflowTemplateLauncher` 会按模板项目名创建/复用 `ProjectModel`，把 provider/model/助手/联网/工具写作项目默认值；模板列出的知识库标题若本地已存在，会自动绑定到该项目的知识库范围。
- 用户侧用量统计继续产品化：新增 `tb_usage` / `UsageDao` / `UsageRecordService`，聊天收尾会记录真实 usage（非流式可用时）或估算 usage（流式/缺失时），并新增「我的 → 用量统计」页面按服务商、模型、日期、项目、会话展示聚合结果；成本估算支持账号级默认单价、provider 默认单价和 provider/model 精确单价。
- 用量统计页新增「成本单价」配置入口，可编辑默认输入/输出单价，并新增或覆盖 `provider/*` 与 `provider/model` 单价规则，保存后写回 `AISettings.usageCostConfig`，后续聊天记录成本估算直接复用该配置。
- 用量统计页新增「复制汇总」入口，可把总 token、估算成本、数据来源以及模型/服务商/日期/项目/会话五类聚合明细复制为文本，便于用户对账、留档或发给自己。
- 流式 SSE 真实 usage 透传已接入：`openai_flutter` 会解析 `stream_options.include_usage` 返回的 final usage chunk，直连/后端流式均会产出 `StreamEvent.usage`；会话页收尾时优先用真实 prompt/completion token 落 `tb_usage`，无 usage 时继续估算兜底。
- 向量知识库 / RAG 升级迈出本地接入：`KnowledgeDao.search` 在关键词检索 0 命中时会走 `LightweightVectorRag` fallback，并继续尊重项目绑定知识库范围；真实 embedding provider 仍保留为后续外部集成。
- RAG 本地轻量索引继续补齐：新增 `tb_kb_vector` 保存 chunk 级轻量向量，导入新文档时自动写索引，删除文档时清理索引；`KnowledgeDao.vectorIndexStats` / `rebuildVectorIndex` 支持查看缺失数量和重建旧数据；知识库页新增「重建检索索引」入口。搜索时索引缺失或损坏会退回现场计算，旧数据在重建前仍可检索。
- 知识库文件导入支持多选批量上传；批量结果会统计成功/跳过数量，并在部分失败时展示逐文件失败原因，便于处理空文本、OCR 不支持或识别异常。
- 新增 `workflow_template_launcher_test.dart`，覆盖模板助手创建/复用与会话配置继承；`knowledge_base_test.dart` 新增轻量向量 fallback + 项目范围验收，并补充本地向量索引自动写入、缺失回退、单文档/全量重建和删除清理用例；已通过 `dart analyze lib/db/knowledge_dao.dart lib/pages/knowledge_base_page.dart test/knowledge_base_test.dart` 与 `flutter test test/knowledge_base_test.dart`。
- 新增 `workflow_template_store_test.dart` 与能力中心页面回归，覆盖自定义模板新增、复制、排序、删除和复制后持久化；`product_capabilities_test.dart` 覆盖模板 JSON 往返；`workflow_template_launcher_test.dart` 覆盖模板项目创建/复用、项目默认值和知识库文档标题绑定。
- 跨设备云同步完成端到端代码闭环：新增后端 `SyncModule`，提供 `POST /uapi/sync/push` 与 `GET /uapi/sync/pull`，按账号隔离变更流、服务端游标、LWW 和等时冲突返回；Flutter 新增 `LocalSyncService` + `CloudSyncClient` + `CloudSyncPage`，可导出核心表 `SyncChange`、分页拉取并应用远端变更、上传本地增量、保存账号游标和上次同步时间，并从登录钩子机会性同步或「我的 → 跨设备云同步」手动触发。`pull.hasMore=true` 时客户端必须继续使用新 `cursor` 拉取；`push.conflicts[].reason` 保留并展示到页面，当前支持 `remote_newer` / `same_timestamp` / 本地等时冲突说明。仍需真实部署、多设备联调和可选端到端加密策略。
- 图片生成保存完成本地入口和应用内相册：`ImageBlock` 增加保存按钮，`GeneratedImageSaveService` 支持 data URI、HTTP 图片和本地文件保存到应用文档目录 `generated_images/`，并可列出/删除已保存图片（删除仅允许操作 `generated_images/` 内文件）；新增「我的 → 生成图片相册」页面展示已保存图片、大小和保存时间，并支持确认删除；备份 v2 已将应用内生成图片打包到 `assets/generated_images/`，覆盖导入会替换本地应用内相册，合并导入会保留本地同名图片并追加唯一文件名。本地保存、查看、备份与恢复均无需系统相册权限；真实系统相册写入仍需要相册插件和平台权限。
- 助手模型覆盖完成 provider + model 组合闭环：`AssistantModel.providerId` 与 `model` 分离持久化，助手编辑页可选服务商覆盖与对应模型；本地模式会先切目标服务商再应用模型，后端模式覆盖 `backendModel`，会话级模型覆盖仍拥有最终优先级。
- 附件原始文件与生成图片资源纳入备份 v2：`BackupService` 会收集 `FileBlock.path` 指向的存在文件写入 `assets/files/`，导入时恢复到本地目录并重写 `FileBlock.path`；应用内生成图片会写入 `assets/generated_images/` 并恢复到 `generated_images/` 相册目录；缺失附件文件会保留元数据并给出非致命告警。
- 备份导入策略完成第一步细分：新增 `BackupPreview` / `BackupService.previewArchive`，导入前可只读解析备份版本、账号、设置/API key 状态、各表数量、头像资源、附件原始文件数量和生成图片数量；同时增加 `BackupConflictSummary` / `BackupTableConflict`，按表识别同 key 覆盖、本地独有、备份新增和同 key 内容不同数量，并展示少量冲突 key 样例；「备份与恢复」页面选择文件后先展示预览和冲突摘要，再确认覆盖导入，取消不会写库或触发刷新。
- 语音输入 / 朗读已从本地执行合同升级到真实 `flutter_tts` 接入：会话表新增 `speechInputEnabled / readAloudEnabled / voiceLocale / voiceRate`，会话页可配置语音输入开关、识别语言和朗读偏好，输入栏按偏好隐藏/使用麦克风；assistant 回复完成后会按偏好调用 `FlutterTtsReadAloudService`，真实执行 `stop -> setLanguage -> setSpeechRate -> setVolume -> setPitch -> speak`；OHOS shell 通过本地 stub 保持可编译并由平台守卫降级为 no-op。仍需真机确认系统语音包、音频焦点和后台/打断体验。
- MCP / 工具生态增强补齐本地审计、失败重试和项目/权限策略：新增 `tb_tool_audit` / `ToolAuditDao`，MCP 工具调用会持久化来源、信任/只读属性、确认结果、参数摘要、执行结果和失败信息；动态 MCP 工具抛错时默认自动再试一次并回灌最终结果；直连 MCP server 可配置项目白名单，未命中项目的会话不会下发该 server 工具；`readOnly` 权限仅暴露 resources/prompts 只读合成工具；新增「我的 → 工具审计」页面查看最近调用记录；真实 OAuth MCP 授权仍属于外部服务接入。
- 可靠性与自动化回归从清单升级为证据矩阵：`ReliabilityBacklog.evidence` 将发送收尾、模型切换、备份恢复、工具确认、知识库导入/检索绑定到真实测试文件、关键断言和可运行命令；能力中心展开场景可直接看到覆盖测试、关键断言和可运行命令。
- 新增 `generated_image_save_service_test.dart`，覆盖 data URI / HTTP / 本地文件三种保存来源、本地相册列表过滤/排序，以及只删除 `generated_images/` 内文件的边界；新增 `generated_image_album_page_test.dart` 覆盖生成图片相册空态、刷新、已保存图片信息展示和确认删除；`my_page_test.dart` 保持个人中心小屏滚动无溢出；`product_capabilities_test.dart` 校验应用目录保存不需要相册权限；`backup_test.dart` 新增附件原始文件导出/导入 round-trip，以及生成图片资源导出、预览计数、覆盖恢复和合并导入同名追加。
- `backup_test.dart` 新增导入前预览与冲突识别回归，覆盖预览数量、跨账号告警、包含设置/API key 标记、仅本地存在风险、同 ID 覆盖风险、同 key 内容不同和样例 key，并验证预览不修改数据库、不推进 `restoreTick`。
- 备份导入策略继续细分：新增 `BackupImportMode.knowledgeBaseOnly`、`BackupImportMode.assistantsOnly` 与 `BackupImportMode.projectConversationsOnly`。导入预览弹窗可选择「仅导入知识库」「仅导入助手」或「仅导入项目和会话」；知识库模式只替换知识库文档、切块和仍能匹配本地项目的项目知识库绑定；助手模式只替换助手列表，并清理当前会话/项目中无法匹配新助手集的引用；项目和会话模式只替换项目、会话与消息，保留本地助手、收藏、知识库和 AI 设置，并恢复消息附件原始文件。`backup_test.dart` 已覆盖三种模式不会影响非目标数据、会推进 `restoreTick`、会给出非致命修复告警。
- 导入影响预估完成服务层与 UI 闭环：`BackupPreview.planFor(mode)` 会按「覆盖全部 / 仅项目会话 / 仅助手 / 仅知识库 / 合并导入」汇总预计覆盖、内容不同、新增和仅本地将删除或保留的行数；导入预览弹窗会随导入方式切换展示对应影响范围。`backup_test.dart` 覆盖服务层计划统计，`backup_restore_page_test.dart` 覆盖 UI 文案。
- 备份合并导入已落地：新增 `BackupImportMode.mergeAppend`，导入时保留本地数据和 AI 设置，把备份内助手、项目、会话、消息、收藏、知识库文档/片段、项目知识库绑定追加写入；自增主键会重新分配，冲突 `cid` 会生成新值，消息 `cid`、会话 `assistantId/projectId`、项目 `defaultAssistantId`、知识库 `docId` 和 `tb_project_kb` 会按映射修复。`backup_test.dart` 覆盖保留本地旧数据、冲突 cid 重映射、消息归属改写、助手/项目/知识库绑定不悬空；`backup_restore_page_test.dart` 覆盖「合并导入」下拉项和不覆盖本地数据文案。
- `assistant_test.dart` 补齐 provider + model 覆盖证据，覆盖 JSON/DAO 持久化、仅切服务商、联合覆盖、不存在 provider 回退和能力位重算。
- 新增 `project_dao_test.dart` 语音偏好回归，覆盖旧表补列、偏好保存和恢复默认。
- 新增 `read_aloud_service_test.dart`，覆盖自动朗读开关、空文本跳过、locale 规范化、朗读速率边界、默认 no-op 实现，以及 `FlutterTtsReadAloudService` 对底层 `flutter_tts` engine 的语言、音量、音调、语速和 `speak/stop` 调用。
- 2026-07-03 修复语音识别语言输入为空时的崩溃风险：输入组件会过滤空 `localeId`，空偏好和插件空语言列表会回退平台默认语言，不再把空字符串传给 `speech_to_text`；新增 `message_input_widget_test.dart` 覆盖空语言、全空 locale 列表和 `zh-CN`/`zh_CN` 兼容，并纳入「语音偏好与朗读执行」可靠性证据。
- 2026-07-03 真实 TTS 插件先行落地：`chatgpt_app_core` 接入 `flutter_tts`，新增 `FlutterTtsReadAloudService` / `FlutterTtsEngine`，会话页默认复用真实服务并在退出会话时 `stop()`；Android manifest 已声明 `android.intent.action.TTS_SERVICE` 查询；OHOS shell 新增 `ohos_stubs/flutter_tts` override 并由平台守卫降级为 no-op。`read_aloud_service_test.dart` 覆盖底层 engine 的 stop、language、speechRate、volume、pitch、speak 调用顺序；剩余为真机发声、系统语音包和音频焦点验证。
- 2026-07-03 TTS 语音风格切换已落地：`ConversationModel` / `tb_conversation_list.voiceStyle` 新增会话级风格偏好，语音偏好弹窗可在「系统默认 / 女声优先 / 男声优先 / 清亮高音 / 低沉慢速」之间切换；`FlutterTtsReadAloudService` 会按 locale + gender/name/identifier 从 `flutter_tts.getVoices` 中尽量选择 voice 并调用 `setVoice`，匹配不到时用 pitch/rate 降级。`read_aloud_service_test.dart` 覆盖风格传递、voice 选择和降级路径，`project_dao_test.dart` 覆盖旧表补列、保存和恢复默认。
- 2026-07-04 sherpa-onnx Matcha 中文 Baker 模型首版随 app 打包已落地：运行必需文件已复制到 `chatgpt_flutter/assets/sherpa_onnx/matcha-icefall-zh-baker/`，`chatgpt_flutter/pubspec.yaml` 明确声明 acoustic model、vocoder、tokens、lexicon、phone/date/number FST 和 dict 目录；`SherpaOnnxTtsManifest` / `BundledSherpaOnnxTtsModel` 负责集中管理 manifest、asset key 和必需资源校验。已通过 `flutter test test/sherpa_onnx_tts_assets_test.dart`、core 相关 `dart analyze`、`chatgpt_flutter` analyze 和 `flutter build apk --debug`；debug APK 约 280MB，APK 内 sherpa_onnx 模型资源 15 个、约 143.5MB。Android Gradle heap 已提到 `-Xmx4096M`，否则大模型进包后容易触发 `Java heap space`。
- 2026-07-04 sherpa-onnx 离线 TTS 播放链路已接入 Android/iOS：新增 `SherpaOnnxReadAloudService`，会把随包模型资源复制到 app support 目录，创建 Matcha `OfflineTts`，合成 wav 后交给 `audioplayers` 播放；新增 `HybridReadAloudService`，语音风格选择「内置离线中文女声」时走离线 sherpa-onnx，其它风格继续走系统 `flutter_tts`。已通过 `dart analyze` 相关 TTS 文件、`flutter test test/read_aloud_service_test.dart test/sherpa_onnx_tts_assets_test.dart test/sherpa_onnx_read_aloud_service_test.dart`、`chatgpt_flutter` / `chatgpt_flutter_ohos` analyze、`flutter build apk --debug` 和 `flutter build ios --debug --no-codesign`；Android APK 与 iOS Runner.app 均确认包含 15 个 sherpa 模型资源，iOS 产物同时包含 `sherpa_onnx.framework`。仍需真机测首句耗时、音频焦点、打断/后台行为；当前首版合成在当前 isolate 执行，后续可优化到 isolate/流式播放。
- 2026-07-04 sherpa-onnx 离线 TTS 体验继续优化：`SherpaOnnxOfflineTtsRuntime` 会按模型目录缓存 `OfflineTts` 实例，首次加载后后续朗读复用同一模型，不再每条回复重复创建/释放 native TTS；新增 `ReadAloudPreparer`，会话进入或语音偏好切到「内置离线中文女声」时后台预热模型。assistant 对话气泡底部新增「播放音频」按钮，可手动播放单条回复，手动播放不依赖「自动朗读」开关，但复用当前语言、速率和语音风格。已通过 TTS 相关 `dart analyze`、`flutter test test/read_aloud_service_test.dart test/sherpa_onnx_read_aloud_service_test.dart test/sherpa_onnx_tts_assets_test.dart`、`chatgpt_flutter` / `chatgpt_flutter_ohos` analyze、`flutter build apk --debug` 和 `flutter build ios --debug --no-codesign`。
- 2026-07-04 针对 iOS 模拟器离线 TTS 卡顿继续处理：sherpa-onnx 默认合成已改为 `Isolate.run` 后台生成 wav，避免 Matcha `generate()` 阻塞 UI isolate；`ReadAloudRequest.onStage` / `ReadAloudStage` 透传「准备中 / 生成音频中 / 播放中 / 完成」状态，assistant 气泡播放按钮会在当前消息下显示转圈和阶段文字。由于 sherpa-onnx Dart API 不提供百分比进度，本版先用不确定进度条；若真机仍慢，下一步再做常驻 worker isolate + 分句队列，减少每次后台 isolate 重新加载模型的时间。已通过 TTS 相关 `dart analyze`、`flutter test test/read_aloud_service_test.dart test/sherpa_onnx_read_aloud_service_test.dart test/sherpa_onnx_tts_assets_test.dart`、`chatgpt_flutter` / `chatgpt_flutter_ohos` analyze、`flutter build apk --debug` 和 `flutter build ios --debug --no-codesign`。
- 2026-07-04 离线 TTS 已增加 wav 音频缓存：`SherpaOnnxReadAloudService` 按模型 id / manifest / locale / speaker / sampleRate / 语速 / 文本生成 SHA-256 缓存 key，把首次合成的 wav 存入 `tts_audio_cache/<modelId>/`；同一条回复再次点击播放会直接命中缓存并跳过「生成音频中」，只进入「准备中 → 播放中 → 完成」。已通过 `dart analyze lib/chat/application/sherpa_onnx_read_aloud_service.dart test/sherpa_onnx_read_aloud_service_test.dart`、`flutter test test/sherpa_onnx_read_aloud_service_test.dart test/read_aloud_service_test.dart test/sherpa_onnx_tts_assets_test.dart`、`chatgpt_flutter` / `chatgpt_flutter_ohos` analyze。本次按要求未打包。
- 2026-07-04 朗读入口偏好已落地：会话语音偏好新增「朗读入口」，可选「显示播放按钮 / 长按菜单显示朗读 / 隐藏播放按钮」。新增 `ConversationModel.readAloudTriggerMode` 与 `tb_conversation_list.readAloudTriggerMode`，旧数据默认按显示播放按钮处理；长按模式仍保留原长按弹窗，只在 assistant 气泡菜单里额外显示「朗读」，隐藏模式不显示气泡播放按钮也不拦截长按菜单。已通过相关 `dart analyze`、`flutter test test/project_dao_test.dart`、`chatgpt_flutter` / `chatgpt_flutter_ohos` analyze。本次按要求未打包。
- 2026-07-05 继续补齐朗读停止入口：当会话朗读入口设为「长按菜单显示朗读」或「隐藏播放按钮」时，平时仍不显示播放按钮；但某条 assistant 气泡正在朗读时，会临时显示停止按钮和阶段文字，用户不需要再次长按菜单才能停止。
- 2026-07-05 继续补齐朗读进度反馈：当前朗读气泡在「准备中 / 生成音频中」阶段会显示小型不确定进度圈，播放阶段保留停止按钮与「播放中」文字，降低 iOS 模拟器离线 TTS 合成时“像卡住了”的感受。
- 2026-07-05 继续收紧朗读阶段 UI 可测性：新增 `ReadAloudStageUi` 统一阶段文案和进度圈显示判断，`ConversationPage` 复用该 helper，`read_aloud_service_test.dart` 覆盖准备/生成/播放/完成/null 阶段，避免后续阶段文案和页面判断漂移。
- 2026-07-04 用户自定义离线 TTS 模型首版已落地：个人中心新增「离线语音模型」页面，可导入 sherpa-onnx Matcha 模型目录或 ZIP；导入时校验 `manifest.json`、acoustic model、vocoder、tokens、lexicon、FST 和 dict 目录，复制到 app support 下并以 `custom_sherpa:<id>` 保存为会话级朗读风格；会话语音偏好只负责选择已导入模型。`SherpaOnnxReadAloudService` 可按该 id 解析用户模型，继续复用 wav 缓存、停止按钮和防抖/节流逻辑。首版不支持只上传单个 `.onnx`。已通过 TTS 相关 `dart analyze`、`flutter test test/read_aloud_service_test.dart test/sherpa_onnx_read_aloud_service_test.dart test/sherpa_onnx_tts_assets_test.dart`；本次未打包。
- 2026-07-04 轻量酒馆化助手角色卡 v1 已落地：不直接照搬重配置的 Tavern/Lorebook 体验，先把移动端高频收益最大的角色字段补齐到现有助手系统。`AssistantModel` / `AssistantDao` 新增 `description`、`openingMessage`、`exampleDialogs` 和 `defaultVoiceStyle`，旧助手表会自动补列；助手编辑页可维护角色简介、开场白、示例对话和默认朗读风格，并能选择内置风格或用户导入的 `custom_sherpa:*` 模型；助手市场和助手选择器优先展示角色简介。新建会话会继承助手默认语音风格，并展示不入库的 assistant 开场气泡，避免空会话直接保存为助手开场白；长按临时开场气泡只保留复制/转发/朗读，不提供收藏、删除或重新生成。2026-07-05 继续补齐示例对话的运行时价值：`systemPromptFor` 会把角色卡示例对话作为 `[示例对话]` 注入上下文，帮助模型保持角色语气和回复格式。已通过 `dart analyze` 与助手相关测试回归。
- 2026-07-05 继续收紧角色卡上下文边界：`systemPromptFor` 注入 `[示例对话]` 时会过滤 `[备选开场白]` 段落，避免 Tavern `alternate_greetings` 被模型误当成对话样例；备选开场仍只通过新建会话的「选择开场白」使用。会话页「下一轮上下文」预览同样复用该过滤结果。
- 2026-07-05 继续统一角色卡展示口径：`AssistantRoleCardService.summarize` 会把可注入的示例对话行数和备选开场数量分开统计；角色资料页、导入预览和复制角色卡摘要都会分别展示 `[示例对话]` 与 `[备选开场白]`，避免用户误以为备选开场会进入 system prompt。
- 2026-07-05 继续降低 Tavern 兼容规则漂移风险：新增 `AssistantExampleDialogs` 作为示例对话/备选开场的纯文本解析工具，`AssistantModel.systemPromptFor` 和 `AssistantRoleCardService` 复用同一套过滤与去重规则，后续修改 `[备选开场白]` / `[alternate_greetings]` 行为不需要在模型层和展示层各改一次。
- 2026-07-05 继续修正气泡沉淀示例的 Tavern 边界：`appendExampleDialog` 在角色卡已有 `[备选开场白]` 时会把新示例插入该段之前，避免长按气泡保存成功但新样例被运行时过滤掉；`hasDuplicateExampleDialog` 只检查可注入示例正文，不把备选开场候选误判为示例重复。
- 2026-07-05 继续增强备选开场解析兼容：`AssistantExampleDialogs` 现在也支持 `[备选开场白] 文本` / `[alternate_greetings] text` 这种 header 同行写法，同一套逻辑会同步影响开场候选、示例正文过滤和气泡沉淀插入位置。
- 2026-07-05 继续增强 Tavern 作者备注兼容：导入 SillyTavern / Tavern 卡时，角色简介除 `creator_notes` 外也会兜底读取 `creatorcomment`、`creator_comment`、`creatorNotes`，并继续合并 tags，避免旧卡作者说明在移动端资料页丢失。
- 2026-07-05 继续增强 Tavern 多语言作者备注兼容：导入 SillyTavern / Tavern 卡时，`creator_notes_multilingual`、`creator_notes_i18n`、`creatorNotesMultilingual`、`creatorCommentMultilingual` 会按中文优先，其次英文 / default / 首个非空文本兜底，并统一替换 `{{char}}` / `{{user}}` / `<BOT>` / `<USER>` 占位符。
- 2026-07-06 修正第三方 Tavern / SillyTavern 角色简介导入口径：第三方卡的应用内「角色简介」优先使用 `description` 的压缩摘要，再追加作者备注和 tags，避免把 `creator_notes` / `creatorcomment` 误当成角色设定简介；本应用自己导出的 Tavern 卡会通过 `extensions.chatai_deep` 识别并继续保留原应用简介，保证导出再导入不漂移。
- 2026-07-06 新增未完成回复状态承接：角色会话里若 assistant 流式回复只有 `ThinkingBlock` / reasoning、没有正式正文，会生成 `RoleContinuationBlock` 保存一条短期角色心理/动作状态快照；气泡显示「已保留角色状态 · 下轮将承接」，下一轮 `CompletionDao` 会把该快照作为“未说出口的状态”带回 history，避免角色状态因空回复、停止或异常而重置。该快照不进入长期记忆 / 世界书，正文正常生成时不会额外创建。
- 2026-07-04 轻量世界书 / 关键词记忆 v1 已落地：`AssistantModel` / `AssistantDao` 新增 `memoryBook`，旧助手表自动补列；助手编辑页新增「关键词记忆 / 世界书」输入框，支持每行 `关键词1,关键词2 => 设定内容`，未写箭头的行作为常驻设定。发送消息时 `ConversationPage` 会用 `AssistantModel.systemPromptFor(inputMessage)` 只把当前轮命中的设定拼进 system prompt，关键词变化时重建 `CompletionDao`，避免长期上下文膨胀和上一轮命中串到下一轮。内置「小说大纲师 / 代码审查员 / 英语口语陪练 / 情绪树洞」已加入示例记忆条目。已通过 `dart analyze` 相关文件、`flutter test test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（30 tests）和 `git diff --check`。
- 2026-07-04 角色卡导入 / 导出 v1 已落地：新增 `AssistantRoleCardService`，定义 `chatai_deep_assistant_card` v1 JSON 格式，导出只包含可分享字段（名称、emoji、简介、系统提示词、开场白、示例对话、世界书、默认语音、provider/model、工具开关与工具 id），不携带数据库 `id/createdAt/updatedAt`；导入时始终作为新助手插入，避免覆盖本地已有角色。助手管理页新增「导入角色卡（.json）」入口，导入前展示简介、提示词长度、开场白、世界书条数和默认语音；每个助手更多菜单新增「导出角色卡」，生成临时 JSON 文件并走系统分享。已通过 `dart analyze` 相关文件、`flutter test test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（35 tests）和 `git diff --check`。
- 2026-07-04 Tavern / SillyTavern JSON 角色卡导入兼容已补齐：`AssistantRoleCardService.importJson` 除自有 `chatai_deep_assistant_card` 外，也能识别 SillyTavern `character_card_v2` 常见的 `spec/data` 包装、`data` 角色体，以及 Tavern 直出字段；`description/personality/scenario/system_prompt/post_history_instructions` 会按段落合并为系统提示词，`first_mes` 映射开场白，`mes_example` 映射示例对话，`character_book.entries` 会转成当前世界书格式（常驻条目保留为常驻设定，关键词条目转为 `关键词 => 内容`，禁用条目跳过）。导入后仍走现有安全清洗策略，不默认保留工具、模型覆盖或默认语音。已通过 `dart analyze chatgpt_app_core/lib/chat/application/assistant_role_card_service.dart chatgpt_app_core/test/assistant_role_card_service_test.dart` 和 `flutter test test/assistant_role_card_service_test.dart test/assistant_test.dart test/assistant_market_page_test.dart test/assistant_profile_page_test.dart`（37 tests）。
- 2026-07-04 PNG 角色卡元数据导入已落地：助手管理页导入入口从 `.json` 扩展为 `.json/.png`；`AssistantRoleCardService.importBytes` 会识别 PNG 签名并扫描 `tEXt` / `iTXt` / `zTXt` 文本块，读取常见 `chara` / `chara_card` / `character` / `ccv3` 关键字，支持明文 JSON 与 base64 JSON，再复用同一套 Tavern / SillyTavern / 自有 JSON 导入解析。PNG 中没有可识别角色卡元数据时会给出格式错误，不会误导入普通图片。已通过 `dart analyze chatgpt_app_core/lib/chat/application/assistant_role_card_service.dart chatgpt_app_core/lib/pages/assistant_list_page.dart chatgpt_app_core/test/assistant_role_card_service_test.dart` 和 `flutter test test/assistant_role_card_service_test.dart test/assistant_test.dart test/assistant_market_page_test.dart test/assistant_profile_page_test.dart`（39 tests）。
- 2026-07-05 角色卡 ZIP 导入已补齐：个人中心进入的「助手管理」导入入口扩展为 `.json/.png/.zip`；`AssistantRoleCardService.importPackageBatchBytes` 会识别 ZIP，并在压缩包内批量解析所有可导入的 `.json` / `.png` 角色卡，继续复用 Tavern / SillyTavern / 自有 JSON 与 PNG metadata 解析，不会把 ZIP 内其它文件当技能或脚本执行。ZIP 内如果是 PNG 角色卡，UI 会沿用解析结果里的 PNG bytes 保存为本地助手头像；多卡 ZIP 会展示批量确认弹窗并一次导入全部，每张成功卡会显示来源文件名，若包内有坏卡会在预览里列出前 3 个跳过文件的文件名和原因，导入完成反馈也会说明跳过数量。旧 `importBytes` 单卡接口仍保持取第一张以兼容现有调用。ZIP 中没有可导入角色卡时会给出格式错误。已补 `assistant_role_card_service_test.dart` 覆盖 ZIP 正常导入、ZIP 内 PNG 头像 bytes、多角色卡批量解析、成功来源文件名、跳过明细和空包拒绝。
- 2026-07-05 角色资料页可保存为会话模板：资料页新增「保存为会话模板」入口，会把当前角色保存为「角色场景」分类的 `WorkflowTemplate`，携带角色名、项目名、system prompt、provider/model 覆盖、工具绑定和以开场白生成的首条用户提示。保存后的模板进入现有 `WorkflowTemplateStore`，后续可在 AI 能力中心复用同一工作流启动通路，把角色卡和会话模板能力串起来。2026-07-05 继续补齐模板中心展示：角色场景模板卡会显示角色、项目、provider/model、工具和开场提示，并使用角色场景图标，保存后回到 AI 能力中心能一眼确认启动上下文。2026-07-05 继续补齐模板回到角色资料：角色场景模板卡新增「查看角色资料」按钮，默认会按模板角色名和 system prompt 在本地助手库查找对应角色，找到后打开现有角色资料页并带入最近长期记忆，找不到则给出提示。2026-07-05 继续补齐模板编辑：自定义模板更多菜单新增「编辑」，可修改标题、分类、项目名、助手名、provider/model、工具 ID、系统提示和首条提示，保存后保留原模板 id 并刷新卡片。已补 `assistant_profile_page_test.dart` 覆盖模板字段构造与保存反馈，`workflow_template_store_test.dart` 覆盖模板 update，`capability_center_page_test.dart` 覆盖角色场景模板展示、查看角色资料动作、编辑和启动。
- 2026-07-04 PNG 角色卡头像保存已落地：`AssistantModel` / `tb_assistant` 新增 `avatarType/avatarValue`，旧助手表自动补列；PNG 角色卡导入成功后，会把原 PNG bytes 保存到应用文档目录 `chat_avatar/<account>/assistant_<name>_<ts>.png`，并将助手头像设为本地 image。助手管理列表和角色资料页会优先显示该本地头像，缺失时回退 emoji；普通 JSON 导入仍不携带本地图片路径，避免分享本机私有路径。已通过 `dart analyze chatgpt_app_core/lib/model/assistant_model.dart chatgpt_app_core/lib/db/assistant_dao.dart chatgpt_app_core/lib/util/avatar_asset_service.dart chatgpt_app_core/lib/pages/assistant_list_page.dart chatgpt_app_core/lib/pages/assistant_profile_page.dart chatgpt_app_core/test/assistant_test.dart chatgpt_app_core/test/assistant_role_card_service_test.dart` 和 `flutter test test/assistant_test.dart test/assistant_role_card_service_test.dart test/assistant_profile_page_test.dart test/assistant_market_page_test.dart`（42 tests）。
- 2026-07-04 角色卡详情预览与摘要统计已补齐：`AssistantRoleCardService.summarize` 统一计算提示词字数、开场白字数、示例对话行数、世界书总条数、常驻/关键词条目数、工具绑定数、默认语音和模型覆盖状态；`parseMemoryEntries` 可把世界书解析为可展示条目。2026-07-05 继续补齐禁用世界书摘要：摘要模型新增 `disabledMemoryCount`，角色卡预览和角色资料页世界书入口在存在禁用条目时都会显示「禁用 N」，导入 Tavern 卡或查看资料页时即可知道哪些设定被保留但不会注入。助手管理页每个助手更多菜单新增「查看角色卡」，导入预览也复用同一套摘要与世界书前 5 条预览，避免导入、列表和详情统计口径不一致。已通过 `dart analyze` 相关文件、`flutter test test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（37 tests）和 `git diff --check`；资料页补齐另通过 `dart analyze chatgpt_app_core/lib/pages/assistant_profile_page.dart chatgpt_app_core/test/assistant_profile_page_test.dart` 与 `flutter test test/assistant_profile_page_test.dart`。
- 2026-07-04 世界书命中可视化已落地：`AssistantRoleCardService.matchMemoryEntries` 复用角色卡世界书解析规则，按当前用户输入返回常驻设定与命中关键词条目，并做去重和限量；`ConversationPage` 发送消息时记录本轮命中的角色记忆，在当前用户气泡下展示「命中角色记忆 N 条」和前 3 条内容，超过部分显示剩余数量。2026-07-05 继续统一命中摘要：会话气泡标题会显示 `命中角色记忆 N 条（常驻 X / 关键词 Y）`，条目预览复用 `AssistantRoleCardService.memoryHitPreviewLine` 压缩空白并截断长内容；资料页上下文预览也复用同一套摘要和条目预览方法，避免两处口径漂移。2026-07-05 继续补齐会话内复制：用户气泡下的命中面板新增「复制命中摘要」按钮，会复制摘要和全部命中条目，便于真实聊天中排查角色世界书触发；复制文本保留完整归一化内容，屏幕预览才截断。2026-07-05 继续补齐展开/收起：命中超过 3 条时默认只展示前 3 条，提供「展开全部 N 条 / 收起命中设定」切换，避免世界书命中较多时撑高聊天流。该提示只影响当前会话 UI，不写入消息历史、不改变模型请求协议；真正注入给模型的上下文仍由 `AssistantModel.systemPromptFor(inputMessage)` 负责。已通过 `dart analyze` 相关文件、`flutter test test/assistant_role_card_service_test.dart test/assistant_profile_page_test.dart` 和 `git diff --check`。
- 2026-07-05 继续补齐发送前世界书可见性：会话页「下一轮上下文」弹窗的摘要会随模拟用户输入实时展示「世界书：本轮命中 N 条 / 本轮未命中」，并列出前 3 条命中预览；用户无需先发送消息，也能确认当前输入会触发哪些 Tavern 世界书设定。
- 2026-07-05 继续增强 Tavern 世界书触发规则：世界书行支持 `[re]` / `[regex]` 前缀表示关键词按正则匹配；导入 SillyTavern / Tavern `character_book.entries` 时，若条目带 `regex` / `use_regex` / `extensions.regex`，会自动保留为正则触发。发送前预览、用户气泡命中面板和真实 `systemPromptFor` 注入共用同一触发语义，避免预览与请求漂移。
- 2026-07-05 继续增强 Tavern 世界书结构兼容：导入 SillyTavern / Tavern `character_book.entries` 时，除标准数组外，也支持按 id/uid 建立的对象映射结构；映射值为条目对象时会按 key 稳定排序后导入，并继续保留常驻、禁用、优先级、正则、二级触发、大小写敏感和整词匹配。已补 `assistant_role_card_service_test.dart` 覆盖对象映射 entries。
- 2026-07-05 继续增强 Tavern 世界书排序兼容：导入世界书条目时，除 `priority` 外，也会把 `order`、`insertion_order`、`insertionOrder` 作为移动端 `[p=...]` 优先级兜底；若 `priority` 明确存在则优先使用 `priority`，避免覆盖原始语义。已补 `assistant_role_card_service_test.dart` 覆盖 order 兜底与 priority 优先。
- 2026-07-05 继续增强 Tavern 世界书禁用语义兼容：导入世界书条目时，除 `enabled:false` 外，也会识别 `disable:true`、`disabled:true` 以及 `extensions.enabled:false / extensions.disable:true / extensions.disabled:true`，统一保存为 `[off]`，避免外部卡的禁用设定在移动端误注入。已补 `assistant_role_card_service_test.dart` 覆盖禁用别名和命中跳过。
- 2026-07-05 继续补齐 Tavern selective 世界书语义：世界书行支持 `[sec=关键词1|关键词2]` 二级触发条件；导入 `selective=true` 且包含 `secondary_keys` 的条目时，主关键词和二级关键词会分开保存，只有两者都命中才注入。非 selective 条目继续保持旧行为，把 secondary keys 合并为普通触发词，兼容已导入旧卡。
- 2026-07-05 继续增强 Tavern 世界书匹配开关：世界书行支持 `[cs]` 区分大小写和 `[ww]` 整词匹配；导入 `case_sensitive` / `caseSensitive`、`match_whole_words` / `matchWholeWords` 时会自动保留这些开关。发送前预览、气泡命中摘要和真实 `systemPromptFor` 注入共用同一匹配语义。
- 2026-07-05 继续补齐 Tavern 世界书扫描范围：发送消息时，角色世界书不再只扫描当前用户输入，而是用最近 6 条非空聊天消息 + 当前输入组成扫描文本；真实 `systemPromptFor` 注入、用户气泡下命中摘要和会话页「下一轮上下文」弹窗共用同一份扫描文本，减少跨轮上下文触发漏判，也避免预览与真实请求不一致。
- 2026-07-05 继续收紧 Tavern 世界书注入预算：`AssistantMemoryBook.buildContext` 新增默认 2400 字符上限，真实写入 system prompt 的 `[当前命中的角色记忆]` 会按优先级和命中顺序裁剪，超长条目截断、低优先级条目跳过；`match` 仍保留完整命中结果，便于 UI 摘要和复制调试包使用。2026-07-05 继续补齐预算可视化：新增 `AssistantMemoryBook.budgetContext` 返回命中数、注入数、跳过数和是否截断，`AssistantMemoryContextBudget.compactSummary` 统一输出 `注入 1/3 条，有截断，跳过 2 条` 这类摘要；会话页「下一轮上下文」摘要和用户气泡下命中面板都会在预算生效时显示该摘要，用户能区分“没命中”和“命中了但被预算裁剪”。2026-07-05 继续补齐调试包证据：会话发送时会记录当轮世界书预算结果，单条「复制调试包」和整段「复制会话调试包」都会导出命中数、实际注入数、跳过数、截断状态和字符预算，便于复现角色崩坏或设定未生效问题。2026-07-05 继续补齐持久化快照：`RoleContextBlock` 新增可选 `memoryBudget` 和 `memoryHits` JSON 字段，预算证据与命中世界书条目会随用户消息 blocks 落库和备份恢复；重启 App 或跨设备恢复后，旧消息调试包和用户气泡下命中面板仍能保留当轮世界书命中与预算证据。
- 2026-07-04 助手长期记忆 v1 已落地：新增 `AssistantMemoryModel` / `AssistantMemoryDao` 和 `tb_assistant_memory`，按 `assistantId` 保存手动记忆，支持倒序读取、删除和 `[长期记忆]` system prompt 片段构造；`ConversationPage` 初始化会加载当前助手最近记忆，并与角色 system prompt / 世界书命中一起注入首轮请求。会话内长按已持久化消息时，在绑定助手的会话里新增「记住」菜单，弹窗允许编辑要保存的事实或偏好，保存后刷新当前助手记忆；切换助手时会重新加载对应长期记忆。已通过 `dart analyze` 相关文件、`flutter test test/assistant_memory_dao_test.dart test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（42 tests）和 `git diff --check`。
- 2026-07-04 助手长期记忆管理页已补齐：新增「助手管理 → 更多 → 长期记忆」，可查看、手动新增、编辑和删除某个助手的长期记忆；页面依赖 `IAssistantMemory` 接口，生产环境使用 `AssistantMemoryDao`，widget 测试使用内存 fake，避免真实 `sqflite` timer 干扰页面测试。保存/删除后页面会乐观刷新列表，再异步落库并显示反馈，减少用户等待感。已通过 `dart analyze chatgpt_app_core/lib/pages/assistant_memory_page.dart chatgpt_app_core/test/assistant_memory_page_test.dart`、`flutter test test/assistant_memory_page_test.dart` 和助手整组回归 `flutter test test/assistant_memory_page_test.dart test/assistant_memory_dao_test.dart test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（44 tests）。
- 2026-07-04 长期记忆管理页摘要与搜索已补齐：页面顶部展示总条数、手动条数、自动建议条数和对话来源条数，并提供本地搜索框，可按记忆内容或来源说明过滤；无匹配时展示空结果文案。2026-07-05 继续补齐搜索清空按钮，输入搜索词后右侧显示「清空搜索」，一键恢复全量长期记忆列表。这样长期记忆增多后，用户仍能快速定位某条偏好、身份或关系状态，并和世界书管理页保持一致的移动端搜索体验。已补 `assistant_memory_page_test.dart` 摘要、内容搜索、来源搜索、清空搜索和空结果回归。
- 2026-07-05 长期记忆编辑防呆已补齐：新增/编辑长期记忆时，如果「记忆内容」为空，弹窗不会关闭，也不会写入 DAO，而是在输入框下直接显示「请填写记忆内容」；用户继续输入后错误提示自动消失。这样和世界书编辑保持一致，移动端误触保存时能立刻知道需要补内容。已补 `assistant_memory_page_test.dart` 空内容保存回归。
- 2026-07-05 长期记忆手动去重已补齐：长期记忆管理页新增/编辑保存前会复用 `AssistantMemoryDao.hasDuplicateContent` 做本地去重；新增重复内容时提示「这条长期记忆已存在」并跳过保存，编辑当前条目保持原内容仍允许保存。DAO 的内容归一化升级为忽略所有空白差异，适配中文记忆里误插空格/换行的常见情况。已补 `assistant_memory_page_test.dart` 重复新增与原条目编辑回归，并补 `assistant_memory_dao_test.dart` 中间空白去重断言。
- 2026-07-04 长期记忆条目复制已补齐：长期记忆列表每条记忆右侧新增「复制记忆」按钮，只复制记忆正文，不带来源或日期；复制后显示「长期记忆已复制」。这样用户在检查角色记忆时能快速复制单条事实、偏好或关系状态用于调试/分享。已补 `assistant_memory_page_test.dart` 剪贴板回归。
- 2026-07-04 世界书管理页与长期记忆去重已补齐：新增「助手管理 → 更多 → 世界书」，可按条目查看、新增、编辑和删除轻量世界书设定；关键词为空时保存为常驻设定，已有注释行会保留，避免管理单条设定时破坏用户手写备注。助手列表更多菜单现在把「世界书」与「长期记忆」分开，分别对应“当前轮关键词触发设定”和“跨轮长期事实”。会话长按「记住」保存长期记忆时会用 `AssistantMemoryDao.hasDuplicateContent` 做 trim/空白归一化去重，避免短时间重复保存同一条内容；保存弹窗也改为自管理 controller 生命周期。已通过 `dart analyze` 相关文件、`flutter test test/assistant_world_book_page_test.dart test/assistant_memory_dao_test.dart test/assistant_memory_page_test.dart test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（47 tests）和 `git diff --check`。
- 2026-07-04 世界书规则增强已落地：轻量世界书行格式在旧的 `关键词 => 内容` / 常驻行基础上，新增可选前缀 `[off]` 禁用条目、`[p=数字]` 设置优先级；请求侧 `AssistantMemoryBook.match` 会跳过禁用条目，并在命中后按优先级从高到低注入，同优先级保留原始顺序。世界书管理页新增「启用条目」开关和「优先级」输入框，列表会展示启用/禁用状态和优先级；角色卡预览层也会显示禁用/优先级，并按同样规则做命中预览。旧世界书文本完全兼容。已通过 `dart analyze chatgpt_app_core/lib/model/assistant_model.dart chatgpt_app_core/lib/chat/application/assistant_role_card_service.dart chatgpt_app_core/lib/pages/assistant_world_book_page.dart chatgpt_app_core/test/assistant_test.dart chatgpt_app_core/test/assistant_role_card_service_test.dart chatgpt_app_core/test/assistant_world_book_page_test.dart` 和 `flutter test test/assistant_test.dart test/assistant_role_card_service_test.dart test/assistant_world_book_page_test.dart test/assistant_profile_page_test.dart`（41 tests）。
- 2026-07-04 世界书管理页摘要与搜索已补齐：页面顶部展示总条数、常驻条数、关键词条数和禁用条数，并提供本地搜索框，可按关键词或设定内容过滤条目；无匹配时展示空结果文案。2026-07-05 继续补齐搜索清空按钮，输入搜索词后右侧显示「清空搜索」，一键恢复全量世界书列表。这样角色世界书条目增多后，用户仍能在移动端快速定位设定并快速退出过滤状态。已补 `assistant_world_book_page_test.dart` 摘要、关键词搜索、内容搜索、清空搜索和空结果回归。
- 2026-07-05 世界书编辑防呆已补齐：新增/编辑世界书设定时，如果「设定内容」为空，弹窗不会关闭，也不会写入助手，而是在输入框下直接显示「请填写设定内容」；用户继续输入后错误提示自动消失。这样移动端误触保存时能获得即时反馈，避免“点了保存但列表没变化”的困惑。已补 `assistant_world_book_page_test.dart` 空内容保存回归。
- 2026-07-05 世界书手动去重已补齐：世界书管理页新增/编辑保存前会按设定内容做本地去重；新增重复内容时提示「这条世界书设定已存在」并跳过保存，编辑当前条目保持原内容仍允许保存。去重会忽略空白差异，关键词变化但内容相同时也视为重复，避免同一设定被多条关键词分散污染角色上下文。已补 `assistant_world_book_page_test.dart` 重复新增与原条目编辑回归。
- 2026-07-04 世界书条目复制已补齐：世界书列表每条设定右侧新增「复制设定」按钮，会复制该条设定的规范行文本，保留 `[off]`、`[p=数字]`、关键词和内容，便于用户调试、迁移或分享单条角色设定；复制后显示「世界书设定已复制」。已补 `assistant_world_book_page_test.dart` 剪贴板回归。
- 2026-07-04 自动建议长期记忆 v1 已落地：新增 `AssistantMemorySuggestionService`，在用户消息包含明显长期偏好、身份、目标或显式「请记住」时生成本地候选，不调用模型、不增加 token 成本；普通问题、过长文本和已存在记忆会跳过。会话页会在对应用户气泡下展示「建议记住」面板，用户点击「记住」后仍会进入可编辑确认弹窗，确认后才写入 `tb_assistant_memory`，点击「忽略」只隐藏当前候选，不改消息历史或请求协议。候选保存的来源标记为 `suggestion`，长期记忆管理页显示「来自自动建议」。已通过 `dart analyze` 相关文件、`flutter test test/assistant_memory_suggestion_service_test.dart test/assistant_memory_page_test.dart test/assistant_memory_dao_test.dart test/assistant_world_book_page_test.dart test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart`（52 tests）和 `git diff --check`。
- 2026-07-04 角色卡导入安全选项已补齐：导入外部角色卡时，预览弹窗会把工具绑定/工具开关、provider/model 覆盖、默认语音列为高影响字段，默认不导入这些字段；用户明确勾选「保留工具绑定 / 工具开关」「保留模型覆盖」「保留默认语音」后才会带入。新增 `AssistantRoleCardService.sanitizeForImport` 统一清洗规则，确保外部角色卡默认只导入角色文本、开场白、示例对话和世界书，不会静默改变工具暴露范围、切换不可用模型或引用本机不存在的自定义音色。已通过 `dart analyze` 相关文件、`flutter test test/assistant_role_card_service_test.dart test/assistant_test.dart test/builtin_assistants_test.dart test/assistant_market_page_test.dart test/assistant_world_book_page_test.dart test/assistant_memory_page_test.dart test/assistant_memory_suggestion_service_test.dart`（49 tests）和 `git diff --check`。
- 2026-07-04 会话内角色资料页已落地：`ConversationPage` 在绑定助手时新增「角色资料」入口，打开 `AssistantProfilePage` 后可查看角色简介、角色卡摘要、开场白/示例对话统计、模型覆盖、默认语音、世界书摘要、最近长期记忆和工具绑定，并可继续跳转编辑角色、管理世界书或长期记忆；返回会话后会重新加载当前助手和记忆，保证编辑后的资料进入下一轮请求上下文。2026-07-05 继续补齐会话页「下一轮上下文」：绑定角色时 AppBar 新增上下文预览入口，弹窗可输入模拟下一条用户消息，直接展示下一轮真实会组装进 system prompt 的角色卡/世界书、当前会话状态和长期记忆，并支持复制；发送链路和预览链路共用 `ConversationRoleContextPreview.build`，避免调试文本与真实请求漂移。2026-07-05 继续补齐发送后快照：发送消息时会把当轮 `assistantSystemPrompt` 写入用户消息的 `RoleContextBlock`，重启 App 后也能从消息 blocks 恢复；用户气泡下显示「本轮完整上下文」，默认折叠，可展开或复制该轮真实注入文本，后续修改角色卡/世界书/记忆不会改变旧气泡快照。2026-07-05 继续补齐备份恢复覆盖：`RoleContextBlock` 随 `tb_messages.blocks` 写入备份并在导入后可 decode 恢复，跨设备迁移也保留角色调试证据。2026-07-05 继续补齐「复制调试包」：用户气泡长按菜单在存在本轮上下文/世界书命中/会话状态时显示「复制调试包」，会复制角色信息、用户消息、会话状态、命中世界书、最近长期记忆和本轮完整上下文；绑定角色的会话 AppBar 也新增「复制会话调试包」，可一次复制整段会话内所有用户轮次的上下文快照、世界书命中、角色状态和最近长期记忆，便于排查角色崩坏或分享复现材料。2026-07-05 继续补齐对话沉淀示例：绑定角色时，气泡长按菜单新增「存为示例对话」，保存助手回复会自动带上前一条用户消息，保存用户消息会优先带上后一条助手回复，并允许保存前编辑；保存后追加到当前角色 `exampleDialogs`，导出角色卡和下一轮上下文都会带上该样例。新增 `assistant_profile_page_test.dart` 覆盖资料摘要、世界书/长期记忆/工具展示和编辑入口，`conversation_role_context_preview_test.dart` 覆盖会话页下一轮上下文组装，`conversation_role_debug_export_test.dart` 覆盖单条和会话调试包文本，`block_message_test.dart` 和 `block_message_content_test.dart` 覆盖快照 block 持久化与渲染，`backup_test.dart` 覆盖快照 block 备份恢复。
- 2026-07-04 角色资料页返回刷新已补齐：资料页从「编辑角色」「世界书」「长期记忆」返回后会刷新当前页面展示；编辑返回时会重绘角色简介/开场白等本地对象字段，长期记忆返回时会重新读取该助手最近 8 条记忆，世界书返回时会重新计算角色卡摘要和世界书预览，避免用户新增/修改内容后资料页仍显示旧信息。`AssistantProfilePage` 支持注入 `AssistantProfileEditor`、`IAssistantMemory` 和 `AssistantWorldBookSaver` 便于 widget 测试，生产路径仍使用真实编辑页和账号 DB DAO。已补 `assistant_profile_page_test.dart` 覆盖编辑返回、长期记忆返回、世界书返回三类刷新。
- 2026-07-05 角色资料页长期记忆来源摘要已补齐：长期记忆入口副标题从单纯数量升级为来源分布，例如 `3 条最近记忆（手动 1 / 自动建议 1 / 对话 1）`；最近长期记忆预览也会显示「手动添加 / 来自自动建议 / 来自用户消息 / 来自助手回复」来源标签，并在页面预览时归一化换行/多空格。2026-07-05 继续补齐「复制长期记忆摘要」：资料页可复制角色名、最近记忆来源统计和当前已加载的最近长期记忆列表，内容会归一化空白，方便移动端排查角色记忆污染或分享给他人核对。这样用户在资料页就能判断某条记忆是自己手动维护、系统建议，还是从对话中沉淀出来的，减少移动端进入管理页二次确认。已补 `assistant_profile_page_test.dart` 来源摘要、来源标签和复制回归，并通过 `dart analyze chatgpt_app_core/lib/pages/assistant_profile_page.dart chatgpt_app_core/test/assistant_profile_page_test.dart` 与 `flutter test test/assistant_profile_page_test.dart`。
- 2026-07-05 角色资料页下一轮上下文影响摘要已补齐：资料页在「上下文预览」入口下方新增「下一轮上下文影响」区块，直接展示角色卡系统提示词是否会注入、世界书常驻/关键词/禁用条目的注入规则、当前会话状态是否会注入、最近长期记忆是否会注入。用户无需打开预览弹窗，也能先知道下一轮对话会受哪些角色数据影响；需要看完整文本时仍可进入「上下文预览」。2026-07-05 继续补齐「复制影响摘要」按钮，会把角色名和四类影响说明复制成文本，便于移动端调试角色卡或发给他人排查。已补 `assistant_profile_page_test.dart` 影响摘要和复制回归，并通过 `dart analyze chatgpt_app_core/lib/pages/assistant_profile_page.dart chatgpt_app_core/test/assistant_profile_page_test.dart` 与 `flutter test test/assistant_profile_page_test.dart`。
- 2026-07-04 Tavern 角色卡兼容性继续增强：`AssistantRoleCardService` 导入 SillyTavern / Tavern V2/V3 风格角色卡时，会把 `tags` 合并到角色简介，把 `alternate_greetings` 追加到示例对话预览；世界书导入不再静默丢弃禁用条目，而是保留为 `[off]`，并保留 `priority` 为 `[p=数字]`，同时合并 `keys` / `key` / `secondary_keys` 便于移动端管理页继续编辑。角色卡预览弹窗也会显示最多 3 段示例/备选开场片段，导入前能看见角色说话方式。2026-07-05 继续补齐 Tavern 占位符归一化：导入时会把 `{{char}}` / `<BOT>` 替换为角色名，把 `{{user}}` / `<USER>` 替换为「用户」，覆盖提示词、简介兜底、开场白、示例对话、备选开场和世界书内容/关键词，避免移动端导入后直接露出模板变量。2026-07-05 继续补齐多语言核心字段：`system_prompt`、`description`、`personality`、`scenario`、`post_history_instructions`、`first_mes`、`mes_example` 若是多语言对象，也会按中文优先、英文/default 兜底解析。2026-07-05 继续补齐备选开场使用：`AssistantConversationFactory.openingMessageCandidates` 会把主开场和 `[备选开场白]` 候选去重合并；从会话列表或助手管理页启动绑定角色的新会话时，若存在多个候选，会弹出「选择开场白」，也可选择不使用开场白。已补 `assistant_role_card_service_test.dart` 覆盖 tags、备选开场白、禁用/优先级世界书、secondary key 兼容、示例预览拆分、占位符替换、多语言核心字段和备选开场提取，`assistant_test.dart` 覆盖开场候选排序与默认选择。
- 2026-07-05 Tavern 备选开场兼容继续增强：导入 `alternate_greetings` 时，除标准数组外，也支持单个字符串、换行字符串和多语言对象；多语言对象会按中文优先、英文/default 兜底选择对应字符串或数组。导入会统一替换 `{{char}}` / `{{user}}` / `<BOT>` / `<USER>` 占位符，并按归一化空白去重。已补 `assistant_role_card_service_test.dart` 覆盖字符串/换行/多语言对象备选开场。
- 2026-07-05 角色卡导入冲突处理已补齐：助手管理页导入单张或 ZIP 批量角色卡时，会在保存前检查现有助手名和本批次已导入名称，重名自动改为 `角色名 (2)` / `角色名 (3)`，避免外部卡覆盖或挤掉同名角色；单卡预览会显示「原名称 / 导入后名称」，批量预览会在列表中显示最终名称和原名，头像文件保存也会使用最终导入名。已补 `assistant_role_card_service_test.dart` 覆盖唯一导入命名规则。
- 2026-07-05 重名角色卡导入策略继续补齐：导入预览在检测到同名助手时新增「另存为新角色 / 覆盖同名角色」单选；默认仍另存为带编号的新角色，选择覆盖时会更新已有助手记录并保留原助手 id、名称和会话绑定。覆盖 JSON 角色卡但不带 PNG 头像时，会保留已有助手头像；带 PNG 头像时才替换头像。
- 2026-07-05 同名角色卡更新体验继续补齐：重名导入策略新增「覆盖并合并世界书」，会更新已有助手内容并保留原助手 id / 名称 / 会话绑定，同时把旧世界书中未与新卡重复的条目保留下来；重复判断按设定内容归一化空白，导入行上的 `[off]`、`[p=]`、`[sec=]`、正则等 Tavern 元标记会保留。已补 `assistant_role_card_service_test.dart` 覆盖世界书合并去重。
- 2026-07-05 世界书合并可见性继续增强：`AssistantRoleCardService.mergeMemoryBookPreview` 会返回合并后的文本、旧条目数、新卡条目数、追加数、重复跳过数和无效跳过数；单卡和 ZIP 批量导入在选择「覆盖并合并世界书」时会展示类似「保留旧 2 / 追加新 1 / 跳过重复 1」的摘要，导入前即可判断合并影响范围。
- 2026-07-05 世界书合并明细预览继续补齐：合并预览会保留实际追加的原始世界书行，单卡导入选择「覆盖并合并世界书」时会展示前 3 条「将追加」内容，超出时显示剩余数量；重复条目不会出现在追加明细里。
- 2026-07-05 覆盖导入安全边界继续收紧：同名角色卡选择「覆盖同名角色」或「覆盖并合并世界书」时，默认保留本地已有工具绑定/工具开关、模型覆盖和默认语音；只有用户在导入安全选项里勾选保留外部卡对应配置时，才会用外部卡替换这些高影响字段，避免更新角色设定时误清掉本机音色或模型路由。
- 2026-07-05 角色卡导入完成反馈继续优化：单卡导入完成弹窗会区分「添加」和「更新」；ZIP 批量导入完成提示会按本次操作统计「新增 N 张 / 更新 N 张 / 跳过 N 个文件」，不再把覆盖更新统一说成“已导入”。
- 2026-07-05 导入反馈口径回归风险继续降低：角色卡导入结果文案已下沉为 `AssistantRoleCardService.importResultText` 纯函数，并补测试覆盖新增、更新、混合跳过和空结果；助手管理页只负责统计数量后调用该函数。
- 2026-07-05 覆盖导入安全选项文案继续修正：重名导入弹窗会明确提示“覆盖时默认保留本地工具、模型和语音设置”；安全选项从“保留工具/模型/语音”改为“使用外部卡工具/模型/语音”，避免用户误以为勾选是在保留本地配置。
- 2026-07-05 ZIP 批量角色卡冲突可见性继续增强：批量导入预览在存在重名卡时会先显示“`N` 张与现有助手重名，重名处理策略会应用到这些角色卡”，不用逐行扫列表才能发现覆盖/另存风险。
- 2026-07-05 ZIP 批量角色卡导入可审计性继续增强：`AssistantRoleCardService.importPreviewSummaryText` 会生成统一的导入摘要，批量预览每张卡会展示提示词字数、开场状态、示例对话、备选开场、世界书常驻/关键词/禁用结构、工具/模型/语音高影响配置和头像标记；用户不必逐张打开单卡预览也能判断这批角色卡会带入什么能力。已补 `assistant_role_card_service_test.dart` 覆盖摘要文案。
- 2026-07-05 角色卡导入语言转换已补齐：单张和 ZIP 批量角色卡导入预览新增「使用当前 AI 配置翻译为简体中文」选项，默认关闭；勾选后保存前会调用当前 AI 服务商，把 `name / description / prompt / openingMessage / exampleDialogs / memoryBook` 翻译为简体中文，再进入原有安全清洗和重名处理。导入确认后不会用同步弹窗阻塞用户，助手列表顶部会立刻出现后台任务记录，单卡展示当前阶段，ZIP 批量展示第几张/总数和当前角色名；后台任务由页面外 `_RoleCardImportCoordinator` 持有，离开助手列表页也不会中断，返回页面仍能看到失败记录。成功后任务行移除并刷新真实助手，失败时不写入助手表，任务行保留失败记录和「查看日志 / 移除记录」操作；角色卡翻译通过 `ChatService.chat(timeout:)` 使用 2 分钟专用超时，后端代理默认非流式超时也提升到 2 分钟，`openai_flutter` 直连底层 `AIHttp.post` 已接收可选 timeout，避免任一路径被原 15 秒默认值截断长文本翻译；非 JSON 翻译返回会在日志里带返回内容预览，方便定位 provider 输出格式问题。翻译服务不会接收或应用工具 ID、模型 ID、服务商 ID、默认语音、头像和数据库字段；ZIP 批量会逐张调用 AI，并在 UI 文案中提示耗时与用量成本。已补 `assistant_role_card_translation_service_test.dart` 覆盖 JSON 提取、字段白名单、缺失字段回退和运行配置不被覆盖。
- 2026-07-05 世界书运行时调试继续补齐：`AssistantWorldBookPage` 新增「输入一句话试触发世界书」输入框，会复用 `AssistantRoleCardService.matchMemoryEntries` 按真实运行时规则预览命中的常驻/关键词记忆，包含优先级排序、禁用条目跳过、正则和二级触发等兼容逻辑；无命中时显示“本句不会注入世界书”。命中时可一键复制摘要，复制文本复用 `AssistantRoleCardService.memoryHitCopyText`，方便排查或分享当前触发结果。已补 `assistant_world_book_page_test.dart` 覆盖常驻 + 关键词命中、禁用跳过、清空输入和复制摘要。
- 2026-07-05 角色资料页开场可见性继续增强：`AssistantProfilePage` 的角色卡区域在显示「备选开场 N 条」之外，会直接展示最多 3 条备选开场内容，超出时提示剩余数量；导入 Tavern / SillyTavern 卡后不用进入编辑页也能确认 `alternate_greetings` 是否解析正确。资料页「保存为会话模板」也会把备选开场写入模板首轮提示，后续从模板启动角色场景时不会只保留主开场；`WorkflowTemplateLauncher.ensureAssistantForTemplate` 在创建或复用模板助手时，会从模板首轮提示里回填主开场和备选开场到助手本身，避免模板创建的角色后续缺少开场候选。已补 `assistant_profile_page_test.dart` 覆盖备选开场内容展示和模板首轮提示，`workflow_template_launcher_test.dart` 覆盖新建助手与旧助手补齐。
- 2026-07-05 Tavern 双向互通继续补齐：新增 `AssistantRoleCardService.exportTavernV2Json` 和 `tavernFilenameFor`，可将本地助手导出为 SillyTavern `chara_card_v2` JSON；导出时会把本地分段 prompt 反向拆成 `system_prompt / description / personality / scenario / post_history_instructions`，把可注入示例对话写入 `mes_example`、备选开场写入 `alternate_greetings`，并把轻量世界书反向转成 `character_book.entries`，保留常驻、禁用、优先级、正则、selective 二级触发、大小写敏感和整词匹配。本应用私有元信息写入 `extensions.chatai_deep`，导入时可读回默认音色、provider/model 覆盖、工具开关和工具 ID，但仍由 `sanitizeForImport` 默认丢弃高影响字段，只有用户勾选保留才落库。助手管理页更多菜单新增「完整角色卡」和「Tavern V2 兼容」两个带副标题的导出入口，明确区分同款 App 备份/分享和 SillyTavern / 酒馆生态互通。已补 `assistant_role_card_service_test.dart` 覆盖 Tavern V2 导出结构、世界书字段、扩展元信息回读、默认清洗和导出格式说明文案。
- 2026-07-04 会话级角色状态已落地：`ConversationModel` / `tb_conversation_list` 新增 `roleScene`、`roleRelationship`、`roleToneNote`，集中迁移器与 DAO 均会自动补列；角色资料页在绑定会话时显示「当前会话状态」，可编辑当前场景、关系备注和语气备注。这些状态只作用于当前会话，不污染全局角色卡；下一次发送消息时会以 `[当前会话角色状态]` 拼入 system prompt，并与世界书命中、长期记忆一起参与当前轮上下文。已通过 `dart analyze` 相关文件、`flutter test test/assistant_profile_page_test.dart test/project_dao_test.dart test/assistant_role_card_service_test.dart test/assistant_memory_page_test.dart test/assistant_world_book_page_test.dart test/assistant_memory_suggestion_service_test.dart`（39 tests）和会话模型相关回归 `flutter test test/assistant_profile_page_test.dart test/project_dao_test.dart test/assistant_test.dart test/backup_test.dart test/local_sync_service_test.dart`（63 tests）。
- 2026-07-04 角色资料页状态保存反馈已打磨：`AssistantProfilePage` 改为保留本地角色状态副本，用户在「当前会话状态」弹窗保存后，不需要退出重进资料页即可立刻看到新的场景 / 关系 / 语气摘要；清空也会同步刷新页面展示。2026-07-05 继续补齐「复制会话状态摘要」：绑定会话且存在状态时，资料页会展示当前会话状态摘要，并可复制角色名、场景、关系和语气，方便排查单会话设定是否污染下一轮对话；复制文本格式已下沉到 `ConversationModel.roleStateCopyText`，后续会话气泡侧可复用同一格式。`assistant_profile_page_test.dart` 已覆盖保存回调、页面即时摘要更新和复制回归，`project_dao_test.dart` 覆盖复制文本格式；已通过 `dart analyze` 相关文件和 `flutter test test/assistant_profile_page_test.dart test/project_dao_test.dart`。
- 2026-07-04 会话状态草稿一键填入已落地：新增 `ConversationRoleStateSuggester`，从当前会话最近用户/助手消息本地生成可编辑草稿，不调用模型、不增加 token 成本；角色资料页的「当前会话状态」弹窗在有草稿时显示「从最近对话填入」，可一键填入当前场景、关系备注和语气备注，再由用户确认保存。草稿会优先保留用户已经手填的非空字段，只补空字段，避免覆盖已有设定。2026-07-04 已补可靠性修正：草稿生成器会按 `createdAt` 升序选择最近消息，不依赖 ChatList 当前列表顺序或倒序加载；测试覆盖乱序输入仍取最新用户/助手消息。2026-07-05 继续补齐气泡侧入口：绑定角色时，长按任意有内容的气泡可点「更新会话状态」，会用该气泡生成当前场景/关系/语气草稿并允许保存前编辑，保存后立即影响下一轮上下文。已通过 `dart analyze` 相关文件和 `flutter test test/conversation_role_state_suggester_test.dart test/assistant_profile_page_test.dart test/project_dao_test.dart`。
- 2026-07-04 会话角色状态注入已可视化：发送消息时如果当前会话配置了场景、关系或语气备注，会把当刻状态快照记录到当前用户气泡下，展示「已带入当前会话状态」和最多三条状态摘要；该提示只反映本轮实际注入，不写入消息历史，后续修改状态不会 retroactively 改旧气泡。2026-07-05 继续补齐会话侧复制：该面板新增「复制会话状态摘要」按钮，复制本轮状态快照，便于在真实聊天流里直接排查本轮带入了什么。2026-07-05 继续统一空白处理：`ConversationModel.roleStatePreviewLines` 会把场景 / 关系 / 语气里的换行和连续空白压缩为单空格，气泡预览、资料页复制、上下文预览和 `roleStateContext` 注入都使用同一份规范文本，但数据库仍保留用户原始输入。已通过 `dart analyze` 相关文件和 `flutter test test/project_dao_test.dart test/conversation_role_state_suggester_test.dart test/assistant_profile_page_test.dart`（23 tests）。
- 2026-07-04 角色资料页上下文预览已落地：`AssistantProfilePage` 新增「上下文预览」入口，底部弹窗可输入一条模拟用户消息，并即时展示本轮会拼入 system context 的角色卡基础提示词、命中的世界书条目、当前会话角色状态和长期记忆；该预览复用 `assistant.systemPromptFor`、`ConversationModel.roleStateContext` 与 `AssistantMemoryDao.buildSystemContext` 的真实组装格式，方便用户在发送前确认关键词世界书是否命中。2026-07-05 继续补齐预览弹窗命中摘要：模拟输入为空时会显示常驻世界书注入数量，输入关键词后会显示 `当前输入会注入世界书 N 条（常驻 X / 关键词 Y）`，并展示最多 3 条命中的世界书标签和内容片段；该摘要同样复用 `AssistantRoleCardService.matchMemoryEntries`，禁用条目不会被计入。已通过 `dart analyze chatgpt_app_core/lib/pages/assistant_profile_page.dart chatgpt_app_core/test/assistant_profile_page_test.dart` 和 `flutter test test/assistant_profile_page_test.dart`。
- 2026-07-04 角色卡导入后的首轮体验已补齐：新增 `AssistantConversationFactory` 统一“从助手创建会话”的字段映射，会话列表新建入口和助手管理导入成功后的启动入口都会继承助手 id、默认朗读音色、项目/模型/联网/工具配置和角色开场白。角色卡导入保存后会弹出「角色卡已导入」确认框，用户可直接点「开始对话」进入绑定该角色的新会话；从助手页启动时会给 `ConversationPage` 注入轻量 `conversationUpdate` 回调，确保用户发出第一条消息后新会话能正常落到会话列表。已通过 `dart analyze chatgpt_app_core/lib/chat/application/assistant_conversation_factory.dart chatgpt_app_core/lib/pages/assistant_list_page.dart chatgpt_app_core/lib/pages/conversation_list_page.dart chatgpt_app_core/test/assistant_test.dart` 和 `flutter test test/assistant_test.dart`（22 tests）。
- 2026-07-04 已有角色的一键开聊入口已补齐：助手管理页每个助手的更多菜单新增「开始对话」，复用角色卡导入后的 `_startConversationWithAssistant` 路径，直接创建绑定该助手的新会话并带入开场白与默认朗读音色；保留点击列表项进入编辑的原行为，避免把管理页变成单一聊天入口。已通过 `dart analyze chatgpt_app_core/lib/pages/assistant_list_page.dart chatgpt_app_core/lib/chat/application/assistant_conversation_factory.dart chatgpt_app_core/test/assistant_test.dart` 和助手相关回归测试。
- 2026-07-04 角色资料页开聊主动作已补齐：`AssistantProfilePage` 新增可选 `onStartConversation` 主按钮；助手管理页更多菜单新增「角色资料」，会读取该助手最近长期记忆后打开完整资料页，并在资料页顶部提供「开始对话」按钮，进入绑定该角色的新会话。这样用户既可以在列表快速开聊，也可以先检查人设、世界书、长期记忆和上下文预览后再开聊。已通过资料页 widget 回归与助手相关分析测试。
- 2026-07-04 角色头像已贯通到会话列表与对话气泡：`AssistantConversationFactory` 创建绑定助手的新会话时，会把助手 PNG 头像或 emoji 写入 `ConversationModel.avatarType/avatarValue`，因此从角色卡导入、助手列表、角色资料页开聊的新会话在会话列表中会显示角色头像；`ConversationPage` 生成 assistant 回复和临时开场白时会优先使用助手本地头像路径，`chat_message` 默认气泡头像渲染也支持本地文件路径，文件缺失时回退首字头像。已通过 `assistant_test.dart` 和 `chat_message_test.dart` 头像回归。
- 2026-07-04 角色上下文预览可复制已补齐：角色资料页「上下文预览」底部弹窗新增「复制上下文」按钮，会复制当前模拟用户输入下真实组装出的角色卡 system prompt、命中世界书、当前会话状态和长期记忆；复制后显示「上下文已复制」。2026-07-05 继续补齐「复制命中世界书」：同一弹窗可只复制当前模拟输入实际命中的世界书条目，内容复用 `AssistantRoleCardService.matchMemoryEntries` 与复制行格式，禁用条目和未命中关键词不会进入剪贴板；复制后显示「命中世界书已复制」。这让用户既能分享完整注入上下文，也能单独排查世界书关键词命中是否合理。已通过 `assistant_profile_page_test.dart` 剪贴板回归。
- 2026-07-04 角色卡摘要复制已补齐：角色资料页新增「复制角色卡摘要」入口，会复制可读文本版角色卡，包含名称、简介、系统提示词、开场白、示例对话、世界书条目、默认语音、模型覆盖和工具绑定；复制后显示「角色卡摘要已复制」。2026-07-05 继续统一世界书复制口径：角色卡摘要中的世界书行复用 `AssistantRoleCardService.memoryEntryCopyLine`，会保留优先级/禁用状态并归一化空白。这适合移动端快速分享/核对角色设定，不需要导出 JSON。已补 `assistant_profile_page_test.dart` 剪贴板回归。
- 2026-07-04 对话页角色身份副标题已补齐：绑定助手的会话页 AppBar 保留原有会话标题，并在标题下方显示角色简介；若角色没有简介，则显示世界书条数、长期记忆条数和默认语音状态。2026-07-05 继续收口顶部按钮：AppBar 只保留高频「切换助手」和「更多」，对话目录、角色资料、下一轮上下文、复制会话调试包和语音偏好折叠进更多菜单，避免按钮挤占会话标题展示空间。已通过 `conversation_page.dart` 静态分析。
- 2026-07-04 角色资料页可读性已优化：角色卡区域不再只展示开场白字数和示例对话行数，也会直接展示开场白正文与示例对话片段，让用户在资料页就能判断角色语气、人设是否可用。已补 `assistant_profile_page_test.dart` 渲染断言。
- 2026-07-04 角色资料页世界书预览已补齐：世界书入口下方会直接展示最多 3 条常驻/关键词记忆，包含关键词标签、优先级/禁用状态和内容片段；超过 3 条时提示还有多少条可进入世界书查看。2026-07-05 继续统一展示口径：资料页世界书预览复用 `AssistantRoleCardService.memoryHitPreviewLine`，和聊天命中面板/上下文预览一样压缩空白并截断长内容；资料页新增「复制世界书摘要」，会复制角色名、条数统计和全部世界书条目，保留优先级/禁用状态并归一化空白。2026-07-05 继续补齐对话内沉淀：绑定角色的会话气泡长按菜单新增「加入世界书」，可把任意用户/助手消息编辑为关键词或常驻设定，保存时会追加到当前角色 `memoryBook`、校验重复内容，并在下一轮请求中立即生效。这样用户无需打开编辑页，也能快速判断和沉淀角色设定。已补 `assistant_profile_page_test.dart` 渲染与复制断言，`assistant_role_card_service_test.dart` 覆盖世界书条目格式化、追加和去重。
- 2026-07-03 复验「会话内切换模型」可靠性证据：`flutter test test/assistant_test.dart test/model_picker_presenter_test.dart test/model_capabilities_test.dart test/project_dao_test.dart` 通过 62 个测试，覆盖助手 provider/model 覆盖、模型选择器最近使用排序/搜索/可用状态/能力位过滤、模型能力位加法合并、会话级模型覆盖恢复跟随全局。
- 2026-07-03 复验「写工具确认弹窗」可靠性证据：`flutter test test/assistant_write_tools_test.dart test/mcp_test.dart test/tool_audit_dao_test.dart test/tool_calling_test.dart` 通过 55 个测试，覆盖写工具确认/拒绝、MCP 非信任源确认、无 UI 默认拒绝、工具审计持久化、项目白名单、只读资源/提示词工具、动态工具失败重试和工具循环收尾。
- 2026-07-03 复验「知识库导入与检索」可靠性证据：`flutter test test/knowledge_file_importer_test.dart test/knowledge_base_test.dart` 通过 14 个测试，覆盖多文件批量导入、空内容/不支持文件逐项失败且不中断其它文件、知识库 DAO 导入/列表/检索/删除、项目绑定知识库优先检索。
- 2026-07-03 复验「RAG 索引重建」可靠性证据：`flutter test test/knowledge_base_test.dart` 通过 12 个测试，覆盖轻量向量索引随文档导入自动写入、关键词 0 命中时向量 fallback、项目范围约束、索引缺失时现场计算回退、单文档/全量重建和 `knowledge_search` 工具检索。
- 2026-07-03 复验「跨设备云同步」本地合同：Flutter 侧 `flutter test test/local_sync_service_test.dart test/cloud_sync_client_test.dart test/cloud_sync_page_test.dart` 通过 12 个测试，后端 `pnpm --filter chatgpt_backend test -- sync.service.spec.ts` 通过 6 个测试，覆盖本地增量导出、远端应用、分页拉取、上传变更、游标推进、冲突 reason 保留、页面中文冲突摘要、服务端 LWW/hasMore/用户隔离。
- 2026-07-03 复验「备份导出与导入」可靠性证据：`flutter test test/backup_test.dart test/backup_restore_page_test.dart test/generated_image_save_service_test.dart` 通过 31 个测试，覆盖导入预览、冲突摘要、五种导入模式、API key 脱敏、账号告警、知识库/头像/附件/生成图片资源 v2 备份恢复、外键修复和非法备份不改库。
- 2026-07-03 复验「生成图片保存与相册」可靠性证据：`flutter test test/generated_image_save_service_test.dart test/generated_image_album_page_test.dart test/my_page_test.dart` 通过 9 个测试，覆盖 data URI/本地文件/HTTP 图片保存、相册列表过滤和修改时间倒序、`generated_images` 目录边界删除保护、相册空态/展示/确认删除刷新、个人中心小屏滚动入口。
- 2026-07-03 复验「用量统计与成本汇总」可靠性证据：`flutter test test/usage_record_test.dart test/usage_stats_page_test.dart` 通过 17 个测试，覆盖 usage 记录、provider/model 精确单价优先级、模型/服务商/日期/项目/会话聚合、项目名/未分类/项目表缺失兜底、页面摘要、复制汇总、空状态和成本单价弹窗保存。
- 2026-07-03 复验「会话模板与工作流启动」可靠性证据：`flutter test test/workflow_template_store_test.dart test/workflow_template_launcher_test.dart test/capability_center_page_test.dart` 通过 13 个测试，覆盖自定义模板管理、模板助手创建复用、会话继承配置、模板项目创建复用、同名知识库绑定、首条提示上下文注入和能力中心一键开始。
- 2026-07-03 复验「助手市场与模板克隆」可靠性证据：`flutter test test/builtin_assistants_test.dart test/assistant_market_page_test.dart` 通过 10 个测试，覆盖内置助手目录完整性、分类分组、独立实例克隆、真实 DAO 落库、多次克隆互不影响、市场名称/分类/提示词搜索和无命中空态。
- 2026-07-03 复验「发送消息与流式收尾」可靠性证据：`flutter test test/block_message_test.dart test/tool_history_test.dart test/usage_record_test.dart` 通过 38 个测试，覆盖流式事件沉淀 typed blocks、空流式占位清理、块 JSON 往返、OpenAI tool_calls/role:tool 跨轮重建、附件文本跨轮拼回、usage 分页/聚合和真实/估算成本入库。
- 2026-07-03 复验「会话搜索与命中定位」可靠性证据：`flutter test test/project_dao_test.dart test/conversation_search_page_test.dart` 通过 26 个测试，覆盖标题/最近消息/历史消息搜索排序、长历史片段自然边界、项目/未分类/全局范围、收藏范围过滤、搜索结果分组、慢响应保护、错误态和点击结果返回命中消息锚点。
- 2026-07-03 复验能力中心证据矩阵总线：`flutter test test/product_capabilities_test.dart test/capability_center_page_test.dart` 通过 29 个测试，确认每个可靠性场景都绑定真实测试文件、关键断言和可运行命令，能力中心页面可展示所有场景项、步骤、工作流模板和一键开始入口。
- 新增 `local_sync_service_test.dart`，覆盖本地变更包增量导出、较新远端写入、陈旧拒绝、同时间冲突和删除应用。
- 新增后端 `sync.service.spec.ts`，覆盖新变更接收、游标分页拉取、`hasMore`/`limit` 边界、远端较新拒绝、本地较新覆盖、同时间冲突和用户隔离。
- 新增 `cloud_sync_client_test.dart` / `cloud_sync_page_test.dart`，覆盖 Flutter 云同步 push/pull 协议、登录态 header 可注入、避免远端 echo、游标/lastPushAt 推进、`hasMore` 分页拉取、冲突 reason 保留与页面展示、页面成功/错误/同步中禁用状态。
- 新增 `tool_audit_dao_test.dart` 与 `mcp_test.dart` 持久化审计用例，覆盖审计写入、倒序读取和 MCP 调用落库。
- 新增 `tool_audit_page_test.dart`，覆盖工具审计页列表、详情展开、空态和错误态。
- `product_capabilities_test.dart` / `capability_center_page_test.dart` 新增可靠性证据校验，确保每个回归场景都有真实存在的测试文件支撑。
- 新增 `backup_restore_page_test.dart`，覆盖导入预览弹窗的备份数量、跨账号告警、冲突摘要，以及「覆盖全部 / 仅导入项目和会话 / 仅导入助手 / 仅导入知识库 / 合并导入」五种导入方式的警告与确认文案；可靠性证据矩阵的备份恢复场景已绑定该 UI 测试。
- `usage_stats_page_test.dart` 新增成本单价弹窗、项目维度和复制汇总回归，覆盖默认单价与模型精确单价保存到 `AISettingsProvider`，以及用量汇总文本格式化和剪贴板复制反馈；`usage_record_test.dart` 覆盖 `aggregateByProject` 在项目表存在/缺失时的聚合和过滤行为。
- `backend_chat_service_test.dart` / `tool_calling_test.dart` / `openai_flutter_test.dart` 新增流式 usage 回归，覆盖后端 JSON 解析、工具循环穿透和直连 SSE final usage chunk 解析。
- 会话搜索相关性排序已补齐：`ConversationListDao.searchConversations` 会按标题命中、最近消息命中、历史消息命中的权重排序，同分再按置顶和更新时间；`project_dao_test.dart` 覆盖“标题/最近消息命中优先于仅历史消息命中”的回归。
- 会话搜索结果片段定位已补齐基础版：`ConversationSearchResult.sourceLabel` 会标识命中来自「标题 / 最近消息 / 历史消息」，搜索页在片段前展示来源标签；`project_dao_test.dart` 覆盖三类来源标签，`conversation_search_page_test.dart` 覆盖 UI 展示。
- 收藏搜索结果上下文已补齐：能反查到原会话的收藏会显示 `来自「会话标题」`，无法反查的收藏保留复制路径；`conversation_search_page_test.dart` 覆盖会话内收藏上下文展示。
- 云同步页面反馈继续补强：同步完成态会展示手动/自动来源、云端游标，并把 `remote_newer` / `same_timestamp` / `local_same_timestamp` 等冲突 reason 转成中文说明；冲突明细最多展示前三条并提示还有更多，`cloud_sync_page_test.dart` 覆盖成功态、中文冲突说明和明细截断。
- 会话搜索补齐消息级跳转：`ConversationSearchResult.targetMessageCreatedAt` 会在历史消息命中时记录命中消息时间；搜索页返回 `ConversationSearchSelection`，打开会话时通过 `ConversationPage.initialTargetCreatedAt` 加载全量历史并滚动到命中消息。`project_dao_test.dart` 覆盖标题/最近消息不带锚点、历史消息带锚点和 1000 条长会话命中；`conversation_search_page_test.dart` 覆盖定位图标与返回锚点。
- 会话搜索补齐多命中片段展开：历史消息命中会返回最多 4 条 `messageSnippets`，搜索页默认展示第一条，存在更多命中时可展开/收起其它片段并保持关键词高亮；`project_dao_test.dart` 覆盖同会话多条历史命中的片段顺序和锚点，`conversation_search_page_test.dart` 覆盖展开按钮与多片段展示。
- 会话搜索继续补齐片段级定位：历史命中新增 `ConversationSearchHit`，展开出来的每个片段都保留自己的 `createdAt`，用户可直接点击某一条展开片段跳到对应消息；`conversation_search_page_test.dart` 覆盖点击第二条命中返回第二条锚点。
- 可靠性证据矩阵新增「会话搜索与命中定位」场景：能力中心会展示搜索标题/最近消息/历史消息、多片段展开和历史命中定位的步骤，并绑定 `project_dao_test.dart` / `conversation_search_page_test.dart` 的可运行命令。
- 可靠性证据矩阵新增独立「跨设备云同步」场景：能力中心会展示本地增量导出、远端分页拉取、上传本地变更、冲突与游标反馈的步骤，并绑定 `local_sync_service_test.dart` / `cloud_sync_client_test.dart` / `cloud_sync_page_test.dart`；备份恢复场景不再混入云同步测试，职责更清晰。
- 可靠性证据矩阵新增「RAG 索引重建」场景：能力中心会展示导入文档、索引缺失、重建索引、检索命中的步骤，并绑定 `knowledge_base_test.dart` 的可运行命令；`product_capabilities_test.dart` 已验证每个场景都有真实测试文件支撑。
- 可靠性证据矩阵新增「生成图片保存与相册」场景：能力中心会展示保存图片、打开应用内相册、刷新列表、确认删除的步骤，并绑定 `generated_image_save_service_test.dart` / `generated_image_album_page_test.dart` / `my_page_test.dart`；`product_capabilities_test.dart` 已验证保存、查看、删除和个人中心入口都有真实测试文件支撑。
- 可靠性证据矩阵新增「用量统计与成本汇总」「会话模板与工作流启动」「语音偏好与朗读执行」场景：分别绑定 `usage_record_test.dart` / `usage_stats_page_test.dart`、`workflow_template_store_test.dart` / `workflow_template_launcher_test.dart` / `capability_center_page_test.dart`、`project_dao_test.dart` / `read_aloud_service_test.dart` / `product_capabilities_test.dart`；`product_capabilities_test.dart` 已验证项目维度/复制汇总、模板项目化启动/知识库绑定、语音偏好持久化/`flutter_tts` 朗读调用都有真实测试文件支撑。
- 2026-07-02 已按 `ReliabilityBacklog.evidence` 整轮补跑 12 个场景对应的 Flutter 测试命令，并通过 `dart analyze lib/capability/product_capabilities.dart test/product_capabilities_test.dart`、`pnpm --filter chatgpt_backend test -- sync.service.spec.ts` 和 `chatgpt_app_core` 全量 `flutter test`（428 tests）；当前本地证据覆盖发送收尾、模型切换、用量统计、工作流模板、备份恢复、工具确认、知识库导入、RAG 索引、生成图片相册、语音偏好、云同步和会话搜索。
- 2026-07-02 跨包验证继续补齐：`chatgpt_backend` 已通过 `lint` / `test` / `build`，`chatgpt_flutter` 壳层 `dart analyze` 通过，`openai_flutter` 已通过 `dart analyze` 和全量 `flutter test`。`openai_flutter_test.dart` 已去除真实 OpenAI API key/代理依赖，改用本地 loopback mock 覆盖 `createChat` 请求体/header/响应解析，以及 final usage SSE 解析。
- 2026-07-02 管理端验证补齐：按 `chatgpt_admin/AGENTS.md` 阅读 Next 16 本地文档后，清理 admin 侧 lint warning（未用 import、动态 `<img>` 改 `next/image unoptimized`），`chatgpt_admin` 已通过 `lint` / `typecheck` / `build`。`next build` 在沙箱内会因 Turbopack 创建进程/绑定端口被拒，外层权限验证通过；构建仅剩 Next/Node 实验性提示，不影响产物生成。
- 2026-07-02 HarmonyOS 壳层验证补齐：`chatgpt_flutter_ohos` 已显式声明 `login_sdk` 直接依赖，删除无效的 Flutter counter 模板测试，新增 `shell_config_test.dart` 覆盖 OHOS 壳层后端 host 配置；按项目要求激活 mise 后已通过 `flutter pub get` / `flutter analyze` / `flutter test`。
- 2026-07-02 支持包验证补齐：`login_sdk` 已声明本地包 `publish_to: none` 并启用 Material icons，删除无效模板测试后通过 `flutter analyze` / `flutter test`；`auth_kit_flutter` 新增基础合同测试后通过 `flutter analyze` / `flutter test`；`chat_message` 清理静态分析问题后通过 `flutter analyze` / `flutter test`；`hi_download` 通过 `flutter analyze` / `flutter test`。
- 2026-07-03 助手市场搜索增强：`AssistantMarketPage` 支持按助手名称、分类和提示词本地过滤，过滤后仍按分类分组展示，无命中时展示空态；`assistant_market_page_test.dart` 覆盖名称搜索、分类搜索和空态。已通过 `dart analyze chatgpt_app_core/lib/pages/assistant_market_page.dart chatgpt_app_core/test/assistant_market_page_test.dart` 和 `cd chatgpt_app_core && flutter test test/assistant_market_page_test.dart`。
- 2026-07-02 工作树收口：全工作树 `git diff --check` 通过；`.codegraph/` 已作为本地可重建索引加入 `.gitignore`，避免误提交。

## 1. 当前基线

项目已经具备一个成熟 AI 客户端的主要骨架：

- 多服务商 AI 配置：本地直连 / 后端代理、多 provider、多模型、模型能力位。
- 会话系统：流式输出、块化消息、工具调用、联网搜索、附件、重新生成、收藏。
- 助手系统：内置助手市场、自定义助手、助手绑定会话、工具集开关。
- 助手市场搜索：支持按名称、分类和提示词过滤内置助手模板，并有无结果空态回归。
- 对话项目化：项目分类、项目图标/颜色、会话移动到项目、旧会话兼容为未分类。
- 会话个性化：会话头像、会话级模型覆盖、底部显示当前模型并可切换。
- 数据迁移与备份：旧表兼容、游客数据迁移、项目/会话/消息/助手/收藏/设置备份恢复。

后续优化的核心目标不再是“把功能堆齐”，而是让这些能力变得可靠、可恢复、可解释、可长期使用。

## 2. 优先级总览

### 当前执行进度

2026-06-29 已落地：

- 模型测试结果持久化：`AiModel.lastTestAt / lastTestStatus / lastTestError`，服务商详情页和会话模型选择器共享同一状态。
- 会话头像图片持久化：相册图片复制到 App Documents 下的 `chat_avatar/<accountHash>/`，替换/恢复/删除时清理托管文件。
- 备份 v2：导出/导入知识库 `tb_kb_doc / tb_kb_chunk`，并预留/实现头像资源 `assets/avatars/` 打包与恢复。
- 项目默认模型/助手/联网搜索/工具集：项目可设置工作空间默认值，新建该项目会话时自动继承；游客迁移和备份恢复会修复默认助手引用。
- 会话模型选择器升级：支持搜索、可用/图片/工具/推理筛选、能力标签和持久化测试状态展示。
- 服务商健康检查页：AI 服务设置页右上角可批量测试启用模型，支持中止批量测试、复制诊断信息，并把测试结果回写到模型配置。
- 项目级知识库：新增 `tb_project_kb` 绑定表，项目菜单可勾选知识库文档，`knowledge_search` 在项目会话中优先检索绑定文档，未绑定时回退全局知识库；备份 v2 同步包含项目知识库绑定。
- 项目内搜索增强：对话列表增加搜索入口，支持按当前项目/未分类范围搜索会话标题、最近消息和全量消息内容，支持助手、模型、时间范围过滤；收藏内容作为独立结果展示并可复制。
- 模型体验增强：模型选择会记录 `lastUsedAt` 并按最近使用优先展示；模型测试成功后根据本地启发式保守写回视觉/工具/推理能力位，只加位不减位。
- 会话内模型切换列表测试已补齐：模型选择器的搜索、最近使用排序、可用状态过滤和图片/工具/推理能力过滤抽为 `ConversationModelPickerPresenter` 纯逻辑，并由 `model_picker_presenter_test.dart` 覆盖；`ReliabilityBacklog.switch_model` 证据矩阵已绑定该测试。
- 稳定性/工程专项：新增 `DbMigration.run` 集中式 schema 迁移入口，DB 打开和备份恢复前统一执行；新增 1000 条长会话分页与搜索基础回归测试。
- 更深的模型能力探测：服务商健康检查页新增单模型“深度探测”，在基础连通后尝试最小 tools schema 与 1x1 图片请求；探测成功只加能力位，失败只记录未确认原因。
- 搜索继续增强：会话搜索在 SQLite 支持 FTS5 时优先走 FTS 候选集，否则回退 `LIKE`；搜索结果增加关键词高亮，收藏结果可反查原会话并跳转，无法反查时保留复制能力。
- UI 自动化回归：新增 `conversation_search_page_test.dart`，覆盖搜索页会话/收藏结果展示、关键词高亮和收藏复制路径。
- 项目/未分类搜索页新增范围切换：从项目或未分类进入搜索时，可在当前范围与「全部会话」之间切换，切换后自动按当前关键词重新搜索；`conversation_search_page_test.dart` 覆盖项目范围与未分类范围切到全局时过滤参数正确重置。
- 搜索片段上下文窗口已调优：历史消息长片段会优先按换行、句号、问号、分号等自然边界截取命中词前后上下文，避免从长段中间硬切；`project_dao_test.dart` 已新增长历史消息片段边界回归。
- 搜索结果分组已落地：搜索页按「标题命中 / 最近消息命中 / 历史消息命中 / 其它匹配」分组展示会话结果，并显示每组数量；`conversation_search_page_test.dart` 覆盖分组标题、计数和结果展示。
- 搜索结果排序解释已落地：搜索页会在会话结果头部说明按「标题 / 最近消息 / 历史消息」相关性分组，同组内保留置顶和更新时间排序；`conversation_search_page_test.dart` 覆盖说明文案。已通过 `dart analyze chatgpt_app_core/lib/pages/conversation_list_page.dart chatgpt_app_core/test/conversation_search_page_test.dart` 和 `cd chatgpt_app_core && flutter test test/conversation_search_page_test.dart`。
- 收藏搜索范围过滤已落地：`FavoriteDao.searchFavoriteResults` 支持 `projectId` / `uncategorized`，搜索页默认收藏结果会跟随当前项目、未分类或全部会话范围；`project_dao_test.dart` 覆盖项目收藏、未分类收藏和全局收藏结果差异。已通过 `dart analyze chatgpt_app_core/lib/db/favorite_dao.dart chatgpt_app_core/lib/pages/conversation_list_page.dart chatgpt_app_core/test/project_dao_test.dart chatgpt_app_core/test/conversation_search_page_test.dart` 和 `cd chatgpt_app_core && flutter test test/project_dao_test.dart test/conversation_search_page_test.dart`。
- 全局搜索入口回归已补齐：`ConversationListPage` 顶部搜索按钮有稳定 key，widget 测试覆盖从全局列表打开时使用 `projectId=null`、`uncategorized=false`、`scopeLabel=全部会话`；`ReliabilityBacklog.conversation_search` 证据矩阵已纳入该断言。已通过 `dart analyze chatgpt_app_core/lib/pages/conversation_list_page.dart chatgpt_app_core/test/conversation_search_page_test.dart`、`cd chatgpt_app_core && flutter test test/conversation_search_page_test.dart`、`dart analyze chatgpt_app_core/lib/capability/product_capabilities.dart chatgpt_app_core/test/product_capabilities_test.dart` 和 `cd chatgpt_app_core && flutter test test/product_capabilities_test.dart`。
- 2026-07-03 搜索专项复验：已通过 `dart analyze lib/db/conversation_dao.dart lib/pages/conversation_list_page.dart test/project_dao_test.dart test/conversation_search_page_test.dart` 和 `flutter test test/project_dao_test.dart test/conversation_search_page_test.dart`。

仍待后续：

- 头像资源恢复已有 `backup_test.dart` 本地自动化覆盖；仍待真机只确认系统文件权限与列表渲染链路。
- 更深的真实模型能力探测仍需要带真实 API Key 的服务商联调，确认不同厂商对 tools / vision 错误码的差异。
- 搜索后续主要剩真实端到端体验观察；结果分组、排序解释、收藏范围过滤、全局入口回归和片段上下文窗口已完成并通过本地回归。
- UI 自动化仍可扩展到会话发送、备份导入导出等更长链路；会话内模型切换列表已有纯逻辑回归覆盖。
- Android 发布质量专项仍按约定后续单独处理。

### P0：先做，直接影响数据安全和核心体验

- 会话头像图片持久化。
- 模型测试结果持久化。
- 项目级默认模型 / 默认助手 / 默认工具配置。
- 备份覆盖知识库与头像资源。
- 会话模型选择器升级。

### P1：随后做，提升专业度和长期使用效率

- 全局搜索与项目内搜索增强。
- 模型能力自动探测。
- 服务商健康检查页。
- 数据库迁移集中化。
- 长会话性能压测与滚动稳定性优化。

### P2：增强项，适合产品稳定后继续扩展

- 项目级知识库。
- 会话模板。
- 用量和成本统计。
- 导入/恢复策略细分。
- 更完整的自动化 UI 回归。

### 暂缓：Android 发布质量专项

本专项后续单独处理：

- 正式 release signing。
- applicationId 正式化。
- NDK 版本升级。
- OCR stub override 拆分。
- 上架前隐私权限与合规文案。

## 3. P0 优化项

### 3.1 会话头像图片持久化

#### 背景

当前会话头像支持 emoji 和相册图片。图片头像保存的是 `image_picker` 返回的本地路径。这个路径可能在系统清理、相册权限变化、文件移动、备份恢复后失效。

#### 目标

把会话头像图片复制到 App Documents 目录，由应用自己管理生命周期。

#### 方案

- 新增头像资源目录，例如：
  - `ApplicationDocumentsDirectory/chat_avatar/<accountHash>/`
- 选择图片后：
  - 压缩到 512px 以内。
  - 生成稳定文件名：`conversation_<cid>_<timestamp>.jpg`。
  - 复制到头像目录。
  - `ConversationModel.avatarType = 'image'`。
  - `ConversationModel.avatarValue = <app-managed-path>`。
- 替换头像时删除旧头像文件。
- 删除会话时可选择删除关联头像文件。
- 备份时把头像资源打进 zip。
- 恢复时重建资源目录并重写 `avatarValue`。

#### 涉及模块

- `conversation_list_page.dart`
- `conversation_dao.dart`
- `conversation_widget.dart`
- `backup_service.dart`
- 新增 `avatar_asset_service.dart`

#### 验收标准

- 从相册选择头像后，原始相册文件删除或权限变化，列表头像仍可显示。
- 备份导出再导入到空库后，图片头像仍可显示。
- 删除/替换头像不会留下大量孤儿文件。

### 3.2 模型测试结果持久化

#### 背景

当前已经支持：

- 服务商详情页模型行测试。
- ~~会话内模型切换列表测试。~~ ✅ 已完成（2026-07-03）：`ConversationModelPickerPresenter` 覆盖搜索、最近使用排序、可用状态和能力过滤。

但测试状态只存在于当前页面/弹窗内，关闭后会丢失。

#### 目标

模型测试结果可复用，帮助用户识别哪些模型可用、上次什么时候测试、失败原因是什么。

#### 数据设计

可优先放入 `AiModel` 本地配置字段：

- `lastTestAt`: int，毫秒时间戳。
- `lastTestStatus`: string，`success | failure | unknown`。
- `lastTestError`: string?，最近一次失败原因。

如果不想扩大 `AiModel` 结构，也可以单独维护 `model_test_cache`，但从当前代码结构看，放进 `AiModel` 更直观。

#### 交互设计

- 模型行显示：
  - `可用` / `不可用` / `未测试`
  - 最近测试时间，例如 `今天 21:30`
- 会话模型选择列表复用同一状态。
- 测试成功清空旧错误。
- 修改 API Key、Base URL、模型 ID 后，将该服务商模型测试状态标记为过期。

#### 验收标准

- 在服务商详情页测试成功后，退出再进入仍显示可用状态。
- 在会话切换模型列表里能看到同一模型的测试状态。
- API Key 修改后，旧测试结果不再被误认为当前可用。

### 3.3 项目级默认模型 / 默认助手 / 默认工具配置

#### 背景

项目分类已经建立，但项目目前主要是“会话分组”。更有价值的下一步是让项目成为工作空间：不同项目可以拥有不同默认模型、助手和工具。

#### 目标

新建项目内会话时，自动继承项目配置。

#### 数据设计

扩展 `ProjectModel`：

- `defaultProviderId`: string?
- `defaultModelId`: string?
- `defaultAssistantId`: int?
- `defaultUseWebSearch`: bool?
- `defaultToolIds`: List<String>?

数据库 `tb_project` 增加对应列，使用 guarded `ALTER TABLE` 保持兼容。

#### 交互设计

- 项目长按菜单增加 `项目设置`。
- 项目设置内包含：
  - 默认模型。
  - 默认助手。
  - 默认联网搜索。
  - 默认工具集。
- 新建会话时：
  - 如果当前筛选在某个项目下，默认归属该项目。
  - 自动填充项目默认模型和助手。
- 会话仍可单独覆盖模型和助手。

#### 优先落地顺序

1. 项目默认模型。
2. 项目默认助手。
3. 项目默认工具 / 联网搜索。

#### 验收标准

- 在项目 A 设置默认模型后，新建会话自动使用该模型。
- 会话手动切换模型后，不影响项目默认值。
- 旧项目无默认配置时行为保持不变。

### 3.4 备份覆盖知识库与头像资源

#### 背景

当前备份已覆盖项目、会话、消息、助手、收藏、设置、知识库、附件原始文件、头像资源和应用内生成图片资源。头像图片资源已经进入备份，仍保留真机显示链路的最终确认。

#### 目标

备份可以恢复一个用户的完整工作上下文，而不只是聊天记录。

#### 备份格式建议

继续使用 zip：

```text
manifest.json
projects.json
conversations.json
messages.json
assistants.json
favorites.json
settings.json
knowledge_docs.json
knowledge_chunks.json
assets/
  avatars/
    <file>
  files/
    <file>
  generated_images/
    <file>
```

#### 兼容策略

- `manifest.formatVersion` 可从 `1` 升到 `2`。
- 导入 v1 备份时：
  - 缺少知识库视为空。
  - 缺少头像资源时，图片头像降级为默认头像。
- 导入 v2 备份时：
  - 先恢复结构化表。
  - 再恢复 assets 并修正头像路径。

#### 验收标准

- 含知识库的备份导入后，知识库页面文档数量和 chunk 数一致。
- 含头像图片的备份导入后，`avatarValue` 被重写到当前账号托管目录；缺少头像资源时图片头像降级为默认头像并给出告警。
- v1 旧备份仍可导入。

#### 当前自动化证据

- `backup_test.dart` 覆盖头像资源打包到 `assets/avatars/`、导入后重写 `avatarValue`、跨账号恢复到新账号目录、缺少头像资源时降级默认头像。
- `backup_test.dart` 同时覆盖知识库、附件原始文件、应用内生成图片和合并导入资源追加。

### 3.5 会话模型选择器升级

#### 背景

会话底部已经显示当前模型，并支持切换和测试。下一步要让它从“列表”变成真正可用的模型选择器。

#### 目标

用户能快速判断应该选择哪个模型，而不是只看到模型 ID。

#### 交互设计

- Bottom sheet 顶部增加搜索框。
- 模型按服务商分组。
- 每个模型展示：
  - 显示名。
  - 模型 ID。
  - 能力标签：视觉、工具、推理、PDF、联网配置可用。
  - 测试状态。
  - 最近使用标记。
- 增加筛选：
  - 全部。
  - 可用。
  - 支持图片。
  - 支持工具。
  - 支持推理。
- 增加 `跟随项目默认` 状态：
  - 若当前会话属于项目且项目设置了默认模型，优先展示该选项。
  - 层级为：会话覆盖 > 项目默认 > 助手覆盖 > 全局设置。

#### 验收标准

- 模型数量较多时可以搜索。
- 能力标签和实际附件/工具入口 gating 一致。
- 切换模型后底部状态立即刷新。

## 4. P1 优化项

### 4.1 全局搜索与项目内搜索增强

#### 目标

把会话数据从“列表浏览”升级为“可检索知识资产”。

#### 功能

- 对话列表页增加搜索入口。
- 支持搜索：
  - 会话标题。
  - 最近消息。
  - 全量消息内容。
  - 收藏内容。
- 支持过滤：
  - 项目。
  - 助手。
  - 模型。
  - 时间范围。
  - 是否收藏。

#### 技术建议

SQLite 优先尝试 FTS5 候选集；当运行时未编译 `ENABLE_FTS5` 或建表失败时，自动回退 `LIKE` + 分页，避免不同平台 SQLite 能力差异导致搜索不可用。

#### 验收标准

- 项目内搜索只返回该项目会话。
- 搜索结果可点击跳转到会话。
- 命中消息可展示摘要片段。
- 命中关键词在会话和收藏结果中高亮。
- 收藏命中能反查原会话时可跳转，无法反查时可复制内容。

### 4.2 模型能力自动探测

#### 背景

当前能力位由本地启发式 + 后端 catalog 加法覆盖决定。用户手动添加模型时，能力可能不准确。

#### 目标

模型测试时顺手探测能力，减少手动配置成本。

#### 探测策略

- 基础连通：普通 `ping`。
- 工具能力：发送一个最小 tools schema，看响应是否接受。
- 视觉能力：可选发送 1x1 图片或本地小图，验证是否接受 image input。
- 推理能力：不能可靠探测时，仅通过模型名/后端 catalog 判断，不强行推断。
- PDF 能力：优先由 catalog/模型名判断，不建议靠真实 PDF 请求探测，成本较高。

#### 重要约束

能力探测必须保守：

- 探测失败不能直接关闭已有能力，只能提示“未确认”。
- 管理端下发的能力仍保持加法覆盖语义。
- 深度探测需要用户显式触发，避免批量健康检查产生过多成本。
- 当前已实现基础连通、最小 tools schema 和 1x1 图片请求的探测路径；真实能力结论仍以服务商实际返回为准。

### 4.3 服务商健康检查页

#### 目标

让用户一次性知道当前配置是否能用。

#### 功能

- 入口：AI 服务设置页右上角。
- 展示所有 enabled providers。
- 支持：
  - 测试 API Key / Base URL。
  - 批量测试启用模型。
  - 显示失败原因。
  - 一键复制诊断信息。

#### 验收标准

- API Key 错误、Base URL 错误、模型不存在能区分展示。
- 批量测试过程可取消。
- 不会修改当前 activeProvider / selectedModel。

### 4.4 数据库迁移集中化

#### 背景

当前很多 DAO 自己在初始化时执行 guarded `ALTER TABLE`。这对快速迭代很方便，但长期会造成 schema 逻辑分散。

#### 目标

保留 DAO 自愈能力，同时建立统一 schema migration 入口。

#### 方案

- 新增 `db_migration.dart`。
- 每次版本升级记录 migration step：
  - `conversation.addProjectId`
  - `conversation.addAvatar`
  - `conversation.addModelOverride`
  - `project.addDefaults`
- `HiDBManager._onUpgrade` 负责跨版本迁移。
- DAO 构造函数仍可保留 guarded `ALTER` 作为防御。

#### 验收标准

- 从旧 DB 直接升级到最新版可用。
- 新安装数据库不重复执行无意义 ALTER。
- 迁移测试覆盖旧 schema。

### 4.5 长会话性能与滚动稳定性

#### 目标

保证真实长会话、块化消息、附件和搜索跳转下仍然稳定。

#### 测试场景

- 1000 条纯文本消息。
- 1000 条包含 block 的消息。
- 图片/文件混合消息。
- 重新生成最后一条 assistant 回复。
- 对话目录跳转到任意历史消息。
- 流式输出中切后台/返回。

#### 优化方向

- 消息分页加载边界更严格。
- block store 清理策略。
- 图片缩略图缓存。
- 长文本折叠或虚拟化。

## 5. P2 优化项

### 5.1 项目级知识库

#### 目标

让项目成为完整工作空间。项目里的会话默认可以检索项目绑定的知识库。

#### 方案

- `tb_project_kb` 关联表：
  - `projectId`
  - `docId`
- 项目设置里选择知识库文档。
- `knowledge_search` tool 根据当前会话项目优先检索项目知识库。
- 没有项目绑定时回退全局知识库。

### 5.2 会话模板

#### 目标

减少重复配置，让常用工作流可以一键开始。

#### 模板字段

- 标题模板。
- 项目。
- 助手。
- 模型。
- 工具集。
- 是否启用联网搜索。
- 初始系统提示词或首条用户提示。

#### 当前状态

2026-06-30 已落地 MVP：

- `BuiltinWorkflowTemplates` 提供论文阅读、代码审查、周报生成等内置模板。
- 「AI 能力中心」模板卡支持「开始」操作。
- `WorkflowTemplateLauncher` 会创建/复用模板助手，继承系统提示词、工具集、模型/provider 覆盖和联网搜索配置。
- 新会话打开时会把模板的首条用户提示预填到输入框，并追加项目名、知识库文档范围、联网搜索和工具清单，用户可编辑后再发送。
- 2026-07-01 继续补齐用户自定义模板：能力中心可新增模板、复制内置/自定义模板、自定义模板排序和删除；模板配置通过 `WorkflowTemplateStore` 持久化到本地缓存。
- 2026-07-01 模板启动已接入真实项目与项目知识库：按模板项目名创建/复用项目，写入项目默认 provider/model/助手/联网/工具，并把已存在的同名知识库文档绑定到项目范围。

仍待后续：

- 模板启动后的端到端真机/集成测试。

### 5.3 用量与成本统计

#### 目标

用户能知道哪些模型、项目、会话消耗最多。

#### 统计维度

- 按服务商。
- 按模型。
- 按项目。
- 按会话。
- 按日期。
- 按本地直连 / 后端代理。

#### 注意

本地直连不一定能拿到准确 usage，需要做估算；后端代理可优先使用服务端 usage。

#### 当前状态

2026-06-30 已落地：

- `tb_usage` 记录每轮模型、provider、项目、会话、prompt/completion token、估算成本与是否估算。
- 聊天收尾接入 `UsageRecordService`，非流式可记录 provider 返回 usage；流式和 usage 缺失时使用本地估算。
- 流式路径已支持 `StreamEvent.usage`：直连与后端代理在收到 final usage chunk 时按真实 token 落库，缺失时才回退估算。
- 「我的 → 用量统计」支持按服务商、模型、日期、项目、会话查看聚合结果；DAO 聚合支持 provider 过滤，可和项目/模型/会话维度交叉使用；项目聚合会显示项目名，未分类 usage 归为「未分类」，项目表缺失时按 `项目 #id` 兜底。
- `AISettings.usageCostConfig` 支持账号级默认单价、provider 默认单价和 provider/model 精确单价；旧设置缺省时回退 0 成本，只统计 token；用量统计页已提供「成本单价」配置入口。
- 用量统计摘要区已提供「复制汇总」入口，`UsageStatsExportFormatter` 会输出总览和五个维度的聚合明细，适合对账、留档或复制到外部表格前整理。

仍待后续：

- 带真实 API Key 覆盖不同服务商的流式 usage trailer 差异联调。

### 5.4 导入/恢复策略细分

#### 当前状态

备份导入已从单一 overwrite-mode 扩展为预览后选择策略，既保留一键覆盖，也支持只导入局部数据或追加合并。

2026-07-01 已完成导入前预览与冲突识别：

- `BackupService.previewArchive` 可在不写库的情况下解析备份版本、来源账号、是否包含设置/API key、各类数据数量、头像资源和附件原始文件数量。
- 账号不一致会在预览阶段给出非阻断告警。
- `BackupConflictSummary` 会比较当前本地库与备份内容，给出总行数、同 key 覆盖、本地独有、备份新增和同 key 内容不同数量；`BackupTableConflict` 提供按表明细和少量 key 样例。
- 「备份与恢复」页面导入前先展示预览和冲突摘要，再由用户确认覆盖导入；取消时不会修改数据库或触发 `restoreTick`。
- `BackupImportMode.knowledgeBaseOnly` 已落地到服务和 UI：预览弹窗可选择「仅导入知识库」，导入时只替换 `tb_kb_doc` / `tb_kb_chunk` / 可匹配本地项目的 `tb_project_kb`，不会修改会话、消息、助手、收藏、项目或 AI 设置；无法匹配本地项目的知识库绑定会被跳过并写入非致命告警。
- `BackupImportMode.assistantsOnly` 已落地到服务和 UI：预览弹窗可选择「仅导入助手」，导入时只替换 `tb_assistant`，并把当前本地会话 `assistantId`、项目 `defaultAssistantId` 中无法匹配导入助手集的引用置空，避免悬空引用；会话、消息、收藏、项目、知识库和 AI 设置内容不被覆盖。
- `BackupImportMode.projectConversationsOnly` 已落地到服务和 UI：预览弹窗可选择「仅导入项目和会话」，导入时只替换 `tb_project` / `tb_conversation_list` / `tb_messages`，保留本地助手、收藏、知识库和 AI 设置；会话/项目助手引用按本地助手集校验，缺失则置空；无效 `projectId` 移到未分类；消息附件原始文件会随会话恢复并重写本地 path。为避免旧项目绑定悬空，`tb_project_kb` 会清空，后续用户可重新绑定项目知识库。
- `BackupImportMode.mergeAppend` 已落地到服务和 UI：预览弹窗可选择「合并导入」，导入时不清空本地表、不应用备份内 AI 设置；助手、项目、会话、消息、收藏、知识库文档/片段和项目知识库绑定会追加写入，主键重新分配，冲突 `cid` 自动改用新值，相关引用按映射修复。
- `BackupPreview.planFor(mode)` 已提供模式级导入计划：预览页会根据当前导入方式展示预计覆盖、内容不同、新增和仅本地将删除/保留的行数；合并导入会把同 ID/cid 风险标记为重映射，而不是本地删除。

#### 后续策略

- 大体量备份的流式导出/导入，降低数万条消息时的内存峰值。
- 更细粒度的冲突人工选择（逐项目/逐会话选择保留本地或导入副本）。

### 5.5 UI 自动化回归

#### 目标

让复杂聊天页变更有更强保护。

#### 覆盖路径

- 新建项目。
- 新建会话。
- 切换模型。
- 测试模型。
- 发送消息。
- 重新生成。
- 设置头像。
- 导出/导入备份。

Flutter widget tests 可覆盖部分逻辑，真实端到端仍需要后续接入集成测试或人工验证清单。

当前已接入搜索页 widget 回归，优先覆盖可离线验证的会话/收藏结果展示、关键词高亮和复制路径；备份导入导出的 service/widget 回归已覆盖知识库、头像资源、附件原始文件、生成图片和多种导入模式；聊天发送、模型切换仍建议作为后续集成测试场景。

## 6. 推荐实施顺序

### 第一阶段：数据安全与可恢复

1. 会话头像图片持久化。
2. 备份包含头像资源。
3. 备份包含知识库。
4. v1/v2 备份兼容测试。

这一阶段完成后，用户数据“看得见的部分”基本都能可靠恢复。

### 第二阶段：模型体验闭环

1. 模型测试结果持久化。
2. 会话模型选择器升级。
3. 服务商健康检查页。
4. 模型能力自动探测。

这一阶段完成后，模型配置从“能填”变成“可诊断、可解释、可复用”。

### 第三阶段：项目工作空间

1. 项目默认模型。
2. 项目默认助手。
3. 项目默认工具 / 联网搜索。
4. 项目级知识库。
5. 项目内搜索。

这一阶段完成后，项目不只是分类，而是完整上下文容器。

### 第四阶段：稳定性与规模化

1. 长会话性能压测。
2. 滚动和跳转稳定性优化。
3. 数据库迁移集中化。
4. 导入/恢复策略细分。
5. 自动化 UI 回归。

## 7. 建议先执行的三张任务卡

### Task A：头像图片持久化

#### 产出

- `AvatarAssetService`
- 会话头像保存/替换/删除改造
- 头像备份资源格式预留
- 单元测试或最小手工验证清单

#### 风险

- 跨平台路径差异。
- OHOS 文件能力差异。
- 备份恢复路径重写。

### Task B：模型测试状态持久化

#### 产出

- `AiModel` 测试字段。
- 服务商详情页测试后落盘。
- 会话模型选择器读取同一状态。
- API Key/Base URL 修改后状态过期。

#### 风险

- 不同服务商同名模型不能共享状态。
- 后端代理模式和本地直连模式测试语义不同。

### Task C：项目默认模型

#### 产出

- `ProjectModel.defaultProviderId/defaultModelId`
- 项目设置入口。
- 新建会话继承项目默认模型。
- 会话底部模型标签区分 `跟随项目` / `当前模型`。

#### 风险

- 需要明确优先级：会话覆盖 > 项目默认 > 助手覆盖 > 全局设置。
- 旧项目和未分类会话必须保持原行为。

## 8. 后续 Android 发布质量入口

本路线图暂不执行 Android 发布专项，但需要记录后续入口：

- `docs/android-release-signing.md` 已存在，可作为正式签名起点。
- 当前构建提示部分插件建议 NDK `28.2.13676358`。
- 当前 release 仍使用 debug signing。
- 当前 applicationId 仍是示例包名。
- OCR 相关 stub override 会影响真机能力，需要发布前重新评估。

建议在产品优化第一阶段完成后，再开独立发布专项处理，避免数据结构改动和发布配置改动混在一起。
