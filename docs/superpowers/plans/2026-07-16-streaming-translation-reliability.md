# 流式翻译可靠性 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让酒馆房间、酒馆模板中文副本和普通角色卡翻译使用用户逐任务选择的已配置模型，通过可真正取消的流式请求、稳定小分块和块级检查点消除长字段级联超时与重复计费。

**Architecture:** UI 先把“跟随全局/本地/后端”偏好解析为不含凭据的具体 `TranslationRequestProfile`；运行器再用当前账号的安全 `AISettings` 严格还原该模型。翻译链路统一为 `ChatService typed SSE → TranslationStreamExecutor → AssistantRoleCardTranslationService`，传输层负责真取消和活动 deadline，业务层负责稳定分块、校验、重试决策和检查点，持久任务负责租约、恢复与原子 finalization。

**Tech Stack:** Flutter/Dart, Provider, package:http 1.6 `AbortableRequest`, openai_flutter, sqflite, crypto SHA-256, NestJS 11, TypeScript, Express SSE, Jest, flutter_test

## Global Constraints

- 每次开始翻译前展示模型选择；按 accountHash 记住上次成功启动翻译的偏好，但不得修改全局聊天模型。
- `followGlobal` 只存在于 UI 偏好；创建任务时必须解析成具体 `local | backend`、providerId 和 modelId 快照。
- `requestProfile`、偏好与日志不得保存 API Key、Authorization、boarding pass 或完整 URL；日志还不得保存 prompt、原文和译文。`sourcePayload/chunkPayload/partialPayload` 按既有本地任务/备份数据范围保存业务内容，执行队列不跨设备同步。
- 支持的模型默认关闭 Thinking；DeepSeek V4 使用 `thinking: {"type":"disabled"}`，DashScope/Qwen 使用 `enable_thinking: false`，OpenAI 只对白名单模型使用 `reasoning_effort: "none"`；Gemini OpenAI-compatible、自定义和聚合端点不猜参数。
- Thinking 参数收到明确“不支持/未知参数”400 时，本任务只回退一次；后续块不再发送该参数，不修改 provider 全局配置。
- 翻译只累计 `StreamEventType.text`；`reasoning` 和 `usage` 只作为连接活动，不进入译文。
- deadline 固定为首事件 45 秒、idle 60 秒、单块总时长 5 分钟；用户取消、账号变化、租约丢失和任一 deadline 都必须关闭底层请求。
- 世界书目标 900 runes、硬上限 1200 runes、timeout 细分下限 400 runes；其它长字段目标 1800、硬上限 2400、细分下限 800。
- 单块至少允许 2048 output tokens；第一阶段串行执行，不并发，不静默回退非流式请求。
- timeout 不允许原尺寸重试；429 最多 2 次，`Retry-After` 限制为 1–120 秒，否则 full-jitter base 2 秒/cap 30 秒；5xx/网络最多 1 次，full-jitter base 1 秒/cap 5 秒；无效 JSON 同尺寸只允许 1 次修复。
- 持久任务退避必须写 `nextRunAt` 并释放 lease，不用长 `Future.delayed` 占住 isolate。
- `tb_story_template_translation_task` 只做 guarded additive migration；旧任务按 `templateCopy` 和字段级 checkpoint 继续可读。
- `tavernRoomImport` finalization 必须幂等；重放不得重复创建模板、房间、参与者或开场消息。
- 任一块保留原文时状态必须为“部分翻译完成”，不得显示“字段已翻译”或“全部完成”。
- 不引入第二套翻译 endpoint、第二套任务表、并发翻译或自动测速模型。

---

## File and Responsibility Map

### Shared request/model domain

- Create `chatgpt_app_core/lib/chat/domain/chat_request_options.dart` — typed request profile、reasoning policy、abort trigger、connect timeout 和安全 transport error。
- Create `chatgpt_app_core/lib/chat/domain/translation_request_profile.dart` — UI preference、具体模型快照、JSON contract。
- Create `chatgpt_app_core/lib/chat/application/translation_model_resolver.dart` — 从 `AISettings` 创建/还原严格任务快照。
- Create `chatgpt_app_core/lib/chat/application/translation_model_preference_store.dart` — account-scoped 非秘密偏好。
- Create `chatgpt_app_core/lib/chat/application/reasoning_control_adapter.dart` — Dart 直连 Thinking 参数白名单。

### Transport and server

- Modify `openai_flutter/lib/http/ai_http.dart` and `openai_flutter/lib/core/ai_completions.dart` — `AbortableRequest`、`finally` close、`extraBody`、connect timeout、error SSE。
- Modify `chatgpt_app_core/lib/dao/chat/chat_service.dart`, `direct_chat_service.dart` and `backend_chat_service.dart` — translation options、semantic backend profile、typed failures。
- Create `chatgpt_backend/src/chat/reasoning-control.ts` — 后端 provider-aware Thinking mapping。
- Create `chatgpt_backend/src/chat/stream-deadline-controller.ts` — first/idle/total deadline state machine。
- Modify `chatgpt_backend/src/chat/dto/completion-body.dto.ts`, `chat.controller.ts` and `chat.service.ts` — semantic fields、客户端断链 signal、上游 abort 和安全错误元数据。

### Translation engine

- Create `chatgpt_app_core/lib/chat/application/translation_stream_executor.dart` — typed SSE collector、活动计时、真取消。
- Create `chatgpt_app_core/lib/chat/application/translation_retry_policy.dart` — 可测试的错误分类、jitter、细分/暂停决策。
- Create `chatgpt_app_core/lib/chat/application/translation_chunk_planner.dart` — rune-based 稳定边界、hash、separator、checkpoint JSON。
- Modify `assistant_role_card_translation_service.dart` and `tavern_room_import_preparer.dart` — 所有长字段使用 planner，并在每块成功后 await checkpoint。

### Persistent tasks and finalization

- Modify `story_template_translation_task_model.dart` and `story_template_translation_task_dao.dart` — taskKind/requestProfile/chunkPayload/outputRoomId/checkpointVersion、新状态和 guarded migration。
- Create `chatgpt_app_core/lib/chat/application/tavern_room_import_finalizer.dart` — 从译后 payload 构造模板、房间、参与者、开场的单一 bundle。
- Modify `story_room_dao.dart` — 暴露可复用 `DatabaseExecutor` transaction helper。
- Modify `story_template_translation_tasks.dart` — 两种 task kind、块级恢复、换模型继续、退避释放、部分完成。

### UI and entry wiring

- Create `chatgpt_app_core/lib/widget/configured_ai_model_picker_sheet.dart` — 会话与翻译共用模型 picker。
- Create `chatgpt_app_core/lib/widget/translation_settings_dialog.dart` — 每次任务的模型/Thinking 设置。
- Modify `conversation_page.dart`, `assistant_list_page.dart` and `story_room_list_page.dart` — 复用 picker，实际入口切流式/持久任务，恢复动作。
- Modify `app.dart` and `story_template_background_worker.dart` — 从 task snapshot 恢复，不再捕获当前全局 `ChatService`。
- Modify `backup_service.dart` and `local_sync_service.dart` — ID remap 和“执行队列仅本机”策略。

---

### Task 1: Typed task model snapshot and account preference

**Files:**

