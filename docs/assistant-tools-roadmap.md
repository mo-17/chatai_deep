# 助手「可执行能力」演进评估与 L1 落地规格

> 背景：当前 App 的「助手」本质是**可切换的系统提示词预设（人设）**，只改变模型怎么说话，
> 不引入新能力、不执行动作。本文评估如何让助手向 Claude Code「skill」那种**可执行能力**
> 靠拢，并给出第一步（L1）的落地规格 + 实施记录。

## 1. 现状盘点（已有什么）

工具调用的**地基已经搭好且跑通**（阶段六）：

- `ChatTool`（`tool_registry.dart`）：`name` + `description` + 参数 JSON Schema + `execute` 执行体 → `ToolOutcome`。
- `ToolRegistry`：组装一组工具，输出 OpenAI function declarations，按名执行（失败转文本回灌，不中断会话）。
- `ToolLoopRunner`：驱动「模型决定调用 → 客户端执行 → 回灌结果 → 续写」多轮回路（上限 5 轮）。
- 已接入会话页并有测试覆盖。

**缺口**：

1. 目前只有 **1 个工具**（`web_search`），且注册表是**全局**按设置拼的（`ToolRegistry.fromSettings`），不是按助手。
2. 助手 = 提示词 + 模型覆盖 + `useTools`（一个总开关 bool），**不能选「这个助手能用哪些工具」**。
3. 工具只在「**流式 + 模型支持 tool 能力位（`caps.tool`）+ 助手 `useTools` 开**」时启用，否则回落阶段五意图编排（`conversation_page.dart` 选路）。

## 2. 分级演进（价值 / 成本）

| 级别 | 做什么 | 成本 | 价值 |
|---|---|---|---|
| **L1 工具按助手绑定** | 助手加 `toolIds`，选它能用哪些工具；注册表按助手拼 | 低 | 高，立刻有「技能」感 |
| **L2 增加纯 Dart 工具** | 计算器、日期时间、单位换算、抓取网页正文等（无副作用、易实现） | 中低 | 高 |
| **L3 App 动作工具** | 让助手能「操作 App」：建会话 / 存收藏 / 查历史 / 改设置（有副作用，需确认 + 权限） | 中高 | 很高（真正 agentic） |
| **L4 助手知识库 / RAG** | 给助手挂文档 + 检索工具（源项目有「知识库检索」预留） | 高 | 高但重 |
| **L5 MCP / 外部工具服务器** | 接外部工具服务器 | 高 | 移动端偏过度 |

类比 skill：**L1+L2 = 给助手「能力」；L3 = 给助手「可执行动作」；L4 = 给助手「领域知识包」**。

## 3. 注意事项 / 坑

1. 工具只在「**流式 + 支持 tool 的模型**」下生效。给助手绑了工具但用户用了不支持工具的模型 / 非流式，会静默回落——L1 之后宜在 UI 给提示。
2. 本地直连 vs 后端代理两条路都要能传 function-calling 参数（现状联网工具已验证 OK，新工具沿用即可）。
3. **L3 有副作用的动作工具必须加确认 UI + 权限**，绝不允许无确认的破坏性操作。
4. 移动端没有代码沙箱，「跑代码」类工具不安全，不做；坚持声明式工具。

## 4. L1 落地规格

**目标**：助手可声明它暴露给模型的工具集（`toolIds`），会话按所绑助手拼注册表。
第一个可绑定工具即现有 `web_search`，为 L2 加更多工具铺好路。

**关键设计——零回归**：

- 助手新增 `toolIds: List<String>?`，持久化为 `tb_assistant.tools`（JSON 文本列）。
- **legacy / 空（`null` 或 `[]`）= 不绑定任何工具**：web_search 仍只由聊天页「联网开关」经
  `forceWebSearch` 驱动 —— **现有所有助手行为完全不变**。
- 助手**显式绑定** `web_search` → 即使联网开关关着，也把它暴露给模型（assistant 自带能力）。
- `useTools` 保留为**总开关**（关 = 一律无工具，回落意图编排）。

**改动点**：

