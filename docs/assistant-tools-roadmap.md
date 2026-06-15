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