- Create: `chatgpt_app_core/lib/chat/domain/chat_request_options.dart`
- Create: `chatgpt_app_core/lib/chat/domain/translation_request_profile.dart`
- Create: `chatgpt_app_core/lib/chat/application/translation_model_resolver.dart`
- Create: `chatgpt_app_core/lib/chat/application/translation_model_preference_store.dart`
- Test: `chatgpt_app_core/test/translation_request_profile_test.dart`
- Test: `chatgpt_app_core/test/translation_model_preference_store_test.dart`

**Interfaces:**

- Consumes: `AISettings.clone()`, `AIMode`, `AiProvider.id/enabled/apiKey/models/effectiveModelId`, `LoginDao.getAccountHash()`.
- Produces:

```dart
enum ChatRequestProfile { standard, translation }
enum ChatReasoningPolicy { providerDefault, offIfSupported }

final class ChatRequestOptions {
  final ChatRequestProfile profile;
  final ChatReasoningPolicy reasoningPolicy;
  final Future<void>? abortTrigger;
  final Duration connectTimeout;
  final int? minOutputTokens;
  final bool suppressReasoningControl;
}

enum TranslationModelPreferenceMode { followGlobal, local, backend }
enum TranslationExecutionMode { local, backend }

final class TranslationModelPreference {
  final TranslationModelPreferenceMode mode;
  final String? providerId;
  final String? modelId;
  final ChatReasoningPolicy reasoningPolicy;
  Map<String, dynamic> toJson();
  factory TranslationModelPreference.fromJson(Map<String, dynamic> json);
}

final class TranslationRequestProfile {
  static const currentVersion = 1;
  final TranslationExecutionMode mode;
  final String? providerId;
  final String modelId;
  final ChatReasoningPolicy reasoningPolicy;
  final bool reasoningControlSuppressed;
  TranslationRequestProfile suppressReasoningControl();
  Map<String, dynamic> toJson();
  factory TranslationRequestProfile.fromJson(Map<String, dynamic> json);
}

final class TranslationModelResolver {
  static TranslationRequestProfile snapshot(
    AISettings settings,
    TranslationModelPreference preference,
  );
  static AISettings apply(
    AISettings current,
    TranslationRequestProfile profile,
  );
}
```

- [ ] **Step 1: Write failing profile/resolver tests**

Write tests that use two enabled `AiProvider` fixtures and assert: `followGlobal` snapshots the current exact mode/model; local snapshots provider id; backend snapshots backend model; `apply` returns a clone and leaves the source unchanged; deleted/disabled provider, missing Key and removed model throw `TranslationModelUnavailableException` instead of falling back.

```dart
test('followGlobal resolves once and apply never mutates global settings', () {
  final settings = _settingsWithProviders(activeProviderId: 'deepseek');
  final profile = TranslationModelResolver.snapshot(
    settings,
    const TranslationModelPreference(
      mode: TranslationModelPreferenceMode.followGlobal,
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    ),
  );

  expect(profile.mode, TranslationExecutionMode.local);
  expect(profile.providerId, 'deepseek');
  expect(profile.modelId, 'deepseek-chat');

  final applied = TranslationModelResolver.apply(settings, profile);
  expect(applied.activeProviderId, 'deepseek');
  expect(applied.effectiveModel, 'deepseek-chat');
  expect(identical(applied, settings), isFalse);
  expect(settings.activeProviderId, 'deepseek');
});

AISettings _settingsWithProviders({required String activeProviderId}) {
  return AISettings(
    mode: AIMode.local,
    providers: [
      AiProvider(
        id: 'deepseek',
        type: 'openai',
        name: 'DeepSeek',
        apiKey: 'test-key',
        apiHost: 'https://api.deepseek.com',
        models: [AiModel(id: 'deepseek-chat')],
        selectedModelId: 'deepseek-chat',
        enabled: true,
      ),
      AiProvider(
        id: 'openai',
        type: 'openai',
        name: 'OpenAI',
        apiKey: 'test-key',
        apiHost: 'https://api.openai.com',
        models: [AiModel(id: 'gpt-4.1')],
        selectedModelId: 'gpt-4.1',
        enabled: true,
      ),
    ],
    activeProviderId: activeProviderId,
    backendModel: 'backend-fast',
    streamEnabled: true,
    resetOnLogout: true,
  );
}
```

- [ ] **Step 2: Run resolver tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/translation_request_profile_test.dart
```

Expected: FAIL because the new libraries and types do not exist.

- [ ] **Step 3: Implement exact JSON and strict apply rules**

Use enum names in JSON, reject blank `modelId`, require `providerId` only in local mode, and serialize only `version/mode/providerId/modelId/reasoningPolicy/reasoningControlSuppressed`. In `apply`, find the provider by exact id before touching `activeProviderId`, verify enabled + non-empty Key + exact configured model, then set mode/model on the cloned settings.

- [ ] **Step 4: Write failing account-store tests**

Use an injected key-value adapter. Assert `keyFor('account-a') == 'translation_model_preference_v1_account-a'`, corrupt JSON falls back to `followGlobal + offIfSupported`, account A/B isolation, account switch during an awaited save rejects and restores the old visible value, and persisted JSON contains none of `apiKey/apiHost/token/authorization`.

- [ ] **Step 5: Implement the preference store**

Follow the existing awaited, account-checked persistence contract in `ai_onboarding_store.dart`. Expose:

```dart
abstract interface class TranslationPreferenceKeyValueStore {
  Object? read(String key);
  Future<bool> writeString(String key, String value);
  Future<bool> remove(String key);
}

final class TranslationModelPreferenceStore {
  static String keyFor(String accountHash);
  TranslationModelPreference read(String accountHash);
  Future<void> save(
    TranslationModelPreference preference, {
    required String expectedAccountHash,
  });
}
```

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
fvm flutter test --no-pub test/translation_request_profile_test.dart test/translation_model_preference_store_test.dart
fvm flutter analyze lib/chat/domain/chat_request_options.dart lib/chat/domain/translation_request_profile.dart lib/chat/application/translation_model_resolver.dart lib/chat/application/translation_model_preference_store.dart
git add lib/chat/domain/chat_request_options.dart lib/chat/domain/translation_request_profile.dart lib/chat/application/translation_model_resolver.dart lib/chat/application/translation_model_preference_store.dart test/translation_request_profile_test.dart test/translation_model_preference_store_test.dart
git commit -m "feat(story): snapshot translation model per task"
```

Expected: all named tests pass; analyze reports no issues.

---

### Task 2: Provider-aware Thinking control

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/reasoning_control_adapter.dart`
- Test: `chatgpt_app_core/test/reasoning_control_adapter_test.dart`
- Create: `chatgpt_backend/src/chat/reasoning-control.ts`
- Test: `chatgpt_backend/src/chat/reasoning-control.spec.ts`

**Interfaces:**

- Consumes: `ChatReasoningPolicy` and a resolved provider id/code + model id.
- Produces the same semantic decision in Dart and TypeScript:

```dart
final class ReasoningControlDecision {
  final bool supported;
  final Map<String, dynamic> requestFields;
  final String explanation;
}

abstract final class ReasoningControlAdapter {
  static ReasoningControlDecision resolve({
    required String? providerId,
    required String? providerCode,
    required String modelId,
    required ChatReasoningPolicy policy,
    bool suppressed = false,
  });

  static bool isExplicitUnsupportedParameter({
    required int statusCode,
    required String safeErrorCode,
  });
}
```

- [ ] **Step 1: Write the Dart decision-table tests**

Assert these exact mappings:

```dart
expect(_fields('deepseek', 'deepseek-v4-flash'),
    {'thinking': {'type': 'disabled'}});
