# ChatAI Deep 流式翻译可靠性设计

- 日期：2026-07-16
- 状态：方向已由用户批准，等待用户复核书面规格
- 适用范围：酒馆房间导入、酒馆模板中文副本及它们复用的角色卡翻译引擎
- 核心目标：消除长字段的级联超时与重复计费，让用户为每次翻译选择已配置模型，并在模型支持时默认关闭深度思考

## 1. 决策摘要

采用“任务级模型选择 + 流式活动超时 + 小块串行翻译 + 真取消 + 块级检查点”的方案：

1. 每次开始翻译前展示模型选择器，列出当前账号已配置的模型；默认选中该账号上次用于翻译的模型，但不修改全局聊天模型。
2. 翻译默认开启“关闭深度思考”。只有已知服务商和模型明确支持时才发送对应参数；未知或不支持的端点不发送猜测参数。
3. 翻译使用流式响应，累计最终正文并忽略推理正文；推理或正文增量都算作连接活动，避免持续输出时被固定 120 秒误判超时。
4. 超时拆分为首个事件 45 秒、空闲 60 秒、单块总时长 5 分钟。超时、用户取消或租约丢失必须真正关闭底层请求。
5. 世界书从第一次请求起按目标 900 字、硬上限 1200 字切块；其它超长字段按目标 1800 字、硬上限 2400 字切块。不得再先发送 2200 字大块并原尺寸等待两次。
6. 默认串行处理，第一阶段不启用并发。超时不原尺寸重试，而是直接安全细分；429、5xx 和网络错误按类别退避，鉴权与参数错误立即停止。
7. 持久任务每块成功后立即保存检查点。App 重启、后台接管或用户换模型继续时，只处理未完成块。
8. 失败块不能被日志标记为“字段已翻译”。任务暂停后允许“继续重试”“换模型继续”或“保留失败块原文并完成”。

## 2. 已核实问题

用户日志中的世界书有 33,322 字。当前实现先按 2,200 字拆为 16 块，每块固定请求两次；调用方又把每次请求限制为 2 分钟。前两次失败后，才把同一块降为约 900 字的小块，而每个小块仍可请求两次。

第一块的实际时序是：

```text
2,200 字请求：120 秒超时
同一请求重试：120 秒超时
小块 1：53 秒成功
小块 2：120 秒超时 + 34 秒成功
小块 3：40 秒成功
```

因此一次大块失败被放大为至少 4 分钟空等，并产生重复输入、重复输出计费和上游并发重叠。

现有 `.timeout(...)` 只停止等待 Future，不会自动取消底层 HTTP 请求：

- 直连路径创建 `HttpClient` / `IOClient` 后没有在成功、异常或取消时确定关闭。
- 后端路径的移动端请求同样只给 Future 加超时。
- NestJS 非流式上游请求没有 `AbortSignal`；客户端开始重试时，旧请求可能仍在服务商侧运行。
- 用户取消只在请求前后检查，不能立即停止正在进行的请求。

另有两处可靠性缺口：

- 只有整个字段完成后才保存字段检查点；世界书翻译到后段中断仍会重做已成功块。
- 实际产生日志的酒馆房间导入入口仍是内存任务；App 被系统结束后没有恢复能力。

## 3. 目标与非目标

### 3.1 目标

- 长翻译持续输出超过 120 秒时仍可正常完成。
- 请求停滞或用户取消后，底层连接及时关闭，不与下一次请求重叠。
- 翻译任务使用用户明确选择的模型，并在后台恢复后保持同一选择。
- 翻译默认使用非思考模式，但不会因发送不兼容参数导致 400。
- 持久任务任一块成功后都可恢复，避免重复翻译和重复计费。
- 错误分类、进度与日志真实反映等待、退避、部分完成和暂停状态。
- 保持旧任务、旧数据库和旧 AI 设置可读，不复制 API Key 到任务表。

### 3.2 非目标

- 第一阶段不自动判断哪个模型客观上最快；模型由用户选择。
- 第一阶段不并行翻译多个块，避免限流和顺序错乱。
- 普通单角色卡导入会复用新的流式传输与分块策略，但其任务持久化不在本期范围。
- 不把翻译模型写回全局聊天配置。
- 不为所有 OpenAI 兼容自定义端点猜测 Thinking 参数。
- 不承诺第三方服务商的固定完成时间，只保证本地不制造重复请求风暴。

## 4. 用户流程

