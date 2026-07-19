# 翻译适配加固 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为酒馆房间、角色卡和酒馆模板翻译增加零隐式请求的模型资格检查、用户显式流式预检，以及按实际正文 rune 计权且可恢复的进度。

**Architecture:** 本地 `TranslationModelEligibilityEvaluator` 先基于账号、模式、有效端点和发行环境做确定性判定；只有用户点击按钮后，`TranslationModelProbeService` 才复用正式 `TranslationStreamExecutor` 发送固定小请求并把脱敏结果缓存到账号级 HiCache。翻译字段合同由单一 `RoleCardTranslationFields` 提供，`TranslationWorkEstimator` 使用同一 translation view 计算总量与 checkpoint 已解决量，runner 再用锚点映射把 rune 比例投射到 4%–94% 并保持旧任务单调兼容。

**Tech Stack:** Flutter/Dart, Provider, flutter_test, HiCache/SharedPreferences, package:http, typed SSE `StreamEvent`, crypto SHA-256, sqflite task checkpoints, FVM

## Global Constraints

- 模型预检永不自动运行；打开页面、切换模型、读取或过期缓存、创建/恢复任务都不得触发预检网络请求。
- 每次预检前明确说明会发送一次无用户数据的小请求并可能产生少量 Token；自动化测试只使用 fake/local SSE，不调用真实服务商。
- 资格检查必须是纯本地逻辑，并在选择器、任务创建、重试、App 启动恢复和后台恢复边界重复执行。
- 游客使用后端代理为 hard block；Android/iOS loopback 为 warning；Android store 的本地直连 `http://` 为 hard block；`10.0.2.2` 不视为 loopback 错误。
- 未验证、网络/限流/超时预检失败仍可在确认后继续；本地配置缺失和平台确定性限制不可继续。
- 预检缓存 key 固定为 `translation_model_probe_v1_<accountHash>`，TTL 固定七天，每账号最多 50 条。
- 缓存、任务、日志不得保存 API Key、Authorization、boarding pass、原始自定义 endpoint、预检 prompt 或响应正文；fingerprint 只落 SHA-256。
- fingerprint 输入包含执行模式、provider id/code、model id、有效 endpoint、reasoning policy、Thinking 适配器版本和预检协议版本；API Key 不参与 hash，Key 变化由设置持久化边界显式失效。
- 预检输出上限必须精确为 128 tokens；普通翻译继续保持至少 2048 output tokens，不改变用户聊天 token 配置。
- 预检发现 Thinking 参数不兼容、完成协商并实际发出无参数重试后，缓存 `reasoningControlSuppressed=true`；该兼容性证据独立于重试最终成功或失败，用该模型创建或换模型继续时必须把证据应用到任务 profile，避免正式任务再次发送已知不兼容参数。
- 正文工作量使用 Dart Unicode rune；统计六个实际翻译字段及可选模板开场，raw Tavern `memoryBook` 只统计 translation view；JSON 包装、Base64 marker 和不可变元数据不计入。
- chunk 完成量同时统计 `sourceText` 与 `separatorAfter`；`completed` 和 `retainedOriginal` 计为 resolved，`pending`、重试和细分不计。
- 新任务翻译阶段映射为 4%–94%，保存为 96%，终态为 100%；旧任务用启动锚点重映射剩余工作，任何恢复、细分或换模型都不得倒退。
- 不修改任务表或 checkpoint JSON 版本；旧任务无法重算时继续使用现有字段等权公式。
- 不改变 45 秒首事件、60 秒 idle、5 分钟总时长、分块阈值、串行策略、重试次数和退避策略。
- 不按预检延迟自动选最快模型，不自动遍历已配置模型，不上传延迟分析，也不自动切换模型或重复预检扣费。
- 不新增自适应超时、系统通知或 OHOS 后台调度器；不为未知兼容端点猜测新的 Thinking 参数。
- 不新增插件或平台依赖；保持 Android、iOS、macOS、Windows 和 OHOS shared-core 编译兼容。

---

## File and Responsibility Map

### Eligibility and execution guard

- Create `chatgpt_app_core/lib/chat/application/translation_model_eligibility.dart` — 环境快照、稳定 issue code、preference/profile 纯本地判定。
- Modify `chatgpt_app_core/lib/chat/application/translation_model_resolver.dart` — 为不可用异常增加稳定 safe code。
- Modify `chatgpt_app_core/lib/chat/application/story_template_translation_tasks.dart` — 创建/重试/恢复的二次资格检查与 `needsConfiguration` 原因保留。
- Modify `chatgpt_app_core/lib/app.dart`, `story_template_background_worker.dart`, `pages/story_room_list_page.dart`, `pages/assistant_list_page.dart` — 注入当前 eligibility environment/checker。

### Body work and progress

- Create `chatgpt_app_core/lib/chat/application/role_card_translation_fields.dart` — 六个字段、标签、实际 source 和 raw memoryBook restore 的唯一合同。
- Create `chatgpt_app_core/lib/chat/application/translation_work_estimator.dart` — assistant/room/task 总量、checkpoint resolved 量、锚点映射和格式化。
- Modify `assistant_role_card_translation_service.dart` and `tavern_room_import_preparer.dart` — 使用统一字段合同，并在进度事件携带可空 rune pair。
- Modify `story_template_translation_tasks.dart` — 从 source/partial/field/chunk checkpoint 重算并持久化单调进度与 rune 详情。
- Modify `story_room_list_page.dart` and `assistant_list_page.dart` — 正文估算、内存任务 rune 进度和恢复模型弹窗。

### Probe cache and transport

- Create `chatgpt_app_core/lib/chat/application/translation_model_probe_cache.dart` — strict record JSON、账号隔离、TTL、50 条、provider 索引与串行写回滚。
- Create `chatgpt_app_core/lib/chat/application/translation_model_probe_fingerprint.dart` — 只落 hash 的 canonical identity 和配置失效集合。
- Create `chatgpt_app_core/lib/chat/application/translation_model_probe_service.dart` — explicit-only single-flight handle、固定 prompt、正式流式解析、错误映射和 cached suppression 应用。
- Modify `reasoning_control_adapter.dart` — 增加 `policyVersion = 1`。
- Modify `chat_request_options.dart`, `translation_stream_executor.dart`, `direct_chat_service.dart`, `backend_chat_service.dart` — 精确 output token override 与首个 typed event 回调。
- Modify `ai_settings_dao.dart` — 在权威 save/clear 边界失效对应账号/provider 的 probe 记录。
- Create `chatgpt_app_core/test/support/fake_translation_chat_service.dart` — executor/probe 共用的 typed SSE fake。

### Probe UI

- Modify `translation_settings_dialog.dart` — eligibility、显式费用确认、运行/取消、状态摘要、warning 二次确认和 fix action。
- Modify `configured_ai_model_picker_sheet.dart` — 每行只读 eligibility/probe badge；展示而不自动测试不可用模型。
- Modify `story_room_list_page.dart` and `assistant_list_page.dart` — 传入 account/environment/service，接收已应用 cached suppression 的具体 profile。

---

### Task 1: Pure translation-model eligibility

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/translation_model_eligibility.dart`
- Modify: `chatgpt_app_core/lib/chat/application/translation_model_resolver.dart`
- Test: `chatgpt_app_core/test/translation_model_eligibility_test.dart`
- Test: `chatgpt_app_core/test/translation_request_profile_test.dart`

**Interfaces:**

- Consumes: `TranslationModelResolver.snapshot/apply`, `AISettings.activeLocal`, `BackendConfig.host/useHttps`, `DistributionConfig.current`, `TargetPlatform`.
- Produces:

```dart
enum TranslationEligibilityLevel { allowed, warning, blocked }

enum TranslationEligibilityCode {
  providerMissing,
  providerDisabled,
  modelMissing,
  apiKeyMissing,
  invalidEndpoint,
  guestBackend,
  mobileLoopback,
  androidStoreCleartext,
  configurationChanged,
}

final class TranslationEligibilityEnvironment {
  final bool isGuest;
  final TargetPlatform platform;
  final AppDistribution distribution;
  final String backendHost;
  final bool backendUseHttps;

  const TranslationEligibilityEnvironment({
    required this.isGuest,
    required this.platform,
    required this.distribution,
    required this.backendHost,
    required this.backendUseHttps,
  });

  factory TranslationEligibilityEnvironment.current();
}

final class TranslationEligibilityIssue {
  final TranslationEligibilityLevel level;
  final TranslationEligibilityCode code;
  final String message;
  final String? actionLabel;

  const TranslationEligibilityIssue({
    required this.level,
    required this.code,
    required this.message,
    this.actionLabel,
  });
}