expect(_fields('dashscope', 'qwen3.5-plus'), {'enable_thinking': false});
expect(_fields('openai', 'gpt-5.2'), {'reasoning_effort': 'none'});
expect(_fields('gemini', 'gemini-2.5-pro'), isEmpty);
expect(_fields('openrouter', 'openai/gpt-5.2'), isEmpty);
expect(_fields('custom_1', 'deepseek-v4-flash'), isEmpty);
```

Also assert `providerDefault` and `suppressed=true` always produce an empty field map, and unsupported-parameter fallback only matches status 400 plus allowlisted safe codes `unknown_parameter` / `unsupported_parameter`.

- [ ] **Step 2: Run Dart tests and verify RED**

Run `cd chatgpt_app_core && fvm flutter test --no-pub test/reasoning_control_adapter_test.dart`.

Expected: FAIL because `ReasoningControlAdapter` is missing.

- [ ] **Step 3: Implement a conservative Dart allowlist**

Use exact first-phase provider gates:

```dart
static const _deepSeekDualMode = {
  'deepseek-v4-pro',
  'deepseek-v4-flash',
};
static final _qwenThinking = RegExp(r'^qwen3(?:[.-]|$)');
static const _openAiNone = {
  'gpt-5.1',
  'gpt-5.1-chat-latest',
  'gpt-5.2',
  'gpt-5.2-chat-latest',
};
```

Provider id/code must be the first-party id; model name alone must never activate a parameter on custom/aggregator endpoints.

- [ ] **Step 4: Write and implement the TypeScript mirror**

Export:

```typescript
export type ReasoningPolicy = 'provider_default' | 'off_if_supported';

export function resolveReasoningControl(input: {
  providerCode: string;
  modelId: string;
  policy: ReasoningPolicy;
}): Record<string, unknown>;
```

Use the same cases and table-driven Jest expectations as Dart. The backend receives its trusted `provider.code` after `resolveProvider`, never a client-supplied provider code.

- [ ] **Step 5: Verify both implementations and commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/reasoning_control_adapter_test.dart
cd ../
pnpm --filter chatgpt_backend exec jest chat/reasoning-control.spec.ts --runInBand
git add chatgpt_app_core/lib/chat/application/reasoning_control_adapter.dart chatgpt_app_core/test/reasoning_control_adapter_test.dart chatgpt_backend/src/chat/reasoning-control.ts chatgpt_backend/src/chat/reasoning-control.spec.ts
git commit -m "feat(ai): map provider reasoning controls"
```

Expected: both decision tables pass.

---

### Task 3: Cancellable openai_flutter transport

**Files:**

- Modify: `openai_flutter/pubspec.yaml`
- Modify: `openai_flutter/lib/http/ai_exception.dart`
- Modify: `openai_flutter/lib/http/ai_http.dart`
- Modify: `openai_flutter/lib/core/ai_completions.dart`
- Modify: `openai_flutter/lib/core/interfaces/ai_create.dart`
- Test: `openai_flutter/test/ai_http_cancellation_test.dart`
- Test: `openai_flutter/test/openai_flutter_test.dart`

**Interfaces:**

- Consumes: package:http 1.6 `http.AbortableRequest`.
- Produces:

```dart
static Stream<AIStreamChunk> postStreamEvents({
  required AIConfigBuilder config,
  required String url,
  Map<String, dynamic>? body,
  Future<void>? abortTrigger,
  Duration connectTimeout = const Duration(seconds: 20),
});

Stream<AIStreamChunk> createChatStreamEvents({
  String model = 'gpt-3.5-turbo',
  List<Map<String, dynamic>>? messages,
  int? maxTokens,
  double? temperature,
  double? topP,
  List<Map<String, dynamic>>? tools,
  Map<String, dynamic> extraBody = const {},
  Future<void>? abortTrigger,
  Duration connectTimeout = const Duration(seconds: 20),
});
```

- [ ] **Step 1: Write local-server cancellation tests**

Create an `HttpServer.bind(InternetAddress.loopbackIPv4, 0)` fixture. Cover: SSE sends one token then holds; completing `abortTrigger` makes the server observe disconnect within one second; a 50 ms non-stream timeout closes the socket; `event: error` fails the stream; response headers survive in `AIRequestException`; reserved keys in `extraBody` are rejected.

```dart
final abort = Completer<void>();
final events = completion.createChatStreamEvents(
  model: 'test',
  messages: const [{'role': 'user', 'content': 'hello'}],
  abortTrigger: abort.future,
);
final subscription = events.listen(received.add, onError: errors.add);
await firstToken.future;
abort.complete();
await expectLater(serverObservedClose.future.timeout(const Duration(seconds: 1)),
    completes);
await subscription.cancel();
```

- [ ] **Step 2: Run SDK tests and verify RED**

Run:

```bash
cd openai_flutter
fvm flutter test test/ai_http_cancellation_test.dart test/openai_flutter_test.dart
```

Expected: FAIL because abort/extraBody/header APIs are absent and sockets remain open.

- [ ] **Step 3: Replace Future.timeout-only requests with AbortableRequest**

Raise `openai_flutter/pubspec.yaml` to `http: ^1.6.0`. Use one internal `Completer<void>` as the single abort path. External abort and connect timer complete it only when incomplete. Build `http.AbortableRequest`, call `IOClient.send`, and always cancel timers plus call `myClient.close()` in `finally`. Apply the same owned-client pattern to `AIHttp.post` so legacy non-stream callers no longer leave orphan requests.

- [ ] **Step 4: Add safe extra-body merging and error SSE parsing**

Reject overrides of `model/messages/stream/stream_options/tools/max_tokens/temperature/top_p`. Merge provider fields only after the canonical body is built. Parse `event: error` and top-level `{"error":...}` outside the broad JSON `FormatException` catch so application errors are not swallowed.

- [ ] **Step 5: Preserve status and Retry-After**

Extend `AIRequestException` with immutable lower-cased response headers and:

```dart
Duration? get retryAfter {
  final seconds = int.tryParse(headers['retry-after'] ?? '');
  return seconds == null ? null : Duration(seconds: seconds);
}
```

Do not include response bodies, Key, Authorization or URL in `toString()`.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```bash
fvm flutter test test/ai_http_cancellation_test.dart test/openai_flutter_test.dart
fvm flutter analyze
cd ..
git add openai_flutter/pubspec.yaml openai_flutter/lib/http/ai_exception.dart openai_flutter/lib/http/ai_http.dart openai_flutter/lib/core/ai_completions.dart openai_flutter/lib/core/interfaces/ai_create.dart openai_flutter/test/ai_http_cancellation_test.dart openai_flutter/test/openai_flutter_test.dart
git commit -m "fix(ai): make streaming requests cancellable"
```

Expected: the server sees disconnect, error events fail, SDK tests and analyze pass.

---

### Task 4: App transport options and Nest stream lifecycle

**Files:**

