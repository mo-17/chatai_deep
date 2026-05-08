# 任务清单：账号隔离 + 流式输出开关

> 适配执行模型：DeepSeek。本文档自包含，逐任务可独立完成。
> 仓库根路径：`/Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep/`
> Flutter 主包：`chatgpt_flutter/`，路径依赖：`openai_flutter/`、`login_sdk/`、`chat_message/`、`hi_download/`，后端：`chatgpt_backend/`。

---

## 背景与现状诊断

### 问题 1：切换账号后，前一账号的对话和配置仍然保留

根因（多处「全局键」漏洞）：

| 位置 | 问题 |
|------|------|
| `chatgpt_flutter/lib/dao/ai_settings_dao.dart:7` | `AISettings` 存在 `HiCache` 的全局键 `ai_settings_v1`，所有账号共用一份配置 |
| `chatgpt_flutter/lib/provider/hi_provider.dart:8` | `AISettingsProvider` 在应用启动时只 `load()` 一次；登出/重登不会重新加载 |
| `chatgpt_flutter/lib/dao/hi_api_cache.dart:48` | `HiAPICache` 用纯 URL 作 key，跨账号共用 |
| `chatgpt_flutter/lib/db/hi_db_manager.dart:10` | `_storageMap` 是进程内常驻 Map，登出时不会关闭旧账号 DB 连接 |
| `login_sdk/lib/dao/login_dao.dart:87` | `logOut()` 只 remove `user_info` + 跳转登录页，没有清缓存、关 DB、重置 Provider —— 切号污染的根源 |

数据库本身按 `accountHash` 分库（`HiDBManager.getAccountHash()`）逻辑是对的，但 `ConversationListPage` 把 `conversationListDao` 缓存在 widget state 上（`wantKeepAlive=true`），切号后 DAO 仍指向旧 DB。

### 问题 2：缺少流式输出开关

- `openai_flutter/lib/core/ai_completions.dart` + `openai_flutter/lib/http/ai_http.dart:32` —— 现在只有单次 POST + JSON 解析，不支持 SSE。
- `chatgpt_backend/src/chat/chat.service.ts:76` —— 后端也是非流式 fetch，不写 SSE。
- `chatgpt_flutter/lib/pages/conversation_page.dart:112` —— 收到完整字符串才一次性 `_addMessage`，无法增量渲染。
- 模型层 `AISettings` 没有 `streamEnabled` 字段，UI 也无入口。

---

## 推进顺序

两条线并行：

**A. 账号隔离**（解决数据残留问题）
1. **任务 1** — 扩展 logOut 流程，集中清理账号态
2. **任务 2** — AI 设置改为按账号隔离
3. **任务 3** — 关闭旧账号 DB 并刷新会话页 DAO（依赖任务 1）

**B. 流式输出开关**
4. **任务 4** — `AISettings` 增加 `streamEnabled` 字段与开关 UI
5. **任务 5** — 实现本地直连 (DirectChatService) 流式响应（依赖任务 4）
6. **任务 6** — 后端 SSE 接口 + BackendChatService 流式消费（依赖任务 4）
7. **任务 7** — `ConversationPage` 接入流式渲染（依赖任务 5、6）

---

## 任务 1：扩展 logOut 流程，集中清理账号态

**目标**：登出时把当前账号的所有内存/缓存全部清理，避免与下一账号串数据。

**改动点**：

1. `login_sdk/lib/dao/login_dao.dart:87` `LoginDao.logOut()`：保持 `HiCache.remove(kUserInfo)` 不变，但增加一个钩子（推荐用回调注册而非反向依赖），让宿主 App 能在 `logOut` 前后执行清理逻辑。例如：
   ```dart
   static final List<VoidCallback> _onLogoutHooks = [];
   static void addLogoutHook(VoidCallback cb) => _onLogoutHooks.add(cb);
   static void logOut() {
     for (final cb in _onLogoutHooks) {
       try { cb(); } catch (_) {}
     }
     HiCache.getInstance().remove(kUserInfo);
     NavigatorUtil.goToLogin();
   }
   ```

2. `chatgpt_flutter/lib/main.dart:60` `doInit()` 中注册以下钩子：
   - `HiDBManager` 暴露 `closeAll()` 静态方法：遍历 `_storageMap` 并 `db.close()`，然后 `_storageMap.clear()`（具体实现见任务 3）。
   - 删除 AI 设置：`HiCache.getInstance().remove('ai_settings_v1')`（理想做法是在任务 2 改造后变成 per-account key，本任务先按当前键清理）。
   - 清 `HiAPICache`：`HiCache` 没现成的 prefix delete，需要在 `HiAPICache` 增加 `clearAll()`，内部用 `_hiCache.remove` 配合 keys 列表（如果 `HiCache` 不支持枚举 key，可改为给 `HiAPICache` 维护 key 集合）。