final class TranslationEligibilityResult {
  final List<TranslationEligibilityIssue> issues;

  const TranslationEligibilityResult([this.issues = const []]);

  TranslationEligibilityLevel get level;
  bool get canStart;
  TranslationEligibilityIssue? get primaryIssue;
}

final class TranslationModelEligibilityEvaluator {
  const TranslationModelEligibilityEvaluator();

  TranslationEligibilityResult evaluatePreference({
    required AISettings settings,
    required TranslationModelPreference preference,
    required TranslationEligibilityEnvironment environment,
  });

  TranslationEligibilityResult evaluateProfile({
    required AISettings settings,
    required TranslationRequestProfile profile,
    required TranslationEligibilityEnvironment environment,
  });
}
```

- [ ] **Step 1: Write the failing eligibility matrix tests**

Create table-driven tests covering: guest/backend blocked, guest/local allowed, missing/deleted/disabled provider blocked, empty Key/model/endpoint blocked, relative/unsupported-scheme/empty-host/user-info endpoint blocked, Android and iOS `localhost|127.0.0.1|::1` warning, desktop loopback allowed, `10.0.2.2` allowed, Android store HTTP blocked, direct/development HTTP allowed, HTTPS allowed, and blocked taking priority over warning.

```dart
test('guest backend is blocked before transport creation', () {
  final result = const TranslationModelEligibilityEvaluator()
      .evaluatePreference(
    settings: backendSettings('deepseek-chat'),
    preference: const TranslationModelPreference(
      mode: TranslationModelPreferenceMode.backend,
      modelId: 'deepseek-chat',
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    ),
    environment: const TranslationEligibilityEnvironment(
      isGuest: true,
      platform: TargetPlatform.iOS,
      distribution: AppDistribution.development,
      backendHost: 'localhost:3000',
      backendUseHttps: false,
    ),
  );

  expect(result.canStart, isFalse);
  expect(result.primaryIssue?.code, TranslationEligibilityCode.guestBackend);
});
```

- [ ] **Step 2: Run the new test and verify RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_model_eligibility_test.dart`

Expected: FAIL because `translation_model_eligibility.dart` and its types do not exist.

- [ ] **Step 3: Implement the environment, result ordering and evaluator**

Use `Uri.tryParse` plus `uri.hasScheme`, `uri.host`, `uri.userInfo` and `http|https`; never search the raw URL string. A relative URI, empty host, unsupported scheme or non-empty user-info is `invalidEndpoint`. Treat only mobile `localhost`, `127.0.0.1` and `::1` as loopback warning. `canStart` is true for allowed/warning and false only for blocked; `primaryIssue` is the first issue at the highest severity, preserving evaluator insertion order within that severity. Catch `TranslationModelUnavailableException` and map its new stable code instead of parsing localized message text.

```dart
TranslationEligibilityLevel _highest(
  Iterable<TranslationEligibilityIssue> issues,
) {
  if (issues.any((issue) => issue.level == TranslationEligibilityLevel.blocked)) {
    return TranslationEligibilityLevel.blocked;
  }
  if (issues.any((issue) => issue.level == TranslationEligibilityLevel.warning)) {
    return TranslationEligibilityLevel.warning;
  }
  return TranslationEligibilityLevel.allowed;
}
```

Extend the existing exception without changing its current `toString()` shape:

```dart
final class TranslationModelUnavailableException implements Exception {
  final String safeCode;
  final String message;

  const TranslationModelUnavailableException(
    this.message, {
    this.safeCode = 'model_unavailable',
  });
}
```

Update every resolver throw site with one of the literal stable codes `providerMissing`, `providerDisabled`, `apiKeyMissing` or `modelMissing`; both an empty and a removed model use `modelMissing`, and both an empty and a deleted provider use `providerMissing`. The evaluator switches on those exact codes and never imports the eligibility enum back into the resolver, avoiding a circular dependency.

- [ ] **Step 4: Run eligibility and resolver tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_model_eligibility_test.dart test/translation_request_profile_test.dart`

Expected: PASS; no network request is constructed by these tests.

- [ ] **Step 5: Commit the pure eligibility slice**

```bash
git add chatgpt_app_core/lib/chat/application/translation_model_eligibility.dart \
  chatgpt_app_core/lib/chat/application/translation_model_resolver.dart \
  chatgpt_app_core/test/translation_model_eligibility_test.dart \
  chatgpt_app_core/test/translation_request_profile_test.dart
git commit -m "feat(story): validate translation model eligibility"
```

---

### Task 2: Enforce eligibility at task lifecycle boundaries

**Files:**

- Modify: `chatgpt_app_core/lib/chat/application/story_template_translation_tasks.dart`
- Modify: `chatgpt_app_core/lib/app.dart`
- Modify: `chatgpt_app_core/lib/chat/application/story_template_background_worker.dart`
- Modify: `chatgpt_app_core/lib/pages/story_room_list_page.dart`
- Modify: `chatgpt_app_core/lib/pages/assistant_list_page.dart`
- Test: `chatgpt_app_core/test/story_template_management_test.dart`
- Test: `chatgpt_app_core/test/tavern_room_import_task_test.dart`
- Test: `chatgpt_app_core/test/backup_translation_task_lifecycle_test.dart`
- Test: `chatgpt_app_core/test/story_template_background_scheduler_test.dart`

**Interfaces:**

- Consumes: Task 1 `TranslationModelEligibilityEvaluator.evaluateProfile`.
- Produces:

```dart
typedef TranslationProfileEligibilityCheck = TranslationEligibilityResult
    Function(TranslationRequestProfile profile);

Future<void> start(
  StoryTemplateModel template, {
  required TranslationRequestProfile requestProfile,
  required TranslationProfileEligibilityCheck checkEligibility,
  required TranslationExecutorResolver resolveExecutor,
});

Future<int> resumeRecoverable({
  required TranslationProfileEligibilityCheck checkEligibility,
  TranslationExecutorResolver? resolveExecutor,
  StoryTemplateTranslationCall? complete,
  TranslationRequestProfile? legacyRequestProfile,
  LegacyTranslationRequestProfileResolver? resolveLegacyRequestProfile,
});
```

`startTavernRoomImport` and `retry` receive the same required `checkEligibility` parameter.

- [ ] **Step 1: Write failing lifecycle guard tests**

Add tests proving: blocked new task throws before `saveTask`; blocked replacement-profile retry throws before mutating the existing task; blocked queued/resumed task becomes `needsConfiguration`; `task.error` keeps the stable eligibility code; warning continues; `fieldPayload`, `chunkPayload` and `partialPayload` remain byte-identical after a blocked resume.

```dart
TranslationEligibilityResult _blockedGuestBackend(
  TranslationRequestProfile _,
) => TranslationEligibilityResult([
  const TranslationEligibilityIssue(
    level: TranslationEligibilityLevel.blocked,
    code: TranslationEligibilityCode.guestBackend,
    message: '后端代理需要登录',
    actionLabel: '去登录',
  ),
]);
```

- [ ] **Step 2: Run focused lifecycle tests RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/story_template_management_test.dart test/tavern_room_import_task_test.dart test/backup_translation_task_lifecycle_test.dart`

Expected: FAIL because coordinator entry points do not require or enforce the checker.

- [ ] **Step 3: Guard new-task creation and claimed-task execution**

Before saving a new row or applying a replacement profile in `retry`, reject `!result.canStart` without mutating a task. After decoding a claimed task profile and before `resolveExecutor`, evaluate again. A blocked claimed task must call the existing `_markNeedsConfiguration` path with `primaryIssue.code.name`; warnings continue without state mutation.

```dart
void _requireEligible(
  TranslationRequestProfile profile,
  TranslationProfileEligibilityCheck checkEligibility,
) {
  final result = checkEligibility(profile);
  if (result.canStart) return;
  final issue = result.primaryIssue!;
  throw TranslationModelUnavailableException(
    issue.message,
    safeCode: issue.code.name,
  );
}
```

- [ ] **Step 4: Wire the same environment into UI, login resume and background**

At each production boundary, capture settings plus current environment immediately before the coordinator `start`, `startTavernRoomImport`, `retry` or `resumeRecoverable` call, then build this closure. Do not reuse the settings/environment snapshot from when the dialog was first opened:

```dart
final environment = TranslationEligibilityEnvironment.current();
const evaluator = TranslationModelEligibilityEvaluator();
final checkEligibility = (TranslationRequestProfile profile) =>
    evaluator.evaluateProfile(
      settings: settings,
      profile: profile,
      environment: environment,
    );
```

Pass it from `StoryRoomListPage`, `AssistantListPage`, `MyApp._resumeStoryTemplateTranslations` and `runStoryTemplateTranslationBackgroundWork`. Do not call the probe service in any of these paths.