- `model/assistant_model.dart`：加 `toolIds`；`fromJson`/`toJson`（`tools` 列 JSON 编解码）。
- `db/assistant_dao.dart`：建表加 `tools text` 列 + 老表 `ALTER`（照 `tb_conversation_list.assistantId` 升级套路）。
- `chat/application/tool_registry.dart`：加工具目录 `ToolDescriptor` + `availableDescriptors(settings)`；
  加 `ToolRegistry.fromAssistant(settings, toolIds, {forceWebSearch})`。
- `pages/conversation_page.dart`：注册表改由所绑助手 `toolIds` 拼（保留联网开关 → `forceWebSearch`）。
- `pages/assistant_edit_page.dart`：加工具多选 UI（未配置搜索 key 的工具置灰提示）。
- `data/builtin_assistants.dart`：`BuiltinAssistant` 加可选 `toolIds`（默认不绑定，保持现有模板不变）。

**测试**：

- `AssistantModel` toolIds JSON 往返（null / [] / ['web_search']）。
- `ToolRegistry.fromAssistant`：legacy null → 空；绑定且已配置 → 含 web_search；`forceWebSearch` 注入；未配置 key → 空。
- `tb_assistant` 升级：旧表（无 tools 列）经 create 后可读写 toolIds。

---

## ✅ 实施记录 · L1

已落地（2026-06-15）。助手可绑定工具，会话按所绑助手拼注册表，零回归。

**改动文件**：

- `model/assistant_model.dart`：加 `toolIds: List<String>?`；`tools` 列 JSON 编解码
  （`_decodeToolIds`，null/空/坏数据 → null）。
- `db/assistant_dao.dart`：建表加 `tools text` 列 + 旧表 `ALTER`（try/catch 吞「列已存在」）。
- `chat/application/tool_registry.dart`：加 `ToolDescriptor` + `catalog` + `isAvailable()`
  + `fromAssistant(s, toolIds, {forceWebSearch})`；`fromSettings` 保留未动。
- `pages/conversation_page.dart`：注册表改由 `_assistant?.toolIds` 拼，会话联网开关 →
  `forceWebSearch`；选路 gate 改为 `caps.tool && stream && useTools && !registry.isEmpty`。
- `pages/assistant_edit_page.dart`：`useTools` 开时展示工具多选（`CheckboxListTile`），
  未配置搜索 key 的工具置灰提示；保存写入 `toolIds`。
- `data/builtin_assistants.dart`：`BuiltinAssistant` 加可选 `toolIds`（默认不绑定，
  现有模板 prompt/行为不变），`toAssistant()` 透传。

**行为约定（零回归）**：

- 旧助手 `toolIds == null` → 不主动暴露工具；联网搜索仍只由会话联网开关经
  `forceWebSearch` 驱动 —— 与 L1 之前完全一致。
- 助手显式绑定 `web_search` → 即使联网开关关着也暴露给模型。
- `useTools` 仍是总开关（关 = 一律无工具）。
- 工具仅在 `caps.tool`（模型支持）+ 流式下生效，否则回落意图编排（同既有逻辑）。

**测试**：新增 `test/assistant_tools_test.dart` 9 例（toolIds JSON 往返、`fromAssistant`
四种选路、`tb_assistant` 旧表升级），全套 **177** 测试通过；`flutter analyze` 改动文件无新增问题。

**已知限制 / 下一步**：

- 目前可绑定工具只有 `web_search`（catalog 单条）；L2 在 `ToolRegistry.catalog` + 工厂里
  追加纯 Dart 工具（计算器 / 日期时间 / 抓取网页正文）即可被助手绑定。
- 绑了工具但用了不支持工具 / 非流式的模型会静默回落，UI 暂未提示（后续可在编辑页或
  会话页补一行说明）。
- 内置模板尚未预绑定工具；需要「默认带联网」的模板时，给其 `toolIds: ['web_search']` 即可。

## ✅ 实施记录 · L2

已落地（2026-06-15）。新增 3 个**无需配置**的纯 Dart 工具，通过 L1 机制即可被助手绑定。

