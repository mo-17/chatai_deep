# Tavern Raw Envelope Translation Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the internal `chatai_deep.tavern_raw.v1` Base64 envelope from being sent to translation models while preserving it exactly and allowing existing failed Tavern translation tasks to resume safely.

**Architecture:** `AssistantRoleCardService` owns a small immutable translation view that separates internal marker lines from the runtime world-book body and can restore them after translation. `AssistantRoleCardTranslationService` plans checkpoints, counts progress, builds prompts, and validates markers against only that body; old full-envelope checkpoints naturally fail their source hash and are replaced. The persistent task schema and import/export formats remain unchanged.

**Tech Stack:** Dart 3, Flutter 3.35.7/FVM, `flutter_test`, existing SQLite task runner and SHA-256 chunk checkpoints.

## Global Constraints

- Preserve every `# [chatai_deep.tavern_raw.v1] ...` marker line verbatim and in source order.
- Never send a raw marker or its Base64 payload to the model, logs, or error text.
- Translate marker-free `memoryBook` values exactly as before.
- Do not add or migrate database columns.
- Existing full-envelope `memoryBook` checkpoints must invalidate by source hash; checkpoints created after this fix must still resume normally.
- Keep the current task's completed non-`memoryBook` field checkpoints reusable.
- Write and observe each failing test before changing production code.

---

### Task 1: Define the raw-envelope translation view

**Files:**
- Modify: `chatgpt_app_core/lib/chat/application/assistant_role_card_service.dart`
- Test: `chatgpt_app_core/test/assistant_role_card_service_test.dart`

**Interfaces:**
- Consumes: the existing `_tavernRawMarker` rule and `memoryBookForRuntime(String)` behavior.
- Produces: `AssistantMemoryBookTranslationView AssistantRoleCardService.memoryBookTranslationView(String source)`, with `String translationSource`, `bool hasRawMarker`, and `String restore(String translatedBody)`.

- [ ] **Step 1: Write failing view tests**

Add tests proving an undecodable marker is still preserved, multiple marker lines stay ordered, and ordinary memory books are identity views:

```dart
test('memoryBookTranslationView preserves raw markers outside translation', () {
  const first = '# [chatai_deep.tavern_raw.v1] NOT_BASE64';
  const second = '# [chatai_deep.tavern_raw.v1] SECOND';
  final view = AssistantRoleCardService.memoryBookTranslationView(
    '$first\nkey => English\n$second',
  );

  expect(view.hasRawMarker, isTrue);
  expect(view.translationSource, 'key => English');
  expect(view.restore('key => 中文'), '$first\n$second\nkey => 中文');
});

test('memoryBookTranslationView is identity without a raw marker', () {
  final view = AssistantRoleCardService.memoryBookTranslationView(
    'key => English',
  );
  expect(view.hasRawMarker, isFalse);
  expect(view.translationSource, 'key => English');
  expect(view.restore('key => 中文'), 'key => 中文');
});
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_role_card_service_test.dart --plain-name memoryBookTranslationView
```

Expected: compilation fails because `memoryBookTranslationView` does not exist.

- [ ] **Step 3: Implement the minimal immutable view**

Add the public view without exposing decoded raw JSON:

```dart
static AssistantMemoryBookTranslationView memoryBookTranslationView(
  String source,
) {
  final markerLines = <String>[];
  final bodyLines = <String>[];
  for (final line in source.replaceAll('\r\n', '\n').split('\n')) {
    if (line.startsWith(_tavernRawMarker)) {
      markerLines.add(line);
    } else {
      bodyLines.add(line);
    }
  }
  return AssistantMemoryBookTranslationView._(
    markerLines: markerLines,
    translationSource: bodyLines.join('\n').trim(),
  );
}
```

Define `AssistantMemoryBookTranslationView` with an unmodifiable marker list and `restore` that returns the translated body unchanged when no marker exists, otherwise joins marker lines and the trimmed body with one newline.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the command from Step 2. Expected: both tests pass.

- [ ] **Step 5: Commit the view contract**

```bash
git add chatgpt_app_core/lib/chat/application/assistant_role_card_service.dart chatgpt_app_core/test/assistant_role_card_service_test.dart
git commit -m "fix(story): isolate tavern raw translation data"
```

---

### Task 2: Make the translation pipeline envelope-aware

**Files:**
- Modify: `chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart`
- Test: `chatgpt_app_core/test/assistant_role_card_translation_service_test.dart`
- Test: `chatgpt_app_core/test/tavern_room_import_task_test.dart`