- [ ] **Step 5: Update test callers with an explicit allow checker**

Use one test helper instead of optional production defaults:

```dart
TranslationEligibilityResult _allowTranslationProfile(
  TranslationRequestProfile _,
) => const TranslationEligibilityResult([]);
```

Pass `checkEligibility: _allowTranslationProfile` at every existing coordinator start/retry/resume call in the four listed test files.

- [ ] **Step 6: Run lifecycle/background tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/story_template_management_test.dart test/tavern_room_import_task_test.dart test/backup_translation_task_lifecycle_test.dart test/story_template_background_scheduler_test.dart`

Expected: PASS; blocked tasks preserve checkpoints and no fake executor request is observed.

- [ ] **Step 7: Commit lifecycle enforcement**

```bash
git add chatgpt_app_core/lib/chat/application/story_template_translation_tasks.dart \
  chatgpt_app_core/lib/app.dart \
  chatgpt_app_core/lib/chat/application/story_template_background_worker.dart \
  chatgpt_app_core/lib/pages/story_room_list_page.dart \
  chatgpt_app_core/lib/pages/assistant_list_page.dart \
  chatgpt_app_core/test/story_template_management_test.dart \
  chatgpt_app_core/test/tavern_room_import_task_test.dart \
  chatgpt_app_core/test/backup_translation_task_lifecycle_test.dart \
  chatgpt_app_core/test/story_template_background_scheduler_test.dart
git commit -m "feat(story): enforce translation eligibility"
```

---

### Task 3: Single source of truth for translation body work

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/role_card_translation_fields.dart`
- Create: `chatgpt_app_core/lib/chat/application/translation_work_estimator.dart`
- Modify: `chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart`
- Test: `chatgpt_app_core/test/translation_work_estimator_test.dart`
- Test: `chatgpt_app_core/test/assistant_role_card_translation_service_test.dart`

**Interfaces:**

- Consumes: `AssistantRoleCardService.memoryBookTranslationView`, `TranslationChunkPlanner`, `TranslationChunkCheckpoint`.
- Produces:

```dart
final class RoleCardTranslationField {
  final String id;
  final String label;
  final String source;
  final String Function(String translated) restore;
}

abstract final class RoleCardTranslationFields {
  static const ids = <String>[
    'name',
    'description',
    'prompt',
    'openingMessage',
    'exampleDialogs',
    'memoryBook',
  ];

  static List<RoleCardTranslationField> fromAssistant(
    AssistantModel assistant,
  );
  static RoleCardTranslationField byId(
    AssistantModel assistant,
    String field,
  );
}

final class TranslationWorkEstimate {
  final int totalRunes;
  final int resolvedRunes;
  final bool usedFallback;
}

final class TranslationProgressAnchor {
  final int totalRunes;
  final int anchorResolvedRunes;
  final double anchorProgress;
  double map(int resolvedRunes);
}

final class TranslationWorkEstimator {
  const TranslationWorkEstimator();

  int totalRunesForAssistant(AssistantModel assistant);
  int totalRunesForResults(
    Iterable<AssistantRoleCardImportResult> results, {
    String initialOpening = '',
  });
  int resolvedRunesForCheckpoint(TranslationChunkCheckpoint checkpoint);
  int? tryTotalRunesForTaskSource(String sourcePayload);
}
```

- [ ] **Step 1: Write estimator contract tests RED**

Cover Chinese, emoji and combining characters as Dart runes; six visible fields; empty fields; raw `memoryBook` marker excluded through translation view; JSON metadata/Base64 excluded; initial opening included; `completed` and `retainedOriginal` resolved; `pending` unresolved; `separatorAfter` included; a source-hash mismatch contributes zero; split/retry attempts do not double count.

```dart
test('checkpoint resolves completed and retained source with separators', () {
  final estimate = const TranslationWorkEstimator()
      .resolvedRunesForCheckpoint(checkpointWith(
    completed: const [('你好', '\n')],
    retained: const [('world', '')],
    pending: const [('later', '\n')],
  ));

  expect(estimate, '你好\nworld'.runes.length);
});
```

- [ ] **Step 2: Run estimator test RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_work_estimator_test.dart`

Expected: FAIL because the field contract and estimator do not exist.

- [ ] **Step 3: Implement the shared field contract**

For `memoryBook`, return `view.translationSource` and `view.restore`; for the other five fields, return the exact `AssistantModel` string and identity restore. Replace the private `_fields`, `_fieldLabel`, `_fieldValue` and `_translationFieldInput` logic in `AssistantRoleCardTranslationService` with this public contract.

- [ ] **Step 4: Implement estimator and anchor math**

The anchor must handle old progress above canonical rune progress without a stall:

```dart
double map(int resolvedRunes) {
  if (totalRunes <= 0) {
    return anchorProgress.clamp(0.04, 0.94).toDouble();
  }
  if (anchorResolvedRunes >= totalRunes) return 0.94;
  final remaining =
      ((resolvedRunes - anchorResolvedRunes) /
              (totalRunes - anchorResolvedRunes))
          .clamp(0, 1);
  final anchored = anchorProgress + remaining * (0.94 - anchorProgress);
  final canonical = 0.04 + 0.90 * (resolvedRunes / totalRunes).clamp(0, 1);
  return [anchorProgress, anchored, canonical]
      .reduce((a, b) => a > b ? a : b)
      .clamp(0.04, 0.94)
      .toDouble();
}
```

Clamp every valid estimate to `0 <= resolvedRunes <= totalRunes`. Clamp a persisted value at or above 0.94 to 0.94 only while the task is in a translating state; saving/completed terminal states retain 0.96/1.0 outside this mapper.

- [ ] **Step 5: Run estimator and translation-service tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_work_estimator_test.dart test/assistant_role_card_translation_service_test.dart`

Expected: PASS, including existing raw marker prompt assertions.

- [ ] **Step 6: Commit the shared work contract**

```bash
git add chatgpt_app_core/lib/chat/application/role_card_translation_fields.dart \
  chatgpt_app_core/lib/chat/application/translation_work_estimator.dart \
  chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart \
  chatgpt_app_core/test/translation_work_estimator_test.dart \
  chatgpt_app_core/test/assistant_role_card_translation_service_test.dart
git commit -m "feat(story): estimate translatable body work"
```

---

### Task 4: Emit rune-aware field and chunk progress

**Files:**

- Modify: `chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart`
- Modify: `chatgpt_app_core/lib/chat/application/tavern_room_import_preparer.dart`
- Test: `chatgpt_app_core/test/assistant_role_card_translation_service_test.dart`
- Test: `chatgpt_app_core/test/tavern_room_import_preparer_test.dart`

**Interfaces:**

- Consumes: Task 3 estimator and field contract.
- Produces these backward-compatible nullable fields and optional named constructor arguments without changing any current member:

```dart
class RoleCardTranslationProgress {
  final int? completedRunes;
  final int? totalRunes;
}

class TavernRoomImportProgress {
  final int? completedRunes;
  final int? totalRunes;
}
```

- [ ] **Step 1: Write failing progress-event tests**

Assert: no rune is completed while waiting; every completed chunk advances by its source plus separator; restored completed chunks count once; retry/split does not advance; retained original advances; final field event reaches its assistant total; whole-card success emits `completedRunes == totalRunes`; Tavern wrapper forwards both values unchanged.

- [ ] **Step 2: Run focused tests RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/assistant_role_card_translation_service_test.dart test/tavern_room_import_preparer_test.dart`

Expected: FAIL because progress objects do not expose rune totals.

- [ ] **Step 3: Enrich service progress from checkpoint state**

Compute `completedBeforeField` from already restored/finished fields. Inside `_translateCheckpoint`, calculate current resolved work from all non-pending states after `await onChunkCheckpoint`; emit only then so visible progress never gets ahead of durable recovery state.

```dart
final resolvedInField = estimator.resolvedRunesForCheckpoint(current);
onProgress?.call(RoleCardTranslationProgress(
  field: current.field,
  fieldLabel: fieldLabel,
  current: fieldIndex,
  total: fieldTotal,
  stage: stage,
  detail: detail,
  fieldProgress: fieldProgress,
  completedRunes: completedBeforeField + resolvedInField,
  totalRunes: totalWork,
));
```

- [ ] **Step 4: Forward rune values through Tavern progress**

Add only the two optional constructor arguments and copy them in `TavernRoomImportPreparer`:

```dart
completedRunes: value.completedRunes,
totalRunes: value.totalRunes,
```

No old caller must be forced to supply them.

- [ ] **Step 5: Run progress tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/assistant_role_card_translation_service_test.dart test/tavern_room_import_preparer_test.dart`