**新增工具**（`chat/application/builtin_tools.dart`）：

- `calculator` 计算器：算术表达式求值（`+ - * / %`、乘方 `^` 右结合、一元正负、括号）。
  自带递归下降求值器 `Arithmetic.eval`，**零第三方依赖**（整数指数走快速幂，非整指数用
  exp/ln 级数近似），除零 / 语法错误抛 `FormatException` → 工具返回友好报错。
- `datetime` 日期时间：返回设备本地 `date / time / weekday / iso`（JSON）。
- `fetch_url` 网页抓取：GET 一个 http(s) URL，`HtmlText.extract` 去标签/剔除
  script+style/解码常见实体/压缩空白，截断到 4000 字。`http.Client` 可注入便于测试。

**接线**（`chat/application/tool_registry.dart`）：

- 加 id 常量 `calculatorId/dateTimeId/fetchUrlId`，`catalog` 增 3 条（`requiresSearchKey=false`）。
- `isAvailable`：非 web_search 工具恒可用（无需 key）。
- `fromAssistant`：按 `toolIds` 装配这三个工具。
- 顺手移除该文件一处历史遗留的未用 import（`search_orchestrator`）。

助手编辑页的工具多选（L1 已实现）自动展示这三个新工具，无需改 UI。

**测试**：新增 `test/builtin_tools_test.dart` 11 例（算术优先级/右结合/小数/取模/非法输入、
HTML 提取、各工具 execute、注册表登记与 `fromAssistant` 装配），全套 **187** 测试通过；
`flutter analyze` 改动文件无问题。

**下一步（L3）**：App 动作工具（建会话 / 存收藏 / 查历史 / 改设置），见下方 L3 评估。

## 5. L3 评估：App 动作工具

**可行性：可行，接入点干净。** `registry.execute()` 在 `ToolLoopRunner` 里是 `await` 的
（工具执行在 App async 上下文中），所以工具可 `await` 一个确认弹框再返回，流式回复会等待；
弹框出口有现成的全局 `NavigatorUtil._context`（首页 `BottomNavigator` 赋值）。动作面 DAO
（会话 / 收藏 / 设置 / 消息）均现成。唯一结构改动：`fromAssistant` 引入 `ToolActionContext`
（在 `conversation_page` 注入 DAO/账号/确认回调）。

**工具分档（按风险定确认策略）**：

| 档 | 工具示例 | 副作用 | 确认 |
|---|---|---|---|
| **只读** | 搜历史 / 列会话 / 列收藏 / 读会话消息 | 无 | 不需要 |
| **追加写** | 建会话 / 存收藏 / 置顶 | 有（可加不毁） | 每次确认（可「本会话允许」） |
| **改设置** | 切模型 / 模式 / 联网开关 | 敏感 | 强确认 + 限范围 |
| **破坏性** | 删会话 / 删收藏 | 不可逆 | 暂不做，或双重确认 |

**主要风险**：① **提示注入**最关键——L2 的 `fetch_url` 抓回的网页正文可能藏「删光会话」之类
指令，模型可能照做 → **所有写操作必须人工确认，破坏性操作不开放**；② 中途弹框 UX（已天然
await，但要设计好「拒绝」回灌话术）；③ 仅在支持 tool 的模型 + 流式下生效；④ 动作必须落到
当前账号 hash；⑤ 导航副作用（建会话是否跳转/刷新）。

**落地路径**：先 **L3a 只读上下文工具**（零确认、零破坏），再 **L3b 追加写 + 确认框**；改设置 /
删除暂缓。

### ✅ 实施记录 · L3a（只读上下文工具）

已落地（2026-06-15）。让助手能「读」用户自己的本地数据，无副作用、无需确认。

**新增工具**（`builtin_tools.dart`，均只读）：

- `search_chat_history(query, limit?)`：跨所有会话按关键词检索消息，返回会话标题 + 片段（联表
  `tb_messages`/`tb_conversation_list`）。
- `list_conversations(limit?)`：最近会话概览（标题 / cid / 消息数）。
- `list_favorites(limit?)`：收藏内容。
- `get_conversation_messages(cid, limit?)`：读某会话消息（role 映射 user/assistant），cid 来自前两者。