### 4.1 开始翻译

用户开启“翻译为简体中文”后，在创建任务前展示“翻译设置”弹窗：

```text
翻译模型
  跟随全局设置
  后端代理 · 当前后端模型
  已启用服务商名称 · 已配置模型 ID

[开] 关闭深度思考
      当前模型支持 / 当前接口不支持强制关闭

预计内容：1 个角色 · 45,260 字

取消                         开始翻译
```

模型列表规则：

1. “跟随全局设置”始终存在。
2. 本地直连模型只来自已启用、API Key 非空、模型 ID 非空的服务商。
3. 后端模式至少展示当前已配置的 `backendModel`。
4. 连通性测试成功的模型排在未测试模型之前，失败模型仍可见但带状态提示。
5. 当前账号上次成功启动翻译时的选择作为默认值；选择失效时回退“跟随全局设置”。

“关闭深度思考”默认开启并按账号记住。若当前模型不支持明确的关闭方式，开关不可用，并说明“该接口不会发送 Thinking 参数；建议选择非推理快速模型”。

### 4.2 运行、失败与恢复

任务卡展示服务商/模型、角色、字段、块序号、已完成字符数、请求耗时和错误类别，但不显示 prompt、Key、完整 URL 或正文。总体进度按已完成源字符数计算，不再让六个长度悬殊的字段等权。

可恢复错误耗尽自动尝试后，任务进入“已暂停，可重试”，保留已成功块。用户可：

1. 使用原模型继续。
2. 重新选择模型后继续。
3. 保留失败块原文并完成。
4. 取消任务。

只有第三种选择会生成包含原文块的部分翻译结果，任务状态和日志必须明确显示“部分翻译完成”。

## 5. 模型选择与任务快照

UI 偏好使用 `TranslationModelPreference`，允许 `followGlobal | local | backend`。
任务创建时必须把偏好解析为不含秘密、始终具体的
`TranslationModelSelection`：

```text
mode: local | backend
providerId: String?
modelId: String?
reasoningPolicy: offIfSupported | providerDefault
```

存储规则：

- 上次 UI 偏好按账号保存；只包含模式、服务商 ID、模型 ID 和策略，不包含 API Key。
- 如果用户选择“跟随全局设置”，任务创建时立即解析当时实际生效的模式、服务商和模型，并把这个具体快照写入任务；后续全局设置变化不会让运行中的任务换模型。
- 任务创建时把选择快照写入任务记录，确保前台转后台或 App 重启后仍使用同一模型。
- 执行时从当前账号的 `AISettings` 克隆配置，再应用任务快照。
- 服务商被禁用、模型被删除或 Key 不可用时，任务进入“需要重新选择模型”，不能静默切换到另一个可能收费的模型。
- 后台 worker 继续从安全存储读取 secrets；任务表、备份和同步不得保存 secrets。

翻译选择器复用会话模型选择器的展示、搜索、测试状态和最近使用排序逻辑。公共展示逻辑从会话页私有方法抽出，避免复制两套规则。

## 6. Thinking 兼容策略

关闭 Thinking 能减少推理 token 与延迟，但不是所有模型的通用能力。请求构造使用 typed adapter，不向业务层暴露任意 `extra_body`：

```text
ReasoningControlAdapter.resolve(providerId, providerCode, modelId, policy)
  -> supported
  -> request fields
  -> user-facing explanation
```

首阶段支持矩阵：

| 服务商/模型 | 关闭参数 | 策略 |
| --- | --- | --- |
| DeepSeek V4 双模式模型 | `thinking: {"type":"disabled"}` | 已知模型发送 |
| DashScope/Qwen 支持模型 | `enable_thinking: false` | 已知模型发送 |
| OpenAI 明确支持 `none` 的模型 | `reasoning_effort: "none"` | 白名单发送 |
| Gemini 当前 OpenAI 兼容传输 | 不发送 | 原生参数与当前传输格式不同 |
| 自定义/聚合端点 | 不发送 | 不猜测兼容性 |

若适配器发送的参数收到明确的“未知参数/不支持”400，当前任务只自动重试一次且移除 Thinking 参数；后续块不再发送该参数，也不修改全局 provider 配置。

参考：