Expected: PASS and existing field/stage text remains unchanged.

- [ ] **Step 6: Commit progress events**

```bash
git add chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart \
  chatgpt_app_core/lib/chat/application/tavern_room_import_preparer.dart \
  chatgpt_app_core/test/assistant_role_card_translation_service_test.dart \
  chatgpt_app_core/test/tavern_room_import_preparer_test.dart
git commit -m "feat(story): report rune weighted translation progress"
```

---

### Task 5: Persist monotonic task progress and replace serialized estimates

**Files:**

- Modify: `chatgpt_app_core/lib/chat/application/translation_work_estimator.dart`
- Modify: `chatgpt_app_core/lib/chat/application/story_template_translation_tasks.dart`
- Modify: `chatgpt_app_core/lib/pages/story_room_list_page.dart`
- Modify: `chatgpt_app_core/lib/pages/assistant_list_page.dart`
- Test: `chatgpt_app_core/test/translation_work_estimator_test.dart`
- Test: `chatgpt_app_core/test/story_template_management_test.dart`
- Test: `chatgpt_app_core/test/tavern_room_import_task_test.dart`
- Test: `chatgpt_app_core/test/translation_settings_dialog_test.dart`
- Create: `chatgpt_app_core/test/translation_task_log_dialog_test.dart`

**Interfaces:**

- Consumes: Task 4 rune event pair plus existing `sourcePayload`, `partialPayload`, `fieldPayload`, `chunkPayload`.
- Produces:

```dart
TranslationWorkEstimate? estimateTask(
  StoryTemplateTranslationTaskModel task,
);

String formatRuneProgress(int completedRunes, int totalRunes);
// "已完成 8,420/33,322 字"
```

- [ ] **Step 1: Write runner/resume/estimate tests RED**

Cover a 33,322-rune worldbook across multiple checkpoints; progress moves after each completed chunk; later waiting/receiving stage events cannot overwrite that value with equal-field progress; pause/restart/replace-model stays monotonic; complete-keeping-original advances and keeps warning; completed role in `partialPayload` counts fully after field/chunk payload clear; opening counts; a valid legacy source plus unsupported `checkpointVersion` falls back to the existing formula and still completes; an invalid `sourcePayload` retains the runner's current failure behavior rather than pretending it is recoverable; no task schema fields are added.

- [ ] **Step 2: Run focused task tests RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_work_estimator_test.dart test/story_template_management_test.dart test/tavern_room_import_task_test.dart`

Expected: FAIL on the current equal-field progress and serialized source estimates.

- [ ] **Step 3: Recompute task work at runner start and checkpoint boundaries**

At `run()` startup, before mutating `task.progress`, first call the existing `_sourcePayload()`; if that fails, preserve the existing failed-task path. For a valid source, compute `initialEstimate = estimateTask(task)`, then capture `anchorProgress = task.progress` and `anchorResolvedRunes = initialEstimate.resolvedRunes` only when the estimate is non-null, non-fallback and has positive total work (otherwise use `0`, because the anchor is unused by fallback). Recompute after `_saveChunkCheckpoint`, `_saveFieldCheckpoint`, role commit, opening commit and `completeKeepingOriginalChunks`.

The estimator mirrors runner recovery rules exactly:

- malformed `partialPayload`/`fieldPayload` are ignored just as the runner ignores them;
- a chunk contributes only when scope, role index, field and `checkpoint.matchesSource(field, source)` all match;
- a mismatched source hash contributes zero without invalidating the whole estimate;
- for a raw-marker `memoryBook`, a field checkpoint alone never proves resolved work; count only its matching chunk states until the completed role is committed into `partialPayload`;
- use precedence `completed role in partialPayload > trustworthy field checkpoint > matching chunk states`, never sum two representations of the same source field;
- an unknown checkpoint envelope/version that the runner can ignore returns `usedFallback: true`; an exception or irreconcilable valid legacy progress envelope returns `null`.

Replace the active runner's `_progressFor`/field-ratio choice with one helper. When `estimate != null`, `!estimate.usedFallback` and `estimate.totalRunes > 0`, it returns `max(task.progress, anchor.map(estimate.resolvedRunes))`; for `null`, `usedFallback` or zero total it returns `max(task.progress, legacyProgress).clamp(0.04, 0.94).toDouble()`. Stage events that have not formed a new checkpoint reuse that current monotonic value and may update only stage/detail. Persist through the existing task save queue; do not add database columns, and do not modify the unused page-local legacy coordinator.

When rune data is valid, append the formatted amount to the existing stage detail without dropping chunk text:

```dart
String _withRuneDetail(String detail, TranslationWorkEstimate work) => [
  if (detail.trim().isNotEmpty) detail.trim(),
  formatRuneProgress(work.resolvedRunes, work.totalRunes),
].join(' · ');
```

- [ ] **Step 4: Prefer rune progress in in-memory import UI and retain fallback**

Update `_translationProgressRatio` and detail builders in `AssistantListPage`:

```dart
if (value.completedRunes != null &&
    value.totalRunes != null &&
    value.totalRunes! > 0) {
  return (value.completedRunes! / value.totalRunes!)
      .clamp(0, 1)
      .toDouble();
}
return _legacyFieldProgressRatio(value);
```

Keep the old formula in a named fallback function for legacy events.

- [ ] **Step 5: Replace all six serialized `estimatedRunes` call sites**

Use these exact replacements:

```dart
estimator.totalRunesForAssistant(importResults.single.assistant)

estimator.totalRunesForResults(importResults)

estimator.totalRunesForResults(
  importPlans.map((plan) => plan.result),
)

estimator.totalRunesForResults(
  payload.results,
  initialOpening: payload.initialOpening,
)

estimator.tryTotalRunesForTaskSource(task.sourcePayload) ?? 0
```

For single/batch Tavern import, choose `initialOpening` before opening `showTranslationSettingsDialog`, then include it in the estimate. Remove every estimate based on the encoded JSON payload length or `task.sourcePayload.runes.length`. In the settings dialog, `estimatedRunes <= 0` renders “预计字符数暂不可用” and never claims the task has zero work.

- [ ] **Step 6: Verify rune detail rendering and legacy fallback GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_work_estimator_test.dart test/story_template_management_test.dart test/tavern_room_import_task_test.dart test/translation_settings_dialog_test.dart test/translation_task_log_dialog_test.dart`

Expected: PASS; `已完成 8,420/33,322 字` is visible, valid legacy checkpoint metadata falls back and completes, and invalid source data still follows the existing failed-task path.

- [ ] **Step 7: Commit persistent progress and estimate wiring**

```bash
git add chatgpt_app_core/lib/chat/application/translation_work_estimator.dart \
  chatgpt_app_core/lib/chat/application/story_template_translation_tasks.dart \
  chatgpt_app_core/lib/pages/story_room_list_page.dart \
  chatgpt_app_core/lib/pages/assistant_list_page.dart \
  chatgpt_app_core/test/translation_work_estimator_test.dart \
  chatgpt_app_core/test/story_template_management_test.dart \
  chatgpt_app_core/test/tavern_room_import_task_test.dart \
  chatgpt_app_core/test/translation_settings_dialog_test.dart \
  chatgpt_app_core/test/translation_task_log_dialog_test.dart
git commit -m "feat(story): persist body weighted translation progress"
```

---

### Task 6: Account-scoped probe cache, fingerprint and authoritative invalidation

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/translation_model_probe_cache.dart`
- Create: `chatgpt_app_core/lib/chat/application/translation_model_probe_fingerprint.dart`
- Modify: `chatgpt_app_core/lib/chat/application/reasoning_control_adapter.dart`
- Modify: `chatgpt_app_core/lib/dao/ai_settings_dao.dart`
- Test: `chatgpt_app_core/test/translation_model_probe_cache_test.dart`
- Test: `chatgpt_app_core/test/ai_settings_secure_storage_test.dart`

**Interfaces:**

- Consumes: `TranslationModelResolver.apply`, `AISettings.activeLocal`, `BackendConfig.buildUri`, `AIProviderHealthConfiguration.capture(beforeProvider).matches(afterProvider)`, `crypto.sha256`.
- Produces:

```dart
enum TranslationModelProbeStatus { verified, failed }

final class TranslationModelProbeCacheToken {
  final int accountGeneration;
  final int providerGeneration;

  const TranslationModelProbeCacheToken({
    required this.accountGeneration,
    required this.providerGeneration,
  });

  bool sameAs(TranslationModelProbeCacheToken other) =>
      accountGeneration == other.accountGeneration &&
      providerGeneration == other.providerGeneration;
}