- Modify: `chatgpt_app_core/lib/dao/chat/chat_service.dart`
- Modify: `chatgpt_app_core/lib/dao/chat/direct_chat_service.dart`
- Modify: `chatgpt_app_core/lib/dao/chat/backend_chat_service.dart`
- Test: `chatgpt_app_core/test/direct_chat_service_test.dart`
- Test: `chatgpt_app_core/test/backend_chat_service_test.dart`
- Modify: `chatgpt_backend/src/chat/dto/completion-body.dto.ts`
- Modify: `chatgpt_backend/src/chat/dto/completion-body.dto.spec.ts`
- Create: `chatgpt_backend/src/chat/stream-deadline-controller.ts`
- Test: `chatgpt_backend/src/chat/stream-deadline-controller.spec.ts`
- Modify: `chatgpt_backend/src/chat/chat.controller.ts`
- Create: `chatgpt_backend/src/chat/chat.controller.spec.ts`
- Modify: `chatgpt_backend/src/chat/chat.service.ts`
- Create: `chatgpt_backend/src/chat/chat.service.spec.ts`

**Interfaces:**

- Consumes: Task 1 `ChatRequestOptions`, Task 2 reasoning adapters, Task 3 abortable SDK.
- Produces a compatibility-preserving method so existing fake `ChatService` classes remain valid:

```dart
abstract class ChatService {
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) {
    return chatStreamEvents(
      prompt: prompt,
      history: history,
      attachments: attachments,
      tools: tools,
      extraMessages: extraMessages,
    );
  }
}
```

- [ ] **Step 1: Write Direct and Backend RED tests**

Direct test asserts `reasoning → text` ordering, provider extra fields, min output token override and external abort forwarding. Backend test asserts request body contains only semantic `request_profile: translation` and `reasoning_policy: off_if_supported`, uses `AbortableRequest`, preserves status/retry-after from HTTP or SSE error, and emits no late token after cancel.

- [ ] **Step 2: Run Flutter transport tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/direct_chat_service_test.dart test/backend_chat_service_test.dart
```

Expected: FAIL because `chatStreamEventsWithOptions` and semantic fields are missing.

- [ ] **Step 3: Implement Direct/Backend overrides**

Pass `providerId` as well as providerCode into `DirectChatService` from `ChatService.from`. Direct resolves `ReasoningControlAdapter` and passes `requestFields` as SDK `extraBody`. Both transports use `max(currentMax, options.minOutputTokens ?? 0)`. Backend uses `http.AbortableRequest(abortTrigger: options.abortTrigger)` and never puts raw deadline milliseconds into the body. When `options.suppressReasoningControl` is true, Backend sends `reasoning_policy: provider_default` even if the stored task policy remains `offIfSupported`.

Map all failures to:

```dart
final class ChatTransportException implements Exception {
  final int? statusCode;
  final Duration? retryAfter;
  final String safeCode;
  final String safeMessage;
}
```

- [ ] **Step 4: Write backend DTO/reasoning/deadline RED tests**

DTO must whitelist only:

```typescript
request_profile?: 'standard' | 'translation';
reasoning_policy?: 'provider_default' | 'off_if_supported';
```

Deadline tests use Jest fake timers: translation first event 45,000 ms; idle reset and fail at 60,000 ms; total fail at 300,000 ms; normal profile keeps the pre-existing 60,000 ms total behavior. Controller tests prove `req.aborted`/`res.close` abort the signal and no error is written to a destroyed response.

- [ ] **Step 5: Implement Nest semantic stripping and lifecycle**

Before upstream fetch:

```typescript
const {
  request_profile = 'standard',
  reasoning_policy = 'provider_default',
  ...openAiBody
} = body;
const upstreamBody = {
  ...openAiBody,
  ...resolveReasoningControl({
    providerCode: provider.code,
    modelId: body.model,
    policy: reasoning_policy,
  }),
  stream: true,
  stream_options: { include_usage: true },
};
```

Controller owns `clientAbort`, listens to both request aborted and response close, passes `clientAbort.signal` to `completeStream`, and removes listeners in `finally`. `StreamDeadlineController` owns first/idle/total timers and aborts the same upstream controller. Server deadline throws `GatewayTimeoutException`; client cancellation exits silently; neither path writes `[DONE]` to a destroyed/ended response.

- [ ] **Step 6: Preserve safe upstream failure metadata**

For upstream 400/401/403/429/5xx, return only `statusCode`, allowlisted `safeCode` and clamped `retryAfterSeconds`. The SSE error payload is:

```json
{"code":"upstream_error","safeCode":"rate_limited","statusCode":429,"retryAfterSeconds":12,"message":"上游请求受限"}
```

Do not forward the upstream error body. Detect explicit Thinking incompatibility on the server and expose `safeCode: unsupported_parameter`.

- [ ] **Step 7: Verify Flutter and Nest GREEN, then commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/direct_chat_service_test.dart test/backend_chat_service_test.dart test/tool_calling_test.dart test/web_search_test.dart test/story_room_tool_runner_test.dart
cd ..
pnpm --filter chatgpt_backend exec jest chat/dto/completion-body.dto.spec.ts chat/stream-deadline-controller.spec.ts chat/chat.controller.spec.ts chat/chat.service.spec.ts --runInBand
pnpm --filter chatgpt_backend run lint
git add chatgpt_app_core/lib/dao/chat/chat_service.dart chatgpt_app_core/lib/dao/chat/direct_chat_service.dart chatgpt_app_core/lib/dao/chat/backend_chat_service.dart chatgpt_app_core/test/direct_chat_service_test.dart chatgpt_app_core/test/backend_chat_service_test.dart chatgpt_backend/src/chat/dto/completion-body.dto.ts chatgpt_backend/src/chat/dto/completion-body.dto.spec.ts chatgpt_backend/src/chat/stream-deadline-controller.ts chatgpt_backend/src/chat/stream-deadline-controller.spec.ts chatgpt_backend/src/chat/chat.controller.ts chatgpt_backend/src/chat/chat.controller.spec.ts chatgpt_backend/src/chat/chat.service.ts chatgpt_backend/src/chat/chat.service.spec.ts
git commit -m "fix(chat): abort stalled translation streams"
```

Expected: all named tests pass; backend lint passes.

---

### Task 5: Translation stream executor and retry decisions

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/translation_stream_executor.dart`
- Create: `chatgpt_app_core/lib/chat/application/translation_retry_policy.dart`
- Test: `chatgpt_app_core/test/translation_stream_executor_test.dart`
- Test: `chatgpt_app_core/test/translation_retry_policy_test.dart`

**Interfaces:**

- Consumes: `ChatService.chatStreamEventsWithOptions` and `TranslationRequestProfile`.
- Produces:

```dart
enum TranslationFailureKind {
  cancelled,
  authentication,
  invalidRequest,
  unsupportedReasoningControl,
  rateLimited,
  server,
  network,
  firstEventTimeout,
  idleTimeout,
  totalTimeout,
  invalidOutput,
}

enum TranslationStreamPhase { waiting, thinking, receiving }

final class TranslationRequestFailure implements Exception {
  final TranslationFailureKind kind;
  final int? statusCode;
  final Duration? retryAfter;
  final String safeCode;
}

abstract interface class TranslationCancellationToken {
  bool get isCancelled;
  Future<void> get whenCancelled;
}

final class TranslationCancellationController
    implements TranslationCancellationToken {
  @override
  bool get isCancelled;
  @override
  Future<void> get whenCancelled;
  void cancel();
}

final class TranslationStreamExecutor {
  TranslationStreamExecutor({
    required ChatService service,
    required TranslationRequestProfile profile,
    Future<void> Function(TranslationRequestProfile profile)?
        onProfileChanged,
    Duration firstEventTimeout = const Duration(seconds: 45),
    Duration idleTimeout = const Duration(seconds: 60),
    Duration totalTimeout = const Duration(minutes: 5),
  });