**Interfaces:**
- Consumes: `AssistantRoleCardService.memoryBookTranslationView` from Task 1.
- Produces: body-only prompts/checkpoints and restored full `memoryBook` output; no public translation-service API changes.

- [ ] **Step 1: Write failing marker-only and marker-plus-body tests**

Use a 33,322-rune marker-only source and assert `complete` is never called. Add a second test that records every prompt and asserts neither the marker prefix nor a unique Base64 sentinel is present while the visible world-book body is translated and the original marker remains byte-for-byte equal.

```dart
test('marker-only memory book never reaches the model', () async {
  const prefix = '# [chatai_deep.tavern_raw.v1] ';
  final source = '$prefix${List.filled(33322 - prefix.runes.length, 'A').join()}';
  var calls = 0;
  final translated =
      await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
    AssistantModel(name: '', memoryBook: source),
    onChunkCheckpoint: (_, __) async {},
    complete: (_) async {
      calls += 1;
      throw StateError('raw marker reached model');
    },
  );
  expect(calls, 0);
  expect(translated.memoryBook, source);
});
```

In `tavern_room_import_task_test.dart`, also create a `tavernRoomImport` task
whose source role has a marker-only `memoryBook`, whose five prior fields are
present in `fieldPayload`, and whose `chunkPayload` contains a completed
checkpoint planned from the full envelope. Assert no prompt contains the raw
marker, the task completes, and exactly one room is created.

```dart
test('full-envelope checkpoint is discarded during Tavern task recovery',
    () async {
  const marker = '# [chatai_deep.tavern_raw.v1] LEGACY_SENTINEL';
  final legacy = const TranslationChunkPlanner().plan(
    field: 'memoryBook',
    source: marker,
  );
  final poisoned = TranslationChunkCheckpoint(
    field: legacy.field,
    sourceHash: legacy.sourceHash,
    chunks: [
      for (final state in legacy.chunks)
        TranslationChunkState(
          chunk: state.chunk,
          status: TranslationChunkStatus.completed,
          translatedText: 'CORRUPTED_BASE64_TRANSLATION',
          attempts: 1,
          lastErrorKind: TranslationFailureKind.invalidOutput,
        ),
    ],
  );
  final source = StoryRoomTemplatePayload(results: [
    AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Gail', memoryBook: marker),
    ),
  ]);
  final task = StoryTemplateTranslationTaskModel(
    sourceTitle: 'gail.png',
    sourcePayload: jsonEncode(source.toJson()),
    outputTitle: '盖尔',
    taskKind: StoryTemplateTranslationTaskKind.tavernRoomImport,
    fieldPayload: jsonEncode({
      'scope': 'role',
      'roleIndex': 0,
      'fields': {
        'name': '盖尔',
        'description': '',
        'prompt': '',
        'openingMessage': '',
        'exampleDialogs': '',
      },
    }),
    checkpointVersion: TranslationChunkCheckpoint.currentVersion,
    chunkPayload: jsonEncode({
      'version': TranslationChunkCheckpoint.currentVersion,
      'checkpoints': {'role:0:memoryBook': poisoned.toJson()},
    }),
  );
  await taskDao.saveTask(task);
  expect(await taskDao.claimTask(
    task.id!,
    leaseOwner: 'runner-raw-recovery',
    leaseDuration: const Duration(minutes: 5),
  ), isTrue);
  final prompts = <String>[];

  await StoryTemplateTranslationTaskRunner(
    taskDao: taskDao,
    templateDao: await StoryTemplateDao.create(storage),
    task: task,
    leaseOwner: 'runner-raw-recovery',
    useChunkCheckpoints: true,
    complete: (prompt) async {
      prompts.add(prompt);
      throw StateError('marker-only recovery must not call the model');
    },
    isCancelled: () => false,
  ).run();

  final stored = await taskDao.getTask(task.id!);
  final templates =
      await (await StoryTemplateDao.create(storage)).getTemplates();
  final output = StoryRoomTemplatePayload.fromTemplate(templates.single);
  expect(prompts, isEmpty);
  expect(output.results.single.assistant.memoryBook, marker);
  expect(stored?.status, StoryTemplateTranslationTaskStatus.completed);
  expect(stored?.outputRoomId, isNotNull);
  expect(await db.query('tb_story_room'), hasLength(1));
});
```