final class TranslationModelProbeRecord {
  final String fingerprint;
  final TranslationModelProbeStatus status;
  final DateTime checkedAt;
  final int? firstEventMs;
  final int? totalMs;
  final String? safeErrorCode;
  final bool reasoningControlSuppressed;
  Map<String, dynamic> toJson();
  factory TranslationModelProbeRecord.fromJson(Map<String, dynamic> json);
}

final class TranslationModelProbeCache {
  static const ttl = Duration(days: 7);
  static const maxRecords = 50;
  static final shared = TranslationModelProbeCache();
  static String keyFor(String accountHash);

  TranslationModelProbeCache({DateTime Function()? now});

  TranslationModelProbeCacheToken tokenFor({
    required String accountHash,
    required String? providerId,
  });

  TranslationModelProbeRecord? lookup({
    required String accountHash,
    required String fingerprint,
  });
  Future<bool> put(
    TranslationModelProbeRecord record, {
    required String expectedAccountHash,
    required String? providerId,
    required TranslationModelProbeCacheToken expectedToken,
  });
  Future<void> invalidateProviders({
    required String accountHash,
    required Set<String> providerIds,
  });
  Future<void> clearAccount(String accountHash);
}

final class TranslationModelProbeFingerprint {
  static const protocolVersion = 1;
  static String build({
    required AISettings settings,
    required TranslationRequestProfile profile,
  });
}
```

- [ ] **Step 1: Write strict cache/fingerprint tests RED**

Test account isolation, strict JSON types, seven-day boundary, max 50 newest records, cancellation absence, corrupt JSON fallback, provider index invalidation, endpoint/model/mode/reasoning/policy-version fingerprint changes, and same fingerprint when only API Key changes. Add deterministic queue interleavings proving: invalidation before put rejects an old token; put before invalidation is subsequently removed; account clear rejects an old account token; a fresh token writes normally.

Also assert serialized cache text does not contain the API Key or endpoint:

```dart
expect(rawCache, isNot(contains('sk-secret')));
expect(rawCache, isNot(contains('https://private.example/v1')));
```

- [ ] **Step 2: Run cache tests RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_model_probe_cache_test.dart`

Expected: FAIL because cache/fingerprint files do not exist.

- [ ] **Step 3: Implement strict cache envelope and serialized write queue**

Persist records separately from the non-sensitive provider index:

```json
{
  "version": 1,
  "accountGeneration": 4,
  "providerGenerations": {"deepseek": 7},
  "records": {
    "9f2c0c9b8b7613f0a65e4dc3f29838f4b27afad3ee76ccbfda93449a9e11d8d4": {
      "status": "verified"
    }
  },
  "providers": {
    "deepseek": [
      "9f2c0c9b8b7613f0a65e4dc3f29838f4b27afad3ee76ccbfda93449a9e11d8d4"
    ]
  }
}
```

Use the preference store's account-before/account-after checks, process-wide per-key save tails and rollback so `shared` and injected test instances cannot race. `tokenFor` synchronously reads the envelope's account generation plus the selected provider generation (`0` for a missing entry; backend uses provider id `null`). `put`, `invalidateProviders` and `clearAccount` all execute in that same per-account queue:

- `put` re-reads both generations inside its queued critical section and returns `false` without writing when either differs from `expectedToken`;
- `invalidateProviders` increments every affected provider generation before deleting its indexed records;
- `clearAccount` increments `accountGeneration` and writes an empty envelope instead of deleting the key, so an old in-flight request cannot recreate cleared state with generation zero.

The generation token is concurrency metadata, never part of `TranslationModelProbeRecord`, the fingerprint, logs or task data. Expired/corrupt/evicted records are removed from every provider index, and empty provider entries are deleted. Expired/corrupt records are ignored synchronously and cleaned on the next write. The injected `now` defaults to `DateTime.now` and owns every TTL comparison in deterministic tests.

- [ ] **Step 4: Implement canonical fingerprint and policy version**

Add `ReasoningControlAdapter.policyVersion = 1`. First restore the exact formal transport settings and derive every canonical variable before hashing:

```dart
final applied = TranslationModelResolver.apply(settings, profile);
final isLocal = profile.mode == TranslationExecutionMode.local;
final providerId = isLocal ? applied.activeProvider.id : 'backend';
final providerCode = isLocal
    ? applied.activeProvider.providerCode
    : 'backend';
final endpointUri = isLocal
    ? Uri.parse(applied.activeLocal.baseUrl)
    : BackendConfig.buildUri('/uapi/chat/completions/stream');
final normalizedPath = endpointUri.normalizePath().path;
final normalizedUri = Uri(
  scheme: endpointUri.scheme.toLowerCase(),
  host: endpointUri.host.toLowerCase(),
  port: endpointUri.hasPort ? endpointUri.port : null,
  path: normalizedPath,
  query: endpointUri.hasQuery ? endpointUri.query : null,
);
final effectiveEndpoint = normalizedUri.toString();
```

The eligibility evaluator has already rejected an empty/relative URI, unsupported scheme, empty host or user-info credentials. Preserve explicit port, path and query because they affect the formal request; normalize dot segments and scheme/host case, and discard only the non-request fragment. The backend identity uses the formal stream URI, not a bare host. Then hash canonical JSON containing no API Key:

```dart
final canonical = jsonEncode({
  'protocolVersion': TranslationModelProbeFingerprint.protocolVersion,
  'reasoningPolicyVersion': ReasoningControlAdapter.policyVersion,
  'mode': profile.mode.name,
  'providerId': providerId,
  'providerCode': providerCode,
  'modelId': profile.modelId,
  'endpoint': effectiveEndpoint,
  'reasoningPolicy': profile.reasoningPolicy.name,
});
return sha256.convert(utf8.encode(canonical)).toString();
```

Only the returned hash may be persisted. Do not add `profile.reasoningControlSuppressed` to the input: it is evidence produced by a probe and must remain discoverable from the original unsuppressed identity. Tests use equivalent host-case/dot-segment endpoints to prove normalization, and changed port/path/query endpoints to prove invalidation.

- [ ] **Step 5: Invalidate cache inside authoritative AI settings save/clear**

In `AISettingsDao._saveForNow`, capture the same authoritative `previousSettings` value currently passed to `reconcileAIHealthState`, then compare it with `settingsToSave` by provider ID union:

```dart
Set<String> changedProbeProviderIds(
  AISettings? previous,
  AISettings next,
) {
  final beforeById = <String, AiProvider>{
    if (previous != null)
      for (final provider in previous.providers) provider.id: provider,
  };
  final afterById = <String, AiProvider>{
    for (final provider in next.providers) provider.id: provider,
  };
  final changed = <String>{};
  for (final id in {...beforeById.keys, ...afterById.keys}) {
    final before = beforeById[id];
    final after = afterById[id];
    if (before == null ||
        after == null ||
        !AIProviderHealthConfiguration.capture(before).matches(after)) {
      changed.add(id);
    }
  }
  return changed;
}
```

Before writing changed settings, call `TranslationModelProbeCache.shared.invalidateProviders` with that set. Its generation increment and record removal are one queued cache mutation. This covers added, removed, Key, effective host, effective model and model-list changes with the existing in-memory-only health snapshot; backend mode/model/URI changes naturally miss the old fingerprint. Because `saveForIfAbsent` also enters `_saveForNow`, guest migration is covered. In `_clearForNow`, call the generation-preserving `clearAccount` before writing the settings tombstone.

Do not put invalidation only in `AiProviderDetailPage`; backup restore, migration and direct DAO saves must use the same boundary.

- [ ] **Step 6: Run cache and secure-settings tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_model_probe_cache_test.dart test/ai_settings_secure_storage_test.dart`

Expected: PASS; Key replacement invalidates the provider despite the Key being absent from fingerprint.

- [ ] **Step 7: Commit probe persistence**

```bash
git add chatgpt_app_core/lib/chat/application/translation_model_probe_cache.dart \
  chatgpt_app_core/lib/chat/application/translation_model_probe_fingerprint.dart \
  chatgpt_app_core/lib/chat/application/reasoning_control_adapter.dart \
  chatgpt_app_core/lib/dao/ai_settings_dao.dart \
  chatgpt_app_core/test/translation_model_probe_cache_test.dart \
  chatgpt_app_core/test/ai_settings_secure_storage_test.dart