  Future<String> complete(
    String prompt, {
    required TranslationCancellationToken cancellation,
    void Function(TranslationStreamPhase phase)? onPhase,
  });
}

enum TranslationRetryAction { retry, split, repair, schedule, pause, cancel }

final class TranslationRetryDecision {
  final TranslationRetryAction action;
  final DateTime? nextRunAt;
  final bool suppressReasoningControl;
}

final class TranslationRetryPolicy {
  const TranslationRetryPolicy({Random? random});

  TranslationRetryDecision decide({
    required TranslationRequestFailure failure,
    required int categoryAttempt,
    required int chunkRunes,
    required int minimumSplitRunes,
    required DateTime now,
  });
}

final class TranslationWorkDeferred implements Exception {
  final DateTime nextRunAt;
  final TranslationRequestFailure failure;
}

final class TranslationWorkPaused implements Exception {
  final TranslationRequestFailure failure;
}
```

- [ ] **Step 1: Write stream-state RED tests**

Use a fake `ChatService` and short injected durations. Assert: text fragments concatenate; reasoning/usage reset idle but do not enter output; first-event/idle/total produce distinct failures; cancellation produces `cancelled`; timeout completes abort trigger and cancels the subscription before the Future fails; reasoning-only completion becomes `invalidOutput`; an explicit unsupported Thinking parameter retries exactly once with suppression and awaits `onProfileChanged` before the second request.

```dart
final executor = TranslationStreamExecutor(
  service: fake,
  profile: profile,
  firstEventTimeout: const Duration(milliseconds: 40),
  idleTimeout: const Duration(milliseconds: 50),
  totalTimeout: const Duration(milliseconds: 200),
);
await expectLater(
  executor.complete('prompt', cancellation: token),
  throwsA(isA<TranslationRequestFailure>().having(
    (e) => e.kind,
    'kind',
    TranslationFailureKind.idleTimeout,
  )),
);
expect(fake.abortObserved, isTrue);
expect(fake.activeSubscriptions, 0);
```

- [ ] **Step 2: Implement the single-terminal state machine**

Use one manual `StreamSubscription<StreamEvent>`, one result `Completer<String>` and three timers. Every terminal path calls one idempotent `finish` that cancels timers, completes the request abort trigger, cancels the subscription, detaches task cancellation and completes result/error exactly once. Build request options with `suppressReasoningControl: profile.reasoningControlSuppressed`.

An explicit unsupported-parameter failure is the one transport negotiation handled inside the executor: if the profile requested `offIfSupported` and has not been suppressed, cancel/close the failed stream, replace the profile with `profile.suppressReasoningControl()`, await `onProfileChanged`, and retry exactly once. Other retry/split/schedule behavior stays in the pure policy and pipeline.

- [ ] **Step 3: Write retry-policy RED tests**

Inject `Random` and `now`. Assert: auth/common 400 pause; unsupported reasoning suppresses + retries once; 429 Retry-After clamps to 1/120 seconds and only two attempts; missing Retry-After uses full jitter under 2/4/8… capped at 30; 5xx/network only one attempt under 5 seconds; each timeout returns split; invalid output returns repair once then pause; cancellation never retries.

- [ ] **Step 4: Implement pure decisions without sleeping**

`TranslationRetryPolicy.decide` returns data only. It does not call `Future.delayed`. For a persistent task, `schedule` supplies `nextRunAt`; for an in-memory single-card import, the caller converts `schedule` to a paused user-visible failure.

- [ ] **Step 5: Verify and commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/translation_stream_executor_test.dart test/translation_retry_policy_test.dart
fvm flutter analyze lib/chat/application/translation_stream_executor.dart lib/chat/application/translation_retry_policy.dart
git add lib/chat/application/translation_stream_executor.dart lib/chat/application/translation_retry_policy.dart test/translation_stream_executor_test.dart test/translation_retry_policy_test.dart
git commit -m "feat(story): collect translation streams safely"
```

Expected: all state and retry cases pass with no real minute-long waits.

---

### Task 6: Stable chunk planner and block-level translation checkpoint

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/translation_chunk_planner.dart`
- Test: `chatgpt_app_core/test/translation_chunk_planner_test.dart`
- Modify: `chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart`
- Modify: `chatgpt_app_core/test/assistant_role_card_translation_service_test.dart`
- Modify: `chatgpt_app_core/lib/chat/application/tavern_room_import_preparer.dart`
- Modify: `chatgpt_app_core/test/tavern_room_import_preparer_test.dart`

**Interfaces:**

- Consumes: Task 5 typed failure/retry decision and existing `RoleCardTranslationCall = Future<String?> Function(String prompt)`.
- Produces:

```dart
enum TranslationChunkStatus { pending, completed, retainedOriginal }

final class TranslationChunk {
  final String id;
  final int index;
  final int sourceStartRune;
  final int sourceEndRune;
  final String sourceText;
  final String separatorAfter;
  final String sourceHash;
  final String inputHash;
}

final class TranslationChunkState {
  final TranslationChunk chunk;
  final TranslationChunkStatus status;
  final String translatedText;
  final int attempts;
  final TranslationFailureKind? lastErrorKind;
}

final class TranslationChunkCheckpoint {
  static const currentVersion = 1;
  final String field;
  final String sourceHash;
  final List<TranslationChunkState> chunks;
  bool matchesSource(String field, String source);
  Map<String, dynamic> toJson();
  factory TranslationChunkCheckpoint.fromJson(Map<String, dynamic> json);
}