3. 通过 `BottomNavigator.build` 已经在调用 `NavigatorUtil.updateContext(context)`；可以借助 `BottomNavigator` 的 `initState` 注册一次钩子，避免重复注册（用 static bool 防重）。

**验收**：

- 用账号 A 登录、生成几条对话、改 AI 设置；登出，用账号 B 登录，B 看不到 A 的对话（DB 已分库这点应已 ok），B 的 AI 设置回到默认。
- 第二次登出再登录账号 A 时，A 的对话仍在（因为是 SQLite 持久化，没被删，只是连接被关再重开）。

---

## 任务 2：AI 设置改为按账号隔离

**目标**：每个账号独立保存自己的 AI 设置，登出/切换账号自动加载对应账号的设置；未登录时使用临时默认值。

**改动点**：

1. `chatgpt_flutter/lib/dao/ai_settings_dao.dart:7`：将 `_kKey = 'ai_settings_v1'` 改成基于账号哈希拼接：
   ```dart
   import 'package:login_sdk/dao/login_dao.dart';

   static String _key() {
     final hash = LoginDao.getAccountHash() ?? 'guest';
     return 'ai_settings_v1_$hash';
   }
   ```
   `load()` / `save(s)` 都使用 `_key()`。

2. `chatgpt_flutter/lib/provider/ai_settings_provider.dart`：`load()` 已存在，`notifyListeners()` 已调用。可暴露一个语义更清晰的 `reload()` 别名。

3. `chatgpt_flutter/lib/main.dart:60` 在 `doInit()` 末尾、登录成功跳转主页之后、登出钩子里都调用 `AISettingsProvider.load()`。
   - 登录成功跳转点在 `login_sdk/lib/pages/login_page.dart:120`，跳转后回到 `BottomNavigator`，可以在 `BottomNavigator.initState` 调一次 `context.read<AISettingsProvider>().load()`，确保每次进入主页都按当前账号加载。

4. 兼容旧版数据（可选）：如果新 key 不存在但旧 `ai_settings_v1` 存在，把旧值 migrate 到当前账号 key 后删除旧键（仅迁移一次）。

**验收**：

- 账号 A 设置 OpenAI key，登出，账号 B 登录后 AI 设置页显示默认值（key 为空）。
- 重新登录账号 A，AI 设置页恢复为之前设置的 OpenAI key。

---

## 任务 3：关闭旧账号 DB 并刷新会话页 DAO

**依赖**：任务 1

**目标**：登出时关闭并丢弃旧账号 DB 句柄；会话列表页/对话页在重新登录后必然走新账号 DB。

**改动点**：

1. `chatgpt_flutter/lib/db/hi_db_manager.dart:8`：新增 `static Future<void> closeAll()`，遍历 `_storageMap.values` 调用 `await mgr._db.close()`，然后 `_storageMap.clear()`。在任务 1 的 `logOut` 钩子中调用。

   ```dart
   static Future<void> closeAll() async {
     for (final mgr in _storageMap.values.toList()) {
       try { await mgr._db.close(); } catch (_) {}
     }
     _storageMap.clear();
     debugPrint('HiDBManager: all dbs closed');
   }
   ```

2. `chatgpt_flutter/lib/pages/conversation_list_page.dart:21`：当前 `wantKeepAlive=true` 且 `conversationListDao` 在 `initState` 一次性创建。需要保证：
   - 登出后 `BottomNavigator` 应被销毁。目前 `LoginDao.logOut()` 用 `Navigator.pushReplacement` 跳到 `LoginPage`，重新登录 `goToHome` 又 `pushReplacement` 进 `BottomNavigator` —— 是新实例，OK。
   - 在 `BottomNavigator.initState` 里加上一次性 reload `AISettingsProvider`。
   - 不需要监听账号变更动态切换 DAO，因为登出已经销毁页面树。

3. `chatgpt_flutter/lib/pages/conversation_page.dart:165`：每次进入都新建 DAO，不缓存跨账号实例，不需要改。但要让任务 1 的 `closeAll()` 在所有页面 dispose 之后再执行（用 `WidgetsBinding.instance.addPostFrameCallback` 包一下，或者放到 `goToLogin` 之后微任务里）。

**验收**：

- 登录 A → 进入会话列表（建立 A 的 DB 连接）→ 登出 → 登录 B → 会话列表显示 B 的数据（空或独立）。
- 在 logcat / debug console 中确认旧 DB 文件路径的连接已关闭（可在 `closeAll` 加一行 `debugPrint`）。