git commit -m "feat(story): cache translation model probes"
```

---

### Task 7: Bounded probe transport and first-event telemetry

**Files:**

- Modify: `chatgpt_app_core/lib/chat/domain/chat_request_options.dart`
- Modify: `chatgpt_app_core/lib/chat/application/translation_stream_executor.dart`
- Modify: `chatgpt_app_core/lib/dao/chat/direct_chat_service.dart`
- Modify: `chatgpt_app_core/lib/dao/chat/backend_chat_service.dart`
- Create: `chatgpt_app_core/test/support/fake_translation_chat_service.dart`
- Modify: `chatgpt_app_core/test/translation_stream_executor_test.dart`
- Modify: `chatgpt_app_core/test/direct_chat_service_test.dart`
- Modify: `chatgpt_app_core/test/backend_chat_service_test.dart`

**Interfaces:**

- Consumes: Existing typed SSE, abort and deadline behavior.
- Produces:

```dart
final class ChatRequestOptions {
  final ChatRequestProfile profile;
  final ChatReasoningPolicy reasoningPolicy;
  final Future<void>? abortTrigger;
  final Duration connectTimeout;
  final int? minOutputTokens;
  final bool suppressReasoningControl;
  final int? maxOutputTokensOverride;

  const ChatRequestOptions({
    this.profile = ChatRequestProfile.standard,
    this.reasoningPolicy = ChatReasoningPolicy.providerDefault,
    this.abortTrigger,
    this.connectTimeout = const Duration(seconds: 20),
    this.minOutputTokens,
    this.suppressReasoningControl = false,
    this.maxOutputTokensOverride,
  }) : assert(
          maxOutputTokensOverride == null || maxOutputTokensOverride > 0,
        );
}

final class TranslationStreamExecutor {
  TranslationStreamExecutor({
    required ChatService service,
    required TranslationRequestProfile profile,
    Future<void> Function(TranslationRequestProfile)? onProfileChanged,
    Duration firstEventTimeout = const Duration(seconds: 45),
    Duration idleTimeout = const Duration(seconds: 60),
    Duration totalTimeout = const Duration(minutes: 5),
    int? maxOutputTokensOverride,
  });

  Future<String> complete(
    String prompt, {
    required TranslationCancellationToken cancellation,
    void Function(TranslationStreamPhase phase)? onPhase,
    void Function()? onFirstEvent,
    Future<void> Function(TranslationRequestProfile profile)? onProfileChanged,
  });
}
```

- [ ] **Step 1: Extract the existing fake transport without behavior changes**

Move `_FakeChatService`, `_FakeRequest` and their script typedefs from `translation_stream_executor_test.dart` into `test/support/fake_translation_chat_service.dart`; rename them `FakeTranslationChatService` and `FakeTranslationRequest`. Run the existing executor test before adding features.

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_stream_executor_test.dart`

Expected: PASS with the same existing assertions.

- [ ] **Step 2: Write failing exact-token and first-event tests**

Assert that `maxOutputTokensOverride: 128` writes exactly 128 to both direct/backend request bodies even when settings are 4096; normal translation still uses at least 2048. Emit a usage event before reasoning/text and assert `onFirstEvent` fires once at usage arrival.

- [ ] **Step 3: Run transport tests RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_stream_executor_test.dart test/direct_chat_service_test.dart test/backend_chat_service_test.dart`

Expected: FAIL because exact override and first-event callback are absent.

- [ ] **Step 4: Implement exact override with validation**

Keep `ChatRequestOptions` const-compatible by asserting that the override is positive. The non-const `TranslationStreamExecutor` constructor and both transport helpers must also throw `ArgumentError.value` for a non-positive runtime value so release builds do not depend on assertions. Direct and backend services must then use the exact override first, otherwise preserve the old floor logic:

```dart
int? _maxTokensFor(ChatRequestOptions options) {
  final exact = options.maxOutputTokensOverride;
  if (exact != null) {
    if (exact <= 0) {
      throw ArgumentError.value(
        exact,
        'maxOutputTokensOverride',
        '必须大于 0',
      );
    }
    return exact;
  }
  final requestedMinimum = options.minOutputTokens ?? 0;
  final value = configuredMax >= requestedMinimum
      ? configuredMax
      : requestedMinimum;
  return value > 0 ? value : null;
}
```

The executor forwards the override through `ChatRequestOptions`; tests must cover both the const assertion and the release-safe runtime validation so zero or a negative value can never silently remove the cap.

- [ ] **Step 5: Fire first-event telemetry at the actual typed event boundary**

Inside the stream listener, before the event-type switch:

```dart
if (!sawEvent) {
  sawEvent = true;
  try {
    onFirstEvent?.call();
  } catch (_) {
    // Telemetry callbacks never own the request.
  }
}
```

Keep usage/reasoning as idle activity and do not append them to output.

- [ ] **Step 6: Run transport tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_stream_executor_test.dart test/direct_chat_service_test.dart test/backend_chat_service_test.dart`

Expected: PASS; existing abort/deadline/Thinking negotiation tests remain green.

- [ ] **Step 7: Commit bounded transport support**

```bash
git add chatgpt_app_core/lib/chat/domain/chat_request_options.dart \
  chatgpt_app_core/lib/chat/application/translation_stream_executor.dart \
  chatgpt_app_core/lib/dao/chat/direct_chat_service.dart \
  chatgpt_app_core/lib/dao/chat/backend_chat_service.dart \
  chatgpt_app_core/test/support/fake_translation_chat_service.dart \
  chatgpt_app_core/test/translation_stream_executor_test.dart \
  chatgpt_app_core/test/direct_chat_service_test.dart \
  chatgpt_app_core/test/backend_chat_service_test.dart
git commit -m "feat(chat): support bounded translation probes"
```

---

### Task 8: Explicit single-flight translation probe service

**Files:**

- Create: `chatgpt_app_core/lib/chat/application/translation_model_probe_service.dart`
- Test: `chatgpt_app_core/test/translation_model_probe_service_test.dart`
- Reuse: `chatgpt_app_core/test/support/fake_translation_chat_service.dart`

**Interfaces:**

- Consumes: Tasks 6–7 fingerprint/cache/executor.
- Produces:

```dart
typedef TranslationProbeExecutorFactory = TranslationStreamExecutor Function({
  required AISettings settings,
  required TranslationRequestProfile profile,
  required Future<void> Function(TranslationRequestProfile)
      onProfileChanged,
});

final class TranslationModelProbeResult {
  final TranslationModelProbeRecord record;
}

final class TranslationModelProbeIdentity {
  final String accountHash;
  final String fingerprint;
  final TranslationModelProbeCacheToken cacheToken;
  final AIProviderHealthConfiguration? _localProviderConfiguration;

  TranslationModelProbeIdentity({
    required this.accountHash,
    required this.fingerprint,
    required this.cacheToken,
    AIProviderHealthConfiguration? localProviderConfiguration,
  }) : _localProviderConfiguration = localProviderConfiguration;
}

abstract interface class TranslationModelProbeHandle {
  Future<TranslationModelProbeResult> get result;
  void cancel();
}

abstract interface class TranslationModelProbeGateway {
  TranslationModelProbeIdentity identify({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });

  bool isIdentityCurrent(
    TranslationModelProbeIdentity identity, {
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });

  TranslationModelProbeRecord? lookup({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });

  TranslationModelProbeHandle start({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
    required bool Function() isConfigurationCurrent,
  });

  TranslationRequestProfile applyCachedEvidence({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });
}

// Constructor of the concrete TranslationModelProbeService implementation.
TranslationModelProbeService({
  TranslationModelProbeCache? cache,
  TranslationProbeExecutorFactory? executorFactory,
  DateTime Function()? now,
  Stopwatch Function()? stopwatchFactory,
});
```

`TranslationModelProbeIdentity` is in-memory only and implements neither serialization nor a diagnostic `toString`; its private health snapshot may contain the Key for equality checks and must never enter logs.

Implement a concrete `final class TranslationModelProbeService implements TranslationModelProbeGateway` with the constructor above and `static final shared = TranslationModelProbeService()`. Back all five gateway methods with `cache ?? TranslationModelProbeCache.shared`, the formal executor factory below, `DateTime.now`, and `Stopwatch.new` defaults. Production page callers always reuse `TranslationModelProbeService.shared`; tests construct isolated instances with fake dependencies. Merely constructing either instance performs no I/O.

- [ ] **Step 1: Write probe service tests RED**

Test fixed prompt contains no supplied user content; success parses a non-empty `translation` string; reasoning-first and usage-first streams record first-event latency; authentication/invalid API/429/first/idle/network/invalid output map to approved safe codes; server and total timeout map to `unknown`; cancel aborts and is not cached; same account/fingerprint/cache token/in-memory provider configuration returns one request with two subscriber handles; cancelling one subscriber does not abort the remaining subscriber, while cancelling the last subscriber closes the transport; a Key change during an in-flight request neither joins the old flight nor lets the old completion repopulate invalidated cache; cache lookup and identity comparison create zero requests; an explicitly confirmed `start` sends one fresh request even when a valid historical record exists; suppression negotiation is cached and `applyCachedEvidence` returns a suppressed profile, including when the no-parameter retry later fails for another reason.