**运行上下文**：新增 `ToolActionContext`（`openStorage` 可注入便于单测；
`forCurrentAccount()` 默认按 `HiDBManager.getAccountHash()` 开库）。`_readyDb` 懒建四表，
空账号也安全。

**接线**（`tool_registry.dart`）：加 4 个 id + `_dataToolIds` 集合 + catalog 4 条（只读）；
`fromAssistant` 增 `actions` 参数——**仅当传入 `actions` 时**装配这些工具（缺则跳过）。
`conversation_page` 构造 registry 时传 `ToolActionContext.forCurrentAccount()`。
助手编辑页多选自动展示这 4 个新工具，无需改 UI。

**测试**：新增 `test/assistant_data_tools_test.dart` 8 例（四工具命中/未命中/排序/role 映射 +
`fromAssistant` 有/无 actions 装配），全套 **195** 测试通过；`flutter analyze` 改动文件无新增问题。

### ✅ 实施记录 · L3b（追加写工具 + 确认）

已落地（2026-06-15）。让助手能「写」用户数据，但**每次写都先人工确认**，破坏性操作不开放。

**新增工具**（`builtin_tools.dart`，均 sideEffect）：

- `save_favorite(content)`：把文本存入收藏夹。
- `create_conversation(title)`：新建带标题的会话（写后 `restoreTick++` 刷新列表）。
- `stick_conversation(cid, stick?)`：置顶 / 取消置顶（`stickTime = now / 0`）。

**确认机制（防提示注入的核心）**：

- `ToolActionContext` 加 `confirm(title, detail)` 回调。写工具 execute 里先
  `await _confirm(...)`，拒绝则回灌「用户拒绝了该操作，未做任何修改」，不碰库。
- **`confirm == null`（无 UI 上下文）一律拒绝**——安全兜底，防止网页正文里藏的指令
  （L2 `fetch_url`）触发静默写入。
- `conversation_page` 注入 `_confirmToolAction`：弹 `AlertDialog`（允许 / 拒绝）。
  工具执行在 `ToolLoopRunner` 里是 `await` 的，弹框时流式回复自然挂起等待。

**接线**：`ToolDescriptor` 加 `sideEffect` 标记；`tool_registry` 加 3 个 id（并入
`_dataToolIds`）+ catalog 3 条 + `fromAssistant` 装配；助手编辑页对 sideEffect 工具加橙色
`edit_note` 角标。

**测试**：新增 `test/assistant_write_tools_test.dart` 9 例（确认后写入 / 拒绝不写 / 无 confirm
拒绝 / 不存在 cid / catalog sideEffect / fromAssistant 装配），全套 **204** 测试通过；
`flutter analyze` 改动文件无问题（顺手把 L3a 误用的 `sqflite_common` 直接导入换成 `sqflite`）。

**暂缓项（按 L3 评估）**：改设置类（敏感）、删除类（不可逆）暂不做；如需，删除类应走双重确认。

## 6. L4 知识库（RAG）

给助手挂一批私有文档，提问时先检索相关片段再连同问题喂给模型作答，答案有出处。完整 RAG
要补「导入切分 → embedding → 向量存储/检索 → 回填」一条链；本仓库用 sqflite、无向量索引，
故分两步：

- **L4a 关键词版**（已落地）：文档切块存 sqflite，SQL `LIKE` 关键词检索。零新依赖、能快速出
  效果，召回不如向量。
- **L4b 向量版**（待定）：加 embedding（调 API）+ 余弦相似检索，召回更好，但要处理 key/联网/
  向量存储/HarmonyOS 兼容。

### ✅ 实施记录 · L4a（关键词知识库）

已落地（2026-06-15）。

**引擎**：

- `data/knowledge_chunker.dart`：`KnowledgeChunker.split`——按段落聚合到 ~600 字上限、超长段
  硬切。纯函数。