---

## 任务 4：`AISettings` 增加 `streamEnabled` 字段与开关 UI

**目标**：在 AI 设置页加一个 `Switch`，控制是否使用流式输出；字段持久化到 `AISettings`。这是后续两个流式实现任务的基础。

**改动点**：

1. `chatgpt_flutter/lib/model/ai_settings.dart`：
   - `AISettings` 添加 `bool streamEnabled`，默认 `true`（更现代的体验，但若担心兼容性可设 `false`）。
   - `defaults()`、`fromJson`（含缺省回退）、`toJson` 全部更新；`fromJson` 要兼容旧数据（缺字段时取默认值）：
     ```dart
     streamEnabled: j['streamEnabled'] as bool? ?? true,
     ```

2. `chatgpt_flutter/lib/pages/ai_settings_page.dart`：
   - 新增 state `late bool _streamEnabled;` 在 `initState` 读取。
   - 在 `_buildModeCard` 之后插入一个新的 `Card`「响应方式」，里面用 `SwitchListTile` 控制：
     - 标题：流式输出
     - 副标：开启后逐字显示 AI 回复，关闭则等待完整回复一次性展示
   - `_buildSettings()` 把 `_streamEnabled` 带上。

3. （可选）`aiDisplayName` 旁边的 `effectiveModel` 不需要改。

**验收**：

- 设置页能看到开关，切换并「保存」后重新进入设置页保持开关状态。
- 此任务**不涉及**实际流式逻辑，仅落字段。后续任务消费它。

---

## 任务 5：实现本地直连 (DirectChatService) 流式响应

**依赖**：任务 4

**目标**：当 `mode = local && streamEnabled = true` 时，DirectChatService 通过 SSE 方式拿到 OpenAI/DeepSeek 的增量片段。

**改动点**：

1. `openai_flutter/lib/core/ai_completions.dart`：新增 `Stream<String> createChatStream({...})`，body 中加上 `"stream": true`，接收 SSE 流。

2. `openai_flutter/lib/http/ai_http.dart`：新增 `static Stream<String> postStream({...})`：
   - 用 `http.Client().send(http.Request('POST', ...))` 拿到 `StreamedResponse`，对 `response.stream.transform(utf8.decoder).transform(LineSplitter())` 逐行解析。
   - SSE 行格式 `data: {...}` / `data: [DONE]`，解析 JSON 后取 `choices[0].delta.content`，yield 出非空 token。
   - 错误处理：HTTP 非 2xx 时把整段 body 解析为 `error.message` 抛 `AIRequestException`。
   - 代理设置参考现有 `AIHttp.post` 的实现，复用 `HttpClient` + `IOClient` 模式。

3. `chatgpt_flutter/lib/dao/chat/chat_service.dart`：把接口扩展为
   ```dart
   abstract class ChatService {
     Future<String?> chat({
       required String prompt,
       required List<Map<String, String>> history,
     });
     Stream<String> chatStream({
       required String prompt,
       required List<Map<String, String>> history,
     });
     factory ChatService.from(AISettings s) { ... }
   }
   ```

4. `chatgpt_flutter/lib/dao/chat/direct_chat_service.dart`：实现 `chatStream`，调用 `AICompletion.createChatStream`，把 yield 的片段直接转发出去。

5. `chatgpt_flutter/lib/dao/completion_dao.dart`：增加 `Stream<String> streamCompletions({required String prompt})`，复用 `_messageList` 拼 history，调用 `chatService.chatStream`。

**验收**：

- 在 AI 设置打开「流式输出」+ 本地模式 + 有效 OpenAI/DeepSeek key，调用 `streamCompletions` 能逐段 yield 到完整回复。
- 关闭流式时仍走原 `chat` 路径，行为不变。
- 本任务不改 UI（任务 7 来接 UI）。

---

## 任务 6：后端 SSE 接口 + BackendChatService 流式消费

**依赖**：任务 4

**目标**：让后端模式也支持流式。后端透传上游 SSE，前端按 SSE 解析。

**改动点（后端）**：

1. `chatgpt_backend/src/chat/chat.service.ts:63` `callUpstream`：抽出一个 `streamUpstream(provider, body): Promise<NodeJS.ReadableStream>`，内部 fetch 时 `body` 加 `stream: true`，返回 `resp.body`。usage 统计在流末尾通过累计或最后一行 `data: {usage:...}` 解析（OpenAI/DeepSeek 流末尾通常带 usage）。