- [ ] **Step 2: Run probe service test RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_model_probe_service_test.dart`

Expected: FAIL because the service does not exist.

- [ ] **Step 3: Implement a fixed privacy-safe prompt and strict output validation**

Use one constant prompt only:

```dart
const translationProbePrompt = '''你是翻译接口兼容性测试器。
把 JSON 中的英文短语翻译为简体中文。
只返回一个 JSON 对象，不要 Markdown，不要解释：
{"translation":"Good morning"}''';
```

Parse with `AssistantRoleCardTranslationService.decodeTranslation`, then require `translation is String`, non-empty and not case-insensitively equal to `Good morning`.

- [ ] **Step 4: Implement single-flight handle, latency and safe caching**

The default executor factory must use the formal selected settings/profile and exact cap:

```dart
TranslationStreamExecutor(
  service: ChatService.from(TranslationModelResolver.apply(settings, profile)),
  profile: profile,
  onProfileChanged: onProfileChanged,
  maxOutputTokensOverride: 128,
)
```

`identify` computes the persisted fingerprint, captures `cache.tokenFor(accountHash: accountHash, providerId: isLocal ? applied.activeProvider.id : null)`, and for local mode retains `AIProviderHealthConfiguration.capture(applied.activeProvider)` in a private in-memory field. `isIdentityCurrent` requires equal account, recomputed fingerprint, `cacheToken.sameAs(currentToken)` and a matching current local provider health snapshot; it catches resolver/configuration errors and returns false.

Before creating the request, call the subscriber's guard once and fail safely with zero requests if it is already false. Use `accountHash:fingerprint` as the service-instance flight bucket, but join only when cache tokens and in-memory provider configurations also match. This prevents two different API Keys or invalidation generations from coalescing even though neither is part of the persisted hash. Backend flights use account/fingerprint/account-generation identity because their formal endpoint/model are already in the fingerprint. `lookup` is the only historical-cache read path; `start` represents a confirmed user retest and always creates one fresh request unless an equivalent flight exists. The shared production instance therefore deduplicates across dialog reopenings.

Each `start` returns a distinct subscriber handle over the shared flight. `handle.cancel()` completes only that subscriber with cancelled and removes it; cancel the underlying `TranslationCancellationController` only when the last subscriber detaches. Completion fans the same sanitized result/error to remaining subscribers, removes the flight, and never leaves a reusable completed handle.

Track `effectiveProfile`, initialize it from the selected profile, and replace it in `onProfileChanged`; the resulting record takes `reasoningControlSuppressed` from that tracked profile. Start an injected stopwatch immediately before `complete`; record first event once and total at terminal, and use the injected clock for `checkedAt`. Persist success/failure except `cancelled`, always under the initial identity's fingerprint even when negotiation updates `effectiveProfile`. Immediately before `cache.put`, require at least one active subscriber's guard to return true (treat exceptions as false), then pass the identity's captured cache token to `put`; the queued generation CAS is the authoritative protection against invalidation occurring after that guard. Store no prompt/output/error body.

Map executor failures by kind, never by raw provider text:

```dart
String probeSafeCode(TranslationFailureKind kind) => switch (kind) {
  TranslationFailureKind.authentication => 'auth_failed',
  TranslationFailureKind.invalidRequest ||
  TranslationFailureKind.unsupportedReasoningControl => 'unsupported_api',
  TranslationFailureKind.rateLimited => 'rate_limited',
  TranslationFailureKind.firstEventTimeout => 'first_event_timeout',
  TranslationFailureKind.idleTimeout => 'idle_timeout',
  TranslationFailureKind.network => 'network_unreachable',
  TranslationFailureKind.invalidOutput => 'invalid_output',
  TranslationFailureKind.cancelled => 'cancelled',
  TranslationFailureKind.server || TranslationFailureKind.totalTimeout =>
    'unknown',
};
```

Cancellation completes the handle with the safe cancelled failure and removes the single-flight entry, but never constructs or persists a failed record.

- [ ] **Step 5: Apply cached Thinking suppression to formal task profiles**

Thinking-parameter incompatibility is evidence independent of the probe's final success. Any fresh same-fingerprint record with `reasoningControlSuppressed=true` transforms a profile, including a failed record whose no-parameter retry later hit a network/server/output error:

```dart
return record?.reasoningControlSuppressed == true
    ? profile.suppressReasoningControl()
    : profile;
```

Expired/other-fingerprint evidence must not alter the task. A failed record still remains a warning in the UI; applying its independently established suppression flag does not convert it to verified.

- [ ] **Step 6: Run probe service tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_model_probe_service_test.dart test/translation_stream_executor_test.dart`

Expected: PASS; the fake service observes one request and no live network is used.

- [ ] **Step 7: Commit explicit probe service**

```bash
git add chatgpt_app_core/lib/chat/application/translation_model_probe_service.dart \
  chatgpt_app_core/test/translation_model_probe_service_test.dart
git commit -m "feat(story): probe translation model compatibility"
```

---

### Task 9: Translation settings and picker preflight UX

**Files:**

- Modify: `chatgpt_app_core/lib/widget/translation_settings_dialog.dart`
- Modify: `chatgpt_app_core/lib/widget/configured_ai_model_picker_sheet.dart`
- Modify: `chatgpt_app_core/lib/pages/story_room_list_page.dart`
- Modify: `chatgpt_app_core/lib/pages/assistant_list_page.dart`
- Test: `chatgpt_app_core/test/translation_settings_dialog_test.dart`
- Test: `chatgpt_app_core/test/configured_ai_model_picker_sheet_test.dart`
- Test: `chatgpt_app_core/test/story_template_management_test.dart`
- Test: `chatgpt_app_core/test/tavern_room_import_task_test.dart`

**Interfaces:**

- Consumes: eligibility evaluator and probe service.
- Produces a concrete result so cached suppression cannot be lost:

```dart
final class TranslationSettingsResult {
  final TranslationModelPreference preference;
  final TranslationRequestProfile profile;
  final TranslationModelProbeIdentity identity;
  final bool warningsAcknowledged;
}

final class TranslationSettingsSnapshot {
  final AISettings settings;
  final String accountHash;
  final TranslationEligibilityEnvironment eligibilityEnvironment;
}

typedef TranslationSettingsSnapshotReader = TranslationSettingsSnapshot
    Function();

Future<TranslationSettingsResult?> showTranslationSettingsDialog(
  BuildContext context, {
  required TranslationSettingsSnapshotReader readSnapshot,
  required TranslationModelPreference initialValue,
  required int estimatedRunes,
  required TranslationModelProbeGateway probeService,
  Future<void> Function(TranslationEligibilityIssue issue)? onFixIssue,
  String title = '翻译设置',
});

Future<TranslationModelPreference?> showConfiguredAiModelPickerSheet(
  BuildContext context, {
  required AISettings settings,
  required TranslationModelPreference selected,
  TranslationEligibilityResult Function(
    TranslationModelPreference preference,
  )? eligibilityFor,
  TranslationModelProbeRecord? Function(
    TranslationModelPreference preference,
  )? probeFor,
  bool includeUnavailable = false,
  bool includeFollowGlobal = true,
  TranslationExecutionMode? onlyMode,
});
```

- [ ] **Step 1: Write zero-hidden-request and status tests RED**

Use a counting fake `TranslationModelProbeGateway` and mutable snapshot reader. Pump/open the dialog, switch local/backend/follow-global choices, search/filter, rebuild and expire a fake record; assert request count stays zero. Confirming “开始翻译” for an unverified model must return a profile without calling `start`. While the dialog remains open, mutate account, Key, endpoint and provider availability; assert submit/test re-read the snapshot, stale fingerprints lose suppression/status, and a newly blocked selection sends zero requests. Mutate identity or cache status after the dialog returns but before coordinator start; assert the page reopens confirmation and no task row/executor is created, while an unchanged identity passes a freshly applied suppression profile. Verify picker badges for verified/unverified/failed/blocked/loopback, including disabled or missing-Key providers now shown as “配置不可用” rather than silently hidden. Add a regression case proving a caller that omits both readers and leaves `includeUnavailable` false still gets the existing configured-only list and health rendering.

- [ ] **Step 2: Write explicit probe interaction tests RED**

Assert: test button first opens the Token notice; cancel sends zero requests; confirm sends one; running state exposes cancel and calls handle.cancel; success shows checked time/first response; failure shows safe localized action; closing dialog cancels active handle; blocked selection cannot test/start; warning selection can start only after confirmation.