- `model/knowledge_model.dart`：`KnowledgeDoc`（标题/片段数/时间）。
- `db/knowledge_dao.dart`：两表 `tb_kb_doc` + `tb_kb_chunk`（账号库内，懒建表 + docId 索引）。
  `addDocument`（切块落库）/ `getDocuments` / `deleteDocument`（连 chunk 删）/ `search`
  （空格分词的多词「与」LIKE 检索，返回 `KnowledgeHit{docTitle, content}`）。

**工具接入**（复用 L1~L3 机制）：

- `builtin_tools.dart`：`knowledge_search(query, limit?)`——只读，经 `ToolActionContext` 开
  账号库 → `KnowledgeDao.search` → 返回 `[{source, content}]`，提示模型注明来源。
- `tool_registry.dart`：加 `knowledgeSearchId` + 并入 `_dataToolIds` + catalog 一条（只读）
  + `fromAssistant` 装配。助手编辑页多选自动展示。

**管理 UI**：`pages/knowledge_base_page.dart`（导入粘贴文本 / 列表 / 删除）；「我的」页加
「知识库」入口。

**用法**：我的 → 知识库导入资料 → 给某助手绑定「知识库检索」工具 → 该助手用支持工具的模型 +
流式时即可基于你的文档作答。

**测试**：新增 `test/knowledge_base_test.dart` 8 例（切分器空/聚合/硬切、DAO 增删检索全链路、
多词与、空文本不建、工具 execute 命中/未命中、catalog + `fromAssistant` 装配），全套 **212**
测试通过；`flutter analyze` 改动文件无新增问题（仅 1 条与全仓库一致的 `use_super_parameters`）。

**导入方式**（粘贴文本 + 文件，2026-06-15 补）：

- 知识库页：右下角 FAB「粘贴文本导入」；右上角「导入文件」选 PDF / 文本类 / 图片文件
  （`FileProcessor.pickerExtensions` + `OcrService.imageExtensions`），文件名作标题 → 切块落库：
  - 文本类：`FileProcessor.extractTextForImport` 直读；
  - PDF：先抽文本层；**扫描件**（`OcrService.pdfNeedsOcr` 判定空/过短/占位提示）回退逐页 OCR；
  - 图片：直接 OCR。

**端上 OCR**（2026-06-15 补，ML Kit）：

- `chat/application/ocr_service.dart`：`OcrService`——`google_mlkit_text_recognition`（中文脚本）
  识别图片；`pdfx` 把扫描件 PDF 逐页 2x 渲染成图再识别（限 20 页）。`pdfNeedsOcr` 为纯函数
  （可单测）；耗时识别在 UI 用模态加载框。
- 新增依赖：`google_mlkit_text_recognition` + `pdfx`。
- ⚠️ **平台限制**：**仅 Android / iOS 有原生实现**，由 `OcrService.isSupported`
  （`Platform.isAndroid || isIOS`）守卫，桌面 / web 调用时优雅提示「当前平台不支持 OCR」。
- **HarmonyOS 壳已处理**：这两个插件无 OHOS 原生实现，故在 `ohos_stubs/` 新增同名**空实现
  stub 包**（仅 `OcrService` 用到的 Dart API 形状，调用即抛 `UnsupportedError`），
  `chatgpt_flutter_ohos/pubspec.yaml` 用 `dependency_overrides` 覆盖到它们 → OHOS 共享核心可
  编译；运行时 `isSupported` 在 OHOS 为 false，stub 永不触发。已用标准 flutter 把核心覆盖到
  stub 验证 `OcrService` 编译通过（OHOS 真机构建需在该环境另行确认）。
- 测试：`test/ocr_service_test.dart` 4 例（`pdfNeedsOcr` 判定 + imageExtensions）；原生识别需
  真机，未在单测覆盖。全套 **219** 测试通过。

**已知限制 / 下一步**：

- 仅关键词检索（同义/语义召回弱）。
- 知识库目前对**所有绑定该工具的助手共享**（按账号一个库）；如需「每个助手独立知识库」，
  要在表上加 `assistantId` 维度并在工具/UI 串起来。
- **L4b**：把 `search` 换/并入向量检索（embedding API + 余弦相似），catalog 与 UI 不变。