final class TranslationChunkPlanner {
  TranslationChunkCheckpoint plan({
    required String field,
    required String source,
  });
  TranslationChunkCheckpoint splitTimedOut({
    required TranslationChunkCheckpoint checkpoint,
    required String chunkId,
  });
}
```

- [ ] **Step 1: Write planner RED tests**

Generate a 33,322-rune world book and assert every first-plan chunk is ≤1200, typical chunks approach 900, exact source text + stored separators reconstructs the input, repeated planning gives identical boundaries/ids/hashes, emoji is never split into invalid surrogate halves, other fields are ≤2400, and timeout splitting respects 400/800 minima.

- [ ] **Step 2: Run planner tests and verify RED**

Run `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_chunk_planner_test.dart`.

Expected: FAIL because planner/checkpoint types are missing.

- [ ] **Step 3: Implement deterministic rune splitting**

Hash with SHA-256 over `version + field + rune offsets + sourceText`. Prefer world-book entry boundaries, then paragraph/newline, then sentence punctuation, then whitespace, and only then hard rune cut. Store separators separately and merge translated chunks with the exact original separator; do not unconditionally add newlines.

- [ ] **Step 4: Rewrite the old large-block regression test before service code**

Replace the existing assertion that expects a `>900` probe. The new test must record every actual source chunk and assert:

```dart
expect(sentWorldBookChunks, isNotEmpty);
expect(sentWorldBookChunks.every((text) => text.runes.length <= 1200), isTrue);
expect(_duplicates(sentWorldBookChunks), isEmpty);
expect(translated.memoryBook, expectedOrderedMerge);
```

Add tests for prompt/exampleDialogs chunking, timeout immediate split without same payload retry, one JSON repair, marker count/order preservation, checkpoint callback awaited before the next call, resume skipping completed ids, and source-hash mismatch invalidating old chunks.

- [ ] **Step 5: Integrate planner into the translation service**

Keep the public `RoleCardTranslationCall` shape. Add:

```dart
static Future<AssistantModel> translateToSimplifiedChinese(
  AssistantModel source, {
  required RoleCardTranslationCall complete,
  Map<String, TranslationChunkCheckpoint> initialChunkCheckpoints = const {},
  Future<void> Function(
    String field,
    TranslationChunkCheckpoint checkpoint,
  )? onChunkCheckpoint,
  RoleCardTranslationProgressCallback? onProgress,
  TranslationRetryPolicy retryPolicy = const TranslationRetryPolicy(),
});
```

Every successful chunk must validate JSON/markers, update its state, await `onChunkCheckpoint`, then emit progress. Timeout calls `splitTimedOut` directly. `retainedOriginal` is only set by an explicit upper-layer user action.

- [ ] **Step 6: Forward role-indexed checkpoints through TavernRoomImportPreparer**

Use a stable key `"<roleIndex>:<field>"`. Add `initialChunkCheckpoints` and `onChunkCheckpoint` parameters and verify the correct role index/field is forwarded before advancing to the next role.

- [ ] **Step 7: Verify and commit**

Run:

```bash
fvm flutter test --no-pub test/translation_chunk_planner_test.dart test/assistant_role_card_translation_service_test.dart test/tavern_room_import_preparer_test.dart
fvm flutter analyze lib/chat/application/translation_chunk_planner.dart lib/chat/application/assistant_role_card_translation_service.dart lib/chat/application/tavern_room_import_preparer.dart
git add lib/chat/application/translation_chunk_planner.dart lib/chat/application/assistant_role_card_translation_service.dart lib/chat/application/tavern_room_import_preparer.dart test/translation_chunk_planner_test.dart test/assistant_role_card_translation_service_test.dart test/tavern_room_import_preparer_test.dart
git commit -m "fix(story): checkpoint bounded translation chunks"
```

Expected: no first request exceeds its hard limit; resume tests show no completed chunk is resent.

---

### Task 7: Additive task migration and atomic Tavern finalizer

**Files:**

- Modify: `chatgpt_app_core/lib/model/story_template_translation_task_model.dart`
- Modify: `chatgpt_app_core/lib/db/story_template_translation_task_dao.dart`
- Modify: `chatgpt_app_core/lib/db/story_room_dao.dart`
- Create: `chatgpt_app_core/lib/chat/application/tavern_room_import_finalizer.dart`
- Modify: `chatgpt_app_core/test/story_template_management_test.dart`
- Create: `chatgpt_app_core/test/tavern_room_import_task_test.dart`

**Interfaces:**

- Consumes: Task 1 profile JSON and Task 6 checkpoint JSON.
- Produces exact task constants/fields:

```dart
abstract final class StoryTemplateTranslationTaskKind {
  static const templateCopy = 'templateCopy';
  static const tavernRoomImport = 'tavernRoomImport';
}

abstract final class StoryTemplateTranslationTaskStatus {
  static const needsConfiguration = 'needsConfiguration';
  static const completedWithWarnings = 'completedWithWarnings';
}

class StoryTemplateTranslationTaskModel {
  String taskKind;
  String requestProfile;
  String chunkPayload;
  int? outputRoomId;
  int checkpointVersion;
}
```

- [ ] **Step 1: Write old-schema migration RED tests**

Create a legacy task table without new columns, insert one row, call DAO `create` and assert defaults: `taskKind=templateCopy`, blank request/chunk payload, null room id, checkpointVersion 0. Add full JSON/DAO round-trip and status label/terminal/canRetry cases.

- [ ] **Step 2: Implement guarded columns and backfill**

Add to CREATE and `SchemaGuard.ensureColumns`:

```dart
'taskKind': "text default 'templateCopy'",
'requestProfile': 'text',
'chunkPayload': 'text',
'outputRoomId': 'integer',
'checkpointVersion': 'integer default 0',
```

Backfill null/blank `taskKind` to `templateCopy` and null checkpoint version to 0. Do not rename/remove `fieldPayload` or `partialPayload`. `completedWithWarnings` is terminal; `needsConfiguration` is manual-action-only and must not be auto-claimed.

- [ ] **Step 3: Write atomic finalization RED tests**

Build a two-role Tavern payload. Assert: repeated finalization returns the same template/room ids and database contains one of each; lost lease writes nothing; an injected participant/message insertion failure rolls back template and room; outputRoomId round-trips.

- [ ] **Step 4: Extract a transaction-compatible room insert helper**

Keep `StoryRoomDao.saveTavernImport` public behavior. Move its transaction body into:

```dart
static Future<int> insertTavernImport(
  DatabaseExecutor executor, {
  required StoryRoomModel room,
  required List<StoryParticipantModel> participants,
  required List<StoryMessageModel> messages,
  StoryPersonaModel? persona,
  required int now,
});
```

The outer method opens a transaction and calls this helper; task DAO can call the helper inside its own transaction without nesting.

- [ ] **Step 5: Build a pure finalization bundle and task DAO method**

`TavernRoomImportFinalizer.build` returns `StoryTemplateModel outputTemplate` plus room/participants/messages created from the translated `StoryRoomTemplatePayload`. DAO exposes:

```dart
final class TavernRoomImportBundle {
  final StoryTemplateModel outputTemplate;
  final StoryRoomModel room;
  final List<StoryParticipantModel> participants;
  final List<StoryMessageModel> messages;
}

final class TavernRoomImportCompletion {
  final int outputTemplateId;
  final int outputRoomId;
}

abstract final class TavernRoomImportFinalizer {
  static TavernRoomImportBundle build({
    required StoryRoomTemplatePayload payload,
    required String title,
    required String sourceTitle,
    required bool translated,
  });
}

Future<TavernRoomImportCompletion?> completeWithTavernRoom(
  StoryTemplateTranslationTaskModel task, {
  required TavernRoomImportBundle bundle,
  required String leaseOwner,
  DateTime? now,
});
```

Within one SQLite transaction: verify task kind/status/lease, reuse or insert output template, reuse outputRoomId if already completed, insert room graph, update both ids/status, clear lease/nextRunAt. `completedWithWarnings` is preserved when the bundle contains retained-original chunks.

- [ ] **Step 6: Verify and commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/story_template_management_test.dart test/tavern_room_import_task_test.dart
fvm flutter analyze lib/model/story_template_translation_task_model.dart lib/db/story_template_translation_task_dao.dart lib/db/story_room_dao.dart lib/chat/application/tavern_room_import_finalizer.dart
git add lib/model/story_template_translation_task_model.dart lib/db/story_template_translation_task_dao.dart lib/db/story_room_dao.dart lib/chat/application/tavern_room_import_finalizer.dart test/story_template_management_test.dart test/tavern_room_import_task_test.dart
git commit -m "feat(story): persist tavern translation outputs"
```

Expected: old rows migrate; atomicity/idempotency tests pass.

---

### Task 8: Persistent runner, block resume, model replacement and lease cancellation

**Files:**

- Modify: `chatgpt_app_core/lib/chat/application/story_template_translation_tasks.dart`
- Modify: `chatgpt_app_core/test/story_template_management_test.dart`
- Modify: `chatgpt_app_core/test/tavern_room_import_task_test.dart`
- Modify: `chatgpt_app_core/lib/chat/application/story_template_background_worker.dart`
- Modify: `chatgpt_app_core/lib/app.dart`

**Interfaces:**

- Consumes: strict profile resolver, stream executor, checkpoint service, task DAO/finalizer.
- Produces:

```dart
typedef TranslationExecutorResolver = TranslationStreamExecutor Function(
  TranslationRequestProfile profile,
);

Future<void> start(
  StoryTemplateModel template, {
  required TranslationRequestProfile requestProfile,
  required TranslationExecutorResolver resolveExecutor,
});

Future<void> startTavernRoomImport(
  List<AssistantRoleCardImportResult> results, {
  required String sourceTitle,
  required TranslationRequestProfile requestProfile,
  required TranslationExecutorResolver resolveExecutor,
});

Future<void> retry(
  StoryTemplateTranslationTaskModel task, {
  TranslationRequestProfile? replacementProfile,
  required TranslationExecutorResolver resolveExecutor,
});

Future<void> completeKeepingOriginalChunks(
  StoryTemplateTranslationTaskModel task,
);
```

- [ ] **Step 1: Write runner RED tests**

Cover: task creation stores concrete profile and kind; executor resolution uses stored profile after global settings change; chunk N checkpoint survives interruption and resume starts at N+1; timeout splits without duplicate payload; 429 writes nextRunAt/releases lease; disabled/deleted model sets `needsConfiguration`; replacement profile preserves completed chunks; explicit Thinking fallback persists the suppressed profile before its second request; lease loss/task cancel completes executor cancellation; retain-original finalizes with warnings.

- [ ] **Step 2: Change coordinator ownership from call closure to resolver**

Remove long-lived `StoryTemplateTranslationCall complete` from coordinator APIs. On claim, decode `task.requestProfile`, resolve a fresh executor from the current account settings, and pass `executor.complete` into the role-card service. A missing legacy profile is snapshotted once from current settings, persisted, then reused.

- [ ] **Step 3: Persist each chunk before UI progress**

Encode current checkpoint to `chunkPayload` with checkpointVersion 1 and use `saveClaimedTask`. At field completion, save `fieldPayload` then clear `chunkPayload`. At role completion, save `partialPayload` and clear field/chunk payloads. A source hash mismatch discards only the stale current-field checkpoint.

- [ ] **Step 4: Implement retry/pause/partial-completion transitions**

`schedule` writes `retryable + nextRunAt` and releases lease; `pause` uses existing terminal-but-retryable `failed` status with stage “已暂停，可重试”, preserving checkpoints without automatic claim; invalid model becomes `needsConfiguration`; cancel remains terminal; retained originals set `completedWithWarnings`. Never log error body or source text.

- [ ] **Step 5: Make background/app restore task-driven**

`app.dart` and `story_template_background_worker.dart` load current secure `AISettings` only to build a `TranslationExecutorResolver`. They must not create one `ChatService` from the current global model and reuse it for all tasks. Existing scheduler task names remain unchanged. Auto-resume only considers queued or due `retryable` rows; `failed` and `needsConfiguration` do not keep WorkManager reporting retry forever.

- [ ] **Step 6: Verify and commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/story_template_management_test.dart test/tavern_room_import_task_test.dart
fvm flutter analyze lib/chat/application/story_template_translation_tasks.dart lib/chat/application/story_template_background_worker.dart lib/app.dart
git add lib/chat/application/story_template_translation_tasks.dart lib/chat/application/story_template_background_worker.dart lib/app.dart test/story_template_management_test.dart test/tavern_room_import_task_test.dart
git commit -m "feat(story): resume translation from chunk checkpoints"
```

Expected: restart/retry never resends a completed chunk and model snapshots survive global changes.

---

### Task 9: Shared configured-model picker and translation settings dialog

**Files:**

- Create: `chatgpt_app_core/lib/widget/configured_ai_model_picker_sheet.dart`
- Create: `chatgpt_app_core/lib/widget/translation_settings_dialog.dart`
- Modify: `chatgpt_app_core/lib/pages/conversation_page.dart`
- Test: `chatgpt_app_core/test/configured_ai_model_picker_sheet_test.dart`
- Test: `chatgpt_app_core/test/translation_settings_dialog_test.dart`
- Modify: `chatgpt_app_core/test/model_picker_presenter_test.dart`

**Interfaces:**

- Consumes: `ConversationModelPickerPresenter`, `TranslationModelPreferenceStore`, `ReasoningControlAdapter`.
- Produces:

```dart
Future<TranslationModelPreference?> showConfiguredAiModelPickerSheet(
  BuildContext context, {
  required AISettings settings,
  required TranslationModelPreference selected,
  bool includeFollowGlobal = true,
});

Future<TranslationModelPreference?> showTranslationSettingsDialog(
  BuildContext context, {
  required AISettings settings,
  required TranslationModelPreference initialValue,
  required int estimatedRunes,
  String title = '翻译设置',
});
```

- [ ] **Step 1: Write picker widget RED tests**

Assert: follow-global always visible; local rows only include enabled providers with non-empty Key/model; backend row uses current backend model; search/filter/status/last-used sorting comes from `ConversationModelPickerPresenter`; failed health models remain visible with badge; selecting returns exact provider/model and does not mutate `AISettings`.

- [ ] **Step 2: Extract the existing conversation picker UI**

Move reusable row/search/chips/status rendering out of private `ConversationPage` methods. Rewire the conversation page to the shared sheet first and keep existing model-selection behavior unchanged. Do not create a second presentation algorithm.

- [ ] **Step 3: Write settings-dialog RED tests**

Assert: remembered selection is initial; invalid remembered selection falls back to follow-global; rune estimate appears; Thinking switch defaults on; unsupported models disable it with “该接口不会发送 Thinking 参数”；cancel returns null; confirm returns preference only.

- [ ] **Step 4: Implement the dialog**

Use `ReasoningControlAdapter.resolve` only for explanation/support display. The dialog never snapshots or persists itself. Caller performs `TranslationModelResolver.snapshot`, creates the task, and only after creation succeeds saves preference for the account.

- [ ] **Step 5: Verify and commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/model_picker_presenter_test.dart test/configured_ai_model_picker_sheet_test.dart test/translation_settings_dialog_test.dart
fvm flutter analyze lib/widget/configured_ai_model_picker_sheet.dart lib/widget/translation_settings_dialog.dart lib/pages/conversation_page.dart
git add lib/widget/configured_ai_model_picker_sheet.dart lib/widget/translation_settings_dialog.dart lib/pages/conversation_page.dart test/model_picker_presenter_test.dart test/configured_ai_model_picker_sheet_test.dart test/translation_settings_dialog_test.dart
git commit -m "feat(ai): choose a model for each translation"
```

Expected: conversation selection remains compatible and translation dialog tests pass.

---

### Task 10: Wire real import entry points and recovery actions

**Files:**

- Modify: `chatgpt_app_core/lib/pages/assistant_list_page.dart`
- Modify: `chatgpt_app_core/lib/pages/story_room_list_page.dart`
- Create: `chatgpt_app_core/test/assistant_list_page_test.dart`
- Modify: `chatgpt_app_core/test/story_template_management_test.dart`
- Modify: `chatgpt_app_core/lib/backup/backup_service.dart`
- Modify: `chatgpt_app_core/test/backup_test.dart`
- Modify: `chatgpt_app_core/lib/sync/local_sync_service.dart`
- Modify: `chatgpt_app_core/test/local_sync_service_test.dart`

**Interfaces:**

- Consumes: Task 8 coordinator APIs and Task 9 dialog.
- Produces all user-visible flows from the approved design.

- [ ] **Step 1: Write entry-flow RED tests**