- [DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)
- [Alibaba Model Studio Qwen OpenAI-compatible API](https://help.aliyun.com/en/model-studio/qwen-api-via-openai-responses)
- [OpenAI Chat Completions](https://platform.openai.com/docs/api-reference/chat/create)
- [Gemini Thinking](https://ai.google.dev/gemini-api/docs/generate-content/thinking)

## 7. 流式传输与取消合同

翻译请求使用现有 `StreamEvent` 通道，并增加翻译专用配置：

```text
firstEventTimeout: 45 seconds
idleTimeout: 60 seconds
totalTimeout: 5 minutes
reasoningPolicy: offIfSupported
responseMode: translationJson
cancellation: task/user/lease
```

行为：

1. 请求发出到第一个 SSE 事件最多等待 45 秒。
2. 收到任意有效 SSE 增量后重置 60 秒 idle timer；`reasoning_content` 不写入译文，但算作活动。
3. 单块总时长最多 5 分钟。
4. 最终只累计 `content`，流结束后统一进行 JSON 提取和字段校验。
5. timeout、订阅取消、用户取消、账号变化或租约丢失调用同一个 cancel 路径。
6. Direct transport 在 `finally` 中关闭 `IOClient` 和 `HttpClient`。
7. Backend transport 取消移动端 client；NestJS 在客户端断开、idle timeout 或 total timeout 时 abort 上游 fetch。
8. 不再在翻译服务和页面各套一层互相竞争的 wall-clock timeout。

端点明确返回“不支持 stream”时任务暂停并提示换模型；第一阶段不静默切回可能再次阻塞的非流式请求。

## 8. 分块、校验与重试

### 8.1 稳定分块

每个块包含 `index`、源范围、`sourceHash`、`inputHash`、原始分隔符、状态、译文、attempt 和错误类别。字符预算按 Dart `runes.length` 计算；相同源文本与策略版本必须产生相同边界和 hash。

- `memoryBook` 优先按完整世界书条目和换行切分，目标 900 字，硬上限 1200 字。
- 其它字段超过 2400 字时按段落、换行、句末标点切分，目标 1800 字，硬上限 2400 字。
- 单条超过硬上限时先找标点和空白，最后才按 Unicode 边界硬切。
- 保存原始块间分隔，合并时不得无条件插入新换行。
- prompt 要求保持 `[off]`、`[p=]`、`[re]`、`[sec=]`、`=>`、正则、变量和 URL 不变。
- 单块至少允许 2048 output tokens，避免被较低的全局聊天上限截断。

每块完成后必须找到目标字段的 JSON 字符串，拒绝空值、字段缺失和截断 JSON。世界书还要检查受保护标记的数量与顺序。成功后立即写检查点，再推进 UI。

### 8.2 错误策略

错误映射为取消、鉴权、无效请求、不支持 Thinking 参数、限流、服务端故障、网络、三类 timeout 和无效输出。

- 401/403 和普通 400：暂停，不重试。
- Thinking 参数不兼容：移除参数，只重试一次。
- 429：最多自动重试两次；`Retry-After` 限制在 1–120 秒，缺失时使用 base 2 秒、上限 30 秒的 full-jitter 指数退避。
- 5xx/网络：最多自动重试一次，使用 base 1 秒、上限 5 秒的 full-jitter 退避。
- timeout：真正取消；世界书块大于 400 runes、其它块大于 800 runes 时按安全边界近似二分，不原尺寸重试；达到最小块仍超时则暂停。
- 无效 JSON：同尺寸只允许一次格式修复请求。

退避写入现有任务 `nextRunAt` 并释放租约，不通过长 `Future.delayed` 占住 isolate。

## 9. 持久任务与兼容迁移

现有 `tb_story_template_translation_task` 使用 additive migration 扩展：

```text
taskKind: templateCopy | tavernRoomImport
requestProfile: JSON，不含 secrets
chunkPayload: JSON
outputRoomId: integer?
checkpointVersion: integer
```

- 旧行按 `templateCopy + legacy field checkpoint` 读取。
- 旧任务继续使用字段级恢复；新任务才启用块级检查点。
- `sourcePayload` 保持不可变源快照；hash 不一致时作废旧块。
- `partialPayload` 保存已完成角色，`chunkPayload` 只保存当前字段块状态。
- 房间导入 finalizer 先保存模板再创建房间，并记录 `outputRoomId`；重复恢复不得创建第二个房间。
- 模板中文副本继续通过 `outputTemplateId` 保持幂等。

实际产生日志的 `assistant_list_page` 酒馆房间导入入口改为创建持久 `tavernRoomImport` 任务，不再由页面私有内存 coordinator 持有整个生命周期。页面只观察任务和展示进度。

## 10. 组件边界

- `TranslationModelResolver`：把当前设置与任务模型选择解析为本任务 settings clone；不联网、不落库、不修改全局设置。
- `TranslationChunkPlanner`：产生稳定、有 hash、保持分隔符的 chunks；不调用模型、不访问数据库。
- `TranslationStreamExecutor`：执行单块流式请求、活动计时、真取消和错误分类；不负责业务落库。
- `RoleCardTranslationPipeline`：按角色、字段、块编排，成功一块即 checkpoint，根据错误决定细分、退避或暂停。
- 持久任务 runner：持有账号 lease，把 pipeline 状态写入任务，完成后调用 template-copy 或 tavern-room finalizer。

账号、租约或取消状态变化时必须立即取消活动请求。

## 11. 日志与隐私

允许记录 task/request ID、provider/model ID、字段、块序号、字符数、首事件耗时、总耗时、attempt、错误类别、HTTP 状态和 cancel 结果。

禁止记录 API Key、Authorization、boarding pass、prompt、原文、译文、完整 URL、文件路径、账号原文和上游错误正文。

日志明确区分“流式接收中”“请求已取消”“等待限流退避”“块已完成”“块已暂停”和“部分翻译完成”。

## 12. 测试设计

### 12.1 单元测试

- 33,322 字世界书第一次请求起就不超过 1200 字。
- 同一超限 payload 不会连续发送两次。
- 相同文本与策略产生相同边界/hash，合并后顺序和分隔符不变。
- timeout 直接细分；429/5xx/网络遵循各自策略。
- DeepSeek、Qwen、OpenAI 白名单映射正确；未知 provider 不发送 Thinking 参数。
- Thinking 参数被拒绝时只回退一次。
- 已完成块恢复时不再请求；source hash 变化会作废旧块。

### 12.2 Transport 测试

- 本地延迟服务器持续发送 SSE 超过 120 秒时任务不超时。
- 60 秒无事件触发 idle timeout，并在 2 秒内观察到连接关闭。
- 用户取消和 lease 丢失会关闭 Direct 与 Backend 请求。
- Backend 客户端断开后 NestJS abort 上游 fetch。
- reasoning 增量重置 idle timer，但不会写入译文。

长时间测试使用 fake clock 或可注入 timer，不让常规测试真实等待分钟级。

### 12.3 DAO、Widget 与集成测试

- 第 N 块后中断，恢复时只请求 N+1 及以后。
- 换模型继续保留已成功块，并更新后续请求快照。
- 429 写 `nextRunAt` 并释放 lease，到期前不能重新领取。
- 旧字段级任务仍可恢复；房间任务重放不会重复创建模板或房间。
- 模型弹窗展示已配置模型、记住账号选择且不修改全局模型。
- 使用 fake SSE 完成 30K+ 世界书，验证无大块探测请求、进度持续推进、最终顺序正确。

## 13. 验收标准

1. 不再出现“同一 2200 字块连续等待两次 120 秒”。
2. 任一请求的源字段文本不超过对应硬上限。
3. 连续收到 SSE 的请求可运行超过 120 秒；停滞 60 秒会触发取消，底层连接在 2 秒内关闭。
4. timeout 后不存在旧请求与新 attempt 同时活动。
5. 持久任务在 App 重启后不会再次请求已成功块。
6. 用户选择的模型在前台、后台和恢复后保持一致，全局模型不变。
7. 支持的模型默认关闭 Thinking；不支持的模型不会收到未知参数。
8. 任一原文块被保留时，UI 不得显示“字段已翻译”或“全部完成”。
9. 新字段使用 guarded additive migration；旧任务与旧配置继续可读。
10. 相关单元、DAO、widget、transport 测试及 `flutter analyze` 全部通过。

## 14. 实施边界

详细步骤由后续 implementation plan 定义，顺序锁定为：

1. typed request profile、Thinking adapter 与任务级模型解析。
2. 可取消流式 transport 和 timeout 状态机。
3. 稳定 chunk planner、校验和 pipeline。
4. 块级检查点与旧任务兼容迁移。
5. 酒馆房间导入接入持久任务和模型选择 UI。
6. 错误恢复 UI、日志与完整回归。

每一阶段必须先写失败测试并观察预期失败，再实现最小改动；不得把并发翻译或自动测速混入本次范围。