- [ ] **Step 3: Run widget tests RED**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_settings_dialog_test.dart test/configured_ai_model_picker_sheet_test.dart`

Expected: FAIL because the UI has no eligibility/probe contract.

- [ ] **Step 4: Implement pure-read picker badges**

The picker may call `eligibilityFor` and `probeFor` during build, but it must never receive or invoke a `startProbe` callback. Both readers stay optional because `conversation_page.dart` also reuses this picker; when they are absent and `includeUnavailable` is false, preserve the existing configured-only filtering and health rendering exactly. The translation dialog passes both readers plus `includeUnavailable: true`, which shows all providers with at least one non-empty model. Render one primary badge with precedence `blocked > local eligibility warning > fresh failed probe > fresh verified probe > unverified`; a verified loopback endpoint therefore still shows the address warning. Blocked tiles remain selectable so the outer dialog can show the exact fix action, but they cannot directly start work.

- [ ] **Step 5: Implement explicit dialog state and cancellation**

Keep one `_activeProbe` handle. `_testModel` performs: read snapshot and resolve selection → local eligibility check → Token notice → read/resolve/check again after the await → capture account, fingerprint and (for local mode) `AIProviderHealthConfiguration` → call `probeService.start` with an `isConfigurationCurrent` guard that re-reads the snapshot and requires the same account/fingerprint/provider health plus non-blocked eligibility → await result → read again and compare current account plus fingerprint/provider health → render only if still current. A changed/blocked configuration after the Token notice sends zero requests; a change while the request is running discards its stale UI result and prevents stale cache persistence. `dispose` calls only this dialog's subscriber handle `_activeProbe?.cancel()`.

Starting translation performs: read snapshot → resolve profile → eligibility check → inspect that identity's fresh record → warning confirmation → read/resolve/check again after the await → create the refreshed identity → apply evidence from the same refreshed snapshot → return `TranslationSettingsResult` with that identity and whether the warning was acknowledged. If identity changes across the confirmation, recompute the warning and require confirmation for the new identity before returning. Confirmation is required for a local eligibility warning, no fresh verified record, or any fresh failed record; one confirmation covers the combined warning summary. Blocked state disables start and exposes `onFixIssue(primaryIssue)`; after awaiting `onFixIssue`, refresh from `readSnapshot` rather than retaining the old settings.

- [ ] **Step 6: Update page callers to consume the concrete profile**

Each page supplies a zero-I/O `readSnapshot` that clones the current `AISettingsProvider` value, reads the current account hash and constructs `TranslationEligibilityEnvironment.current()` at call time. Pass `TranslationModelProbeService.shared`, never create a new production service per dialog.

Wrap each page's selection flow in a confirmation loop. Immediately before the coordinator call, synchronously read a fresh snapshot, resolve an unsuppressed profile from `result.preference`, evaluate eligibility, and call `probeService.isIdentityCurrent(result.identity, ...)`. If identity changed, or the current state now requires a warning while `result.warningsAcknowledged` is false, show “翻译配置已变化，请重新确认” and reopen the dialog with `result.preference`; do not create/retry a task. When current, persist the confirmed preference, call `applyCachedEvidence` again from that same snapshot, and pass this freshly resolved profile—not the earlier `result.profile`—to the coordinator.

Build the coordinator's required checker as a page-specific wrapper around Task 2 eligibility. In addition to local eligibility, it re-reads settings and requires the finalized identity to remain current and the current cached-evidence profile's `reasoningControlSuppressed` value to equal the profile being saved/executed. On mismatch return a blocked `configurationChanged` issue with message “翻译配置已变化，请重新确认” and action “返回翻译设置”. New-task `start` therefore throws before saving a row; replacement-model `retry` returns to the page's confirmation loop. App/background recovery, which has no pending UI choice, keeps Task 2's ordinary eligibility checker. Snapshot construction, identity checks and cache lookup do not start requests.

- [ ] **Step 7: Run widget and lifecycle tests GREEN**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub test/translation_settings_dialog_test.dart test/configured_ai_model_picker_sheet_test.dart test/story_template_management_test.dart test/tavern_room_import_task_test.dart`

Expected: PASS; zero hidden requests and cached suppression handoff are asserted.

- [ ] **Step 8: Commit preflight UI**

```bash
git add chatgpt_app_core/lib/widget/translation_settings_dialog.dart \
  chatgpt_app_core/lib/widget/configured_ai_model_picker_sheet.dart \
  chatgpt_app_core/lib/pages/story_room_list_page.dart \
  chatgpt_app_core/lib/pages/assistant_list_page.dart \
  chatgpt_app_core/test/translation_settings_dialog_test.dart \
  chatgpt_app_core/test/configured_ai_model_picker_sheet_test.dart \
  chatgpt_app_core/test/story_template_management_test.dart \
  chatgpt_app_core/test/tavern_room_import_task_test.dart
git commit -m "feat(story): expose translation model preflight"
```

---

### Task 10: Full verification and iOS acceptance

**Files:**

- Verify only; if a failure is found, fix it in the task-owning files and create a narrowly scoped follow-up fix commit without mixing unrelated cleanup.

**Interfaces:**

- Consumes: all prior tasks.
- Produces: automated evidence plus a manual-test handoff that does not spend real provider Tokens without user action.

- [ ] **Step 1: Run the complete focused suite**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub \
  test/translation_model_eligibility_test.dart \
  test/translation_request_profile_test.dart \
  test/translation_work_estimator_test.dart \
  test/assistant_role_card_translation_service_test.dart \
  test/tavern_room_import_preparer_test.dart \
  test/story_template_management_test.dart \
  test/tavern_room_import_task_test.dart \
  test/translation_model_probe_cache_test.dart \
  test/translation_model_probe_service_test.dart \
  test/translation_stream_executor_test.dart \
  test/direct_chat_service_test.dart \
  test/backend_chat_service_test.dart \
  test/translation_settings_dialog_test.dart \
  test/configured_ai_model_picker_sheet_test.dart \
  test/translation_task_log_dialog_test.dart \
  test/ai_settings_secure_storage_test.dart \
  test/backup_translation_task_lifecycle_test.dart \
  test/story_template_background_scheduler_test.dart
```

Expected: every listed test passes with zero failures.

- [ ] **Step 2: Run full core regression**

Run: `cd chatgpt_app_core && fvm flutter test --no-pub`

Expected: all tests pass; baseline before implementation is 1431/1431, and the final total is larger because of new tests.

- [ ] **Step 3: Run analyzer**

Run: `cd chatgpt_app_core && fvm flutter analyze --no-pub`

Expected: `No issues found!` or no new issues relative to the verified branch baseline; any actual error must be fixed before handoff.

- [ ] **Step 4: Verify repository and commit boundaries**

Run:

```bash
git status --short
git log --oneline --decorate c1541430..HEAD
git diff --check c1541430..HEAD
```

Expected: clean worktree, the design and implementation-plan documentation commits plus the planned focused implementation commits, and no whitespace errors.

- [ ] **Step 5: Run iOS simulator smoke without triggering a live probe**

Run from `chatgpt_flutter`:

```bash
fvm flutter emulators --launch apple_ios_simulator
xcrun simctl bootstatus booted -b
IOS_DEVICE_ID="$(
  fvm flutter devices --machine |
    /usr/bin/python3 -c 'import json, sys
devices = json.load(sys.stdin)
matches = [d for d in devices if d.get("targetPlatform") == "ios" and d.get("emulator") is True]
if not matches:
    raise SystemExit("No booted iOS simulator found")
print(matches[0]["id"])'
)"
fvm flutter run -d "$IOS_DEVICE_ID" --no-pub
```

If Codex sandboxing reports `engine.stamp: Operation not permitted`, rerun these FVM commands with the approved escalation; treat that message as an environment restriction, not an app failure, and do not modify the shared FVM installation.

Keep the installed simulator app and its data intact: do not uninstall, erase, or reset it. Verify launch, navigation into translation settings, model switching, cached badge rendering and closing the dialog without a probe loading state or request log. Do not edit credentials or click a real provider's “测试翻译模型”; quit `flutter run` with `q` after the smoke. Guest/backend, loopback, Android-store cleartext and the 33,322-rune checkpoint sequence remain deterministic widget/unit acceptance cases from Steps 1–2 rather than requiring destructive simulator reconfiguration.

- [ ] **Step 6: Leave the only real-provider acceptance action to the user**

Ask the user to choose one configured fast model, click “测试翻译模型”, acknowledge the small Token request, then confirm: one request, status/latency summary, and no repeated Thinking-parameter failure when starting a translation. This manual action is not required for the automated branch to remain test-clean, but it is required before claiming that a specific third-party provider works live.