2. `chatgpt_backend/src/chat/chat.controller.ts`：新增 `POST /uapi/chat/completions/stream`：
   ```ts
   @Post('completions/stream')
   @UseGuards(JwtGuard)
   async stream(@Req() req, @Body() body, @Res() res: Response) {
     res.setHeader('Content-Type', 'text/event-stream');
     res.setHeader('Cache-Control', 'no-cache');
     res.setHeader('Connection', 'keep-alive');
     // pipe upstream stream → res，并拦截 [DONE] 后做 usage 落库
   }
   ```

3. `CLAUDE.md` 记得更新「Backend routes」段落，新增此端点说明。

**改动点（前端）**：

4. `chatgpt_flutter/lib/dao/chat/backend_chat_service.dart`：新增 `chatStream`，目标 URL 替换为 `/uapi/chat/completions/stream`，用 `http.Client().send(http.Request)` 接 `StreamedResponse`，按 SSE 行解析。401 仍走 `LoginDao.logOut()` 并抛异常。

5. 后端业务错误（`code != 0`）若以 SSE 一行 `event: error\ndata: {...}` 的形式发送，前端要能识别并抛错。

**验收**：

- 后端模式 + 流式开关，能从 `/uapi/chat/completions/stream` 拿到逐字流。
- 关闭流式仍走原 `/uapi/chat/completions`。
- 后端 usage 表照常落库（不能因为流式丢失计费数据）。

---

## 任务 7：`ConversationPage` 接入流式渲染

**依赖**：任务 5、6

**目标**：当 `streamEnabled` 开启时，AI 回复气泡边接收边更新；接收完整回复后再写入 `messageDao`。

**改动点**：

1. `chatgpt_flutter/lib/pages/conversation_page.dart:103` `_onSend`：根据 `settings.streamEnabled` 分两条路径：
   - **非流式**：保持当前实现。
   - **流式**：
     - 先 `_addMessage` 用户消息（持久化到 DB）。
     - 创建一个空内容的 receiver `MessageModel`，**只**通过 `chatController.addMessage` 加入气泡（**先不**调 `messageDao.saveMessage`）。
     - ```dart
       await for (final chunk in completionDao.streamCompletions(prompt: inputMessage)) {
         buffer += chunk;
         chatController.updateMessage(model.copyWith(content: buffer));
       }
       ```
     - 流结束后再 `messageDao.saveMessage(finalModel)`，并调 `_notifyConversationListUpdate()`。

2. `chat_message` 包：检查 `ChatController` 是否已有 `updateMessage(model)` 接口；若没有，在 `chat_message/lib/core/chat_controller.dart` 添加：通过 id/createdAt 匹配 `_messageList` 中的元素并替换内容，再 `_messageStream.add(_messageList)`。

3. 错误兜底：流中途异常（包括网络断/上游返回 error），把已收到的 buffer 写入 DB（避免「显示了一半但没存」），并在气泡末尾追加错误提示；最后必须把 `_sendBtnEnable` 恢复为 `true`（用 try/finally）。

4. `dispose` 时若流未结束，需要取消订阅，避免 setState after disposed。可用 `StreamSubscription? _activeStreamSub` 持有句柄。

**验收**：

- 开关打开后发送消息，气泡逐字出现；按返回键退出再进入，能从 DB 加载到完整内容。
- 流途中关闭对话页不报错。
- 关闭开关后行为退回到一次性显示。

---

## 测试矩阵（全部完成后回归）

| 场景 | 期望 |
|------|------|
| 账号 A 登录 → 设置 AI key → 登出 → 账号 B 登录 | B 看到默认 AI 设置，看不到 A 的对话 |
| 账号 A → 登出 → 账号 A 重新登录 | 历史对话和 AI 设置全部恢复 |
| 流式开关开 + local + OpenAI key | 气泡逐字出现，结束后 DB 有完整记录 |
| 流式开关开 + backend | 同上，backend usage 表正常落库 |
| 流式开关关 | 等待完整回复一次性展示，行为同改造前 |
| 流式中途返回上一页 | 不抛 setState after disposed，已接收部分写入 DB |
| 流式中途网络断 | 气泡保留已收内容，发送按钮恢复可用，DB 落库 |

---

## 备忘

- Dart 注释保持中文，与现有风格一致。
- DAO 沿用 `IXxx` + `XxxDao` 接口/实现并存的格式（参考 `IConversationList` / `ConversationListDao`）。
- `pubspec.yaml` 的 path 依赖保持 `../<package>` 结构。
- 改后端时记得 `npm run lint` + 必要时 `npm test`；改 Flutter 时 `flutter analyze` + `flutter test`。