Cover both pages: choosing translate opens settings; selecting model creates a concrete task profile; preference saves only after task row exists; global settings remain unchanged; canceling settings creates no task. For ordinary single-card import, fake typed SSE reasoning+text returns only text. For Tavern room import, the page creates `tavernRoomImport` and no private in-memory room job.

- [ ] **Step 2: Replace assistant-list translation wiring**

Upgrade `_RoleCardImportOptions` and `_TavernRoomImportOptions` from a translation bool-only contract to carry a concrete `TranslationRequestProfile?`. Delete `_RoleCardImportCoordinator.startTavernRoom` and `_runTavernRoom`. Translated Tavern branches call persistent `startTavernRoomImport`; un-translated room creation may stay immediate. `_translateImportedRoleCard` uses `TranslationStreamExecutor` and Task 6 chunk strategy without persistence.

- [ ] **Step 3: Replace story-template copy wiring**

`_translateTemplateAsSimplifiedCopy` opens the settings dialog, snapshots the chosen model, calls coordinator `start` and saves preference after success. Retry uses stored profile. Add actions:

```text
继续使用原模型
更换模型后继续
保留失败块原文并完成
取消任务
```

Filter page task lists by `taskKind` so template-copy cards and assistant Tavern-import cards appear on their relevant surfaces.

- [ ] **Step 4: Make progress/logging truthful and private**

Progress uses completed source runes / total source runes. Display provider/model id, role, field, chunk, source char count, first-event/total duration and safe failure kind. Never interpolate prompt/source/translation/Key/full URL/upstream body into logs. A failed or retained-original chunk cannot emit “字段已翻译”.

- [ ] **Step 5: Add backup ID remap and local-only sync policy tests**

Backup merge must remap `templateId`, `outputTemplateId` and `outputRoomId` after room/template maps are known. Translation task execution rows are local-only in `LocalSyncService`: exclude them from outbound payload and ignore remote upserts, preventing two devices from spending tokens for one task. Add round-trip tests proving requestProfile contains no secrets.

- [ ] **Step 6: Implement backup/sync rules**

Move or second-pass translation task restore after both template and room id maps exist. Keep old `templateCopy` rows restorable. Add an explicit task-table exclusion alongside other local execution metadata in sync code; do not exclude actual completed templates/rooms.

- [ ] **Step 7: Verify and commit**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/story_template_management_test.dart test/backup_test.dart test/local_sync_service_test.dart test/assistant_list_page_test.dart
fvm flutter analyze lib/pages/assistant_list_page.dart lib/pages/story_room_list_page.dart lib/backup/backup_service.dart lib/sync/local_sync_service.dart
git add lib/pages/assistant_list_page.dart lib/pages/story_room_list_page.dart lib/backup/backup_service.dart lib/sync/local_sync_service.dart test/story_template_management_test.dart test/backup_test.dart test/local_sync_service_test.dart test/assistant_list_page_test.dart
git commit -m "feat(story): persist reliable tavern translations"
```

Expected: actual user-log entry point is persistent and every recovery action has a tested state transition.

---

### Task 11: End-to-end reliability gate and platform verification

**Files:**

- Create: `chatgpt_app_core/test/translation_reliability_integration_test.dart`
- Modify: `docs/superpowers/specs/2026-07-16-streaming-translation-reliability-design.md` status only after all gates pass.

**Interfaces:**

- Consumes every prior task.
- Produces the release evidence for all ten acceptance criteria.

- [ ] **Step 1: Write a 30K+ fake-SSE integration test**

Generate at least 33,322 runes of world-book content. Fake SSE emits reasoning and text with controllable activity. Interrupt after a middle chunk checkpoint, reconstruct coordinator/DAO, resume, and assert:

```dart
expect(maxRequestedRunes, lessThanOrEqualTo(1200));
expect(requestedChunkIds.length, requestedChunkIds.toSet().length);
expect(resumedChunkIds.any(completedBeforeRestart.contains), isFalse);
expect(result.memoryBook, expectedWorldBook);
expect(globalSettings.toJson(), originalGlobalJson);
expect(savedTask.outputRoomId, isNotNull);
```

- [ ] **Step 2: Add cancellation-overlap assertions**

Hold the first request open, trigger idle timeout, and only allow the next split request to start after the fake server reports the first socket closed. Assert peak active upstream requests is 1. Repeat for user cancel and lease loss.

- [ ] **Step 3: Run focused package/backend suites**

Run:

```bash
cd openai_flutter
fvm flutter test
fvm flutter analyze
cd ../chatgpt_app_core
fvm flutter test --no-pub test/translation_reliability_integration_test.dart test/translation_chunk_planner_test.dart test/translation_stream_executor_test.dart test/assistant_role_card_translation_service_test.dart test/story_template_management_test.dart test/tavern_room_import_task_test.dart
fvm flutter analyze
cd ..
pnpm --filter chatgpt_backend test -- --runInBand
pnpm --filter chatgpt_backend run lint
```

Expected: every command exits 0.

- [ ] **Step 4: Run full Flutter shell regression**

Run:

```bash
cd chatgpt_flutter
fvm flutter pub get
fvm flutter test
fvm flutter analyze
```

Expected: pub resolution, tests and analyze all exit 0.

- [ ] **Step 5: Exercise iOS simulator behavior**

Launch the already configured iOS simulator without uninstalling its app data:

```bash
cd chatgpt_flutter
fvm flutter devices
open -a Simulator
fvm flutter run
```

Choose the already-booted iOS simulator if Flutter prompts for a device. Manually verify: model dialog appears; global chat model is unchanged; a long world book shows continuously advancing chunk progress; cancel stops network activity; background/relaunch resumes after the last successful chunk; retained-original result is visibly marked partial. Record any simulator-only limitation instead of deleting/reinstalling the app.

- [ ] **Step 6: Update status, inspect diff and commit the gate**

Set the design status to `已实现并通过自动化验证，等待用户手动验收`. Then run:

```bash
git diff --check
git status --short
git diff --stat HEAD
git add chatgpt_app_core/test/translation_reliability_integration_test.dart
git add -f docs/superpowers/specs/2026-07-16-streaming-translation-reliability-design.md
git commit -m "test(story): gate streaming translation reliability"
```

Expected: no whitespace errors; only intended files are staged; commit succeeds.

---

## Acceptance Trace

1. No repeated 2200-rune probe: Tasks 6 and 11.
2. Every source request respects hard limits: Tasks 6 and 11.
3. Active SSE may exceed 120 seconds; 60-second stall cancels: Tasks 4, 5 and 11.
4. No old/new attempt overlap: Tasks 3–5 and 11.
5. Restart skips successful chunks: Tasks 6–8 and 11.
6. Selected model survives foreground/background/restart while global stays unchanged: Tasks 1, 8–10.
7. Supported Thinking is off; unsupported endpoints receive no guessed field: Tasks 2, 4 and 5.
8. Retained original is not reported as full success: Tasks 7, 8 and 10.
9. Guarded migration keeps old tasks/config readable: Task 7.
10. Unit/DAO/widget/transport/analyze gates pass: Tasks 1–11.

## Execution Notes

- Execute tasks in order; later interfaces intentionally depend on exact names defined earlier.
- Each task gets a fresh RED observation, focused GREEN run, code review, then its own commit.
- Preserve unrelated untracked `.superpowers/` and `login_sdk/test/support/` files.
- Because `/docs/` is ignored, documentation commits use an explicit forced add only for the exact new plan/spec path when needed; never force-add the whole docs tree.