- [ ] **Step 2: Run the two tests and verify RED**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_role_card_translation_service_test.dart --plain-name "marker-only memory book never reaches the model"
fvm flutter test --no-pub test/assistant_role_card_translation_service_test.dart --plain-name "raw marker stays outside memory book prompts"
fvm flutter test --no-pub test/tavern_room_import_task_test.dart --plain-name "full-envelope checkpoint is discarded during Tavern task recovery"
```

Expected: the first test calls the model, the second prompt contains the raw
marker/Base64 sentinel, and the persistent task completes with
`CORRUPTED_BASE64_TRANSLATION` instead of the original marker.

- [ ] **Step 3: Route `memoryBook` through the translation view**

Import `assistant_role_card_service.dart`. Introduce this private input and
factory:

```dart
final class _TranslationFieldInput {
  final String source;
  final String Function(String translated) restore;

  const _TranslationFieldInput({
    required this.source,
    required this.restore,
  });
}

static _TranslationFieldInput _translationFieldInput(
  AssistantModel assistant,
  String field,
) {
  final value = _fieldValue(assistant, field);
  if (field != 'memoryBook') {
    return _TranslationFieldInput(source: value, restore: (text) => text);
  }
  final view = AssistantRoleCardService.memoryBookTranslationView(value);
  return _TranslationFieldInput(
    source: view.translationSource,
    restore: view.restore,
  );
}
```

Use the input source for:

```dart
restored.matchesSource(field, input.source)
_chunkPlanner.plan(field: field, source: input.source)
detail: '${input.source.runes.length} 字'
_validateProtectedMarkers(source: input.source, translated: mergedBody)
```

Use `input.restore(mergedBody)` only when assigning the translated field and saving its field checkpoint. Force the individual-field path whenever the memory-book view has a raw marker so whole-card translation can never include it.

The initial field-checkpoint filter must also compare any chunk checkpoint with
`_translationFieldInput(assistant, entry.key).source`; otherwise a new body-only
checkpoint could be mistaken for a legacy full-envelope field checkpoint.

- [ ] **Step 4: Run the marker tests and existing translation suite**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_role_card_translation_service_test.dart
fvm flutter test --no-pub test/tavern_room_import_task_test.dart --plain-name "full-envelope checkpoint is discarded during Tavern task recovery"
```

Expected: all tests pass, including protected-marker and 33,322-rune recovery tests.

- [ ] **Step 5: Commit the pipeline fix**

```bash
git add chatgpt_app_core/lib/chat/application/assistant_role_card_translation_service.dart chatgpt_app_core/test/assistant_role_card_translation_service_test.dart chatgpt_app_core/test/tavern_room_import_task_test.dart
git commit -m "fix(story): exclude tavern raw data from translation"
```

---

### Task 3: Run the reliability gate and refresh iOS

**Files:**
- Verify: the files modified in Tasks 1–2 and existing iOS Simulator app data.

**Interfaces:**
- Consumes: body-only checkpoint hashing from Task 2 and the existing persistent `StoryTemplateTranslationTaskRunner`.
- Produces: full regression and live evidence that the existing failed task recovers while the app data container remains intact.

- [ ] **Step 1: Run focused and full verification**

Run:

```bash
cd chatgpt_app_core
fvm flutter test --no-pub test/assistant_role_card_service_test.dart test/assistant_role_card_translation_service_test.dart test/tavern_room_import_task_test.dart
fvm flutter analyze --no-pub lib/chat/application/assistant_role_card_service.dart lib/chat/application/assistant_role_card_translation_service.dart
fvm flutter test --no-pub
```

Expected: focused suites and the full core suite pass; analyze adds no issue in the two modified files.

- [ ] **Step 2: Refresh the existing iOS app without clearing data**

Reuse the booted simulator and the ignored local Sherpa assets if required:

```bash
cd chatgpt_flutter
fvm flutter run -d 90DDF01C-C134-4A78-9345-3ACA45F1ECD9 --debug --no-pub
```

Do not call `simctl uninstall`, `erase`, or delete the data container. Verify the failed task is still present, retry it, and confirm it skips the raw envelope and creates exactly one room. Detach with `d` so the app remains installed and running.

- [ ] **Step 3: Inspect the final branch state**

Run `git diff --check`, `git status --short --branch`, and `git log -4 --oneline`.
Expected: no uncommitted tracked files and the two fix commits are at branch tip.

---

## Completion Evidence

- `git diff --check` exits 0 and the worktree is clean.
- No prompt or saved error contains `chatai_deep.tavern_raw.v1` or its Base64 payload.
- The existing Simulator task can recover without re-importing the role card or retranslating the first five fields.
- The Simulator app and its data container remain installed; no uninstall or erase command is used.
