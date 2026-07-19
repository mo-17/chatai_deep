import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/role_card_translation_fields.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/application/translation_work_estimator.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const estimator = TranslationWorkEstimator();

  group('RoleCardTranslationFields', () {
    test('exposes the six visible fields in stable order with labels', () {
      final assistant = AssistantModel(
        name: '名称',
        description: '简介',
        prompt: '人设',
        openingMessage: '开场',
        exampleDialogs: '对话',
        memoryBook: '世界书',
      );

      final fields = RoleCardTranslationFields.fromAssistant(assistant);

      expect(
        fields.map((field) => field.id),
        RoleCardTranslationFields.ids,
      );
      expect(
        fields.map((field) => field.label),
        ['名称', '简介', '人设', '开场', '示例对话', '世界书'],
      );
      expect(
        fields.map((field) => field.source),
        ['名称', '简介', '人设', '开场', '对话', '世界书'],
      );
      expect(
        RoleCardTranslationFields.byId(assistant, 'prompt').source,
        '人设',
      );
    });

    test('keeps raw memory-book markers outside work and restores them', () {
      const marker = '# [chatai_deep.tavern_raw.v1] QUJDRA==';
      final assistant = AssistantModel(
        name: '',
        memoryBook: '$marker\nkey => English',
      );

      final field = RoleCardTranslationFields.byId(assistant, 'memoryBook');

      expect(field.source, 'key => English');
      expect(field.restore('key => 中文'), '$marker\nkey => 中文');
    });

    test('restores a marker-only memory book byte-for-byte', () {
      const source = '# [chatai_deep.tavern_raw.v1] QUJDRA==';
      final field = RoleCardTranslationFields.byId(
        AssistantModel(name: '', memoryBook: source),
        'memoryBook',
      );

      expect(field.source, isEmpty);
      expect(field.restore(''), source);
    });
  });

  group('TranslationWorkEstimator body totals', () {
    test('counts Chinese, emoji and combining characters as Dart runes', () {
      final assistant = AssistantModel(
        name: '你',
        description: '😀',
        prompt: 'e\u0301',
      );

      expect(estimator.totalRunesForAssistant(assistant), 4);
    });

    test('counts only six visible fields and accepts empty fields', () {
      final assistant = AssistantModel(
        name: 'A',
        description: '',
        prompt: 'BC',
        openingMessage: '',
        exampleDialogs: 'D',
        memoryBook: '',
        worldBookJson: jsonEncode({'largeMetadata': 'M' * 200}),
        roleCardAssets: base64Encode(List<int>.filled(300, 65)),
        avatarValue: 'data:image/png;base64,${'Q' * 400}',
        defaultVoiceStyle: 'voice-id',
        providerId: 'provider-id',
        model: 'model-id',
      );

      expect(estimator.totalRunesForAssistant(assistant), 4);
      expect(
        estimator.totalRunesForAssistant(AssistantModel(name: '')),
        0,
      );
    });

    test('excludes raw memory-book marker metadata from the total', () {
      const marker = '# [chatai_deep.tavern_raw.v1] QUJDREVGRw==';
      final assistant = AssistantModel(
        name: '',
        memoryBook: '$marker\n关键词 => visible',
      );

      expect(
        estimator.totalRunesForAssistant(assistant),
        '关键词 => visible'.runes.length,
      );
    });

    test('counts imported results and the selected initial opening', () {
      final results = [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: '甲', prompt: '😀'),
        ),
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: '乙', description: 'e\u0301'),
        ),
      ];

      expect(
        estimator.totalRunesForResults(results, initialOpening: '房间😀'),
        8,
      );
    });

    test('reads body work from a task source and excludes JSON metadata', () {
      final payload = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(
              name: '角色',
              openingMessage: 'Hello',
              roleCardAssets: base64Encode(List<int>.filled(500, 65)),
              worldBookJson: jsonEncode({'metadata': 'Z' * 500}),
            ),
          ),
        ],
        initialOpening: '选中开场',
        promptConfigJson: jsonEncode({'metadata': 'P' * 500}),
      );
      final expected = '角色Hello选中开场'.runes.length;

      expect(
        estimator.tryTotalRunesForTaskSource(jsonEncode(payload.toJson())),
        expected,
      );
      expect(estimator.tryTotalRunesForTaskSource('{invalid'), isNull);
      expect(estimator.tryTotalRunesForTaskSource('[]'), isNull);
    });
  });

  group('TranslationWorkEstimator checkpoints', () {
    test('resolves completed and retained source with separators', () {
      final checkpoint = _checkpointWith(
        completed: const [('你好', '\n')],
        retained: const [('world', '')],
        pending: const [('later', '\n')],
      );

      final resolved = estimator.resolvedRunesForCheckpoint(checkpoint);

      expect(resolved, '你好\nworld'.runes.length);
    });

    test('a source-hash mismatch contributes zero', () {
      final checkpoint = _checkpointWith(
        completed: const [('done', '\n')],
        chunkSourceHash: 'different-source',
      );

      expect(estimator.resolvedRunesForCheckpoint(checkpoint), 0);
    });

    test('split and retry attempts do not double count source work', () {
      const planner = TranslationChunkPlanner();
      final source = List.filled(1000, '界').join();
      final planned = planner.plan(field: 'memoryBook', source: source);
      final split = planner.splitTimedOut(
        checkpoint: planned,
        chunkId: planned.chunks.single.chunk.id,
      );
      final completed = TranslationChunkCheckpoint(
        field: split.field,
        sourceHash: split.sourceHash,
        chunks: [
          for (var index = 0; index < split.chunks.length; index += 1)
            TranslationChunkState(
              chunk: split.chunks[index].chunk,
              status: index.isEven
                  ? TranslationChunkStatus.completed
                  : TranslationChunkStatus.retainedOriginal,
              translatedText: split.chunks[index].chunk.sourceText,
              attempts: 9 + index,
              lastErrorKind: TranslationFailureKind.totalTimeout,
            ),
        ],
      );

      expect(
        estimator.resolvedRunesForCheckpoint(completed),
        source.runes.length,
      );
    });
  });

  group('TranslationWorkEstimator persisted tasks', () {
    test('counts 33,322-rune raw world-book chunks at durable boundaries', () {
      const marker = '# [chatai_deep.tavern_raw.v1] V09STER1CT09L';
      final body = List.filled(33322, '界').join();
      final source = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: '', memoryBook: '$marker\n$body'),
        ),
      ]);
      final planned = const TranslationChunkPlanner().plan(
        field: 'memoryBook',
        source: body,
      );
      final checkpoint = _withCompletedPrefix(planned, 7);
      final task = _taskFor(
        source,
        checkpointVersion: TranslationChunkCheckpoint.currentVersion,
        fieldPayload: jsonEncode({
          'scope': 'role',
          'roleIndex': 0,
          'fields': {'memoryBook': '$marker\ntranslated'},
        }),
        chunkPayload: _chunkEnvelope({
          'role:0:memoryBook': checkpoint,
          'role:1:memoryBook': checkpoint,
          'opening:memoryBook': checkpoint,
        }),
      );

      final estimate = estimator.estimateTask(task);

      expect(estimate, isNotNull);
      expect(estimate!.usedFallback, isFalse);
      expect(estimate.totalRunes, 33322);
      expect(
        estimate.resolvedRunes,
        estimator.resolvedRunesForCheckpoint(checkpoint),
        reason: 'raw-marker memoryBook 不能仅凭 fieldPayload 计为全部完成',
      );
      expect(estimate.resolvedRunes, inInclusiveRange(7000, 9500));
    });

    test('uses completed role then field then chunks without double counting',
        () {
      final first = AssistantRoleCardImportResult(
        assistant: AssistantModel(
          name: 'Alice',
          description: 'Detective',
          prompt: 'First role prompt',
        ),
      );
      final second = AssistantRoleCardImportResult(
        assistant: AssistantModel(
          name: 'Bob',
          prompt: 'Second role prompt',
        ),
      );
      final source = StoryRoomTemplatePayload(results: [first, second]);
      final promptCheckpoint = _withCompletedPrefix(
        const TranslationChunkPlanner().plan(
          field: 'prompt',
          source: second.assistant.prompt,
        ),
        1,
      );
      final partial = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(
            name: '爱丽丝',
            description: '侦探',
            prompt: '第一位角色',
          ),
        ),
      ]);
      final task = _taskFor(
        source,
        roleIndex: 1,
        partialPayload: jsonEncode(partial.toJson()),
        fieldPayload: jsonEncode({
          'scope': 'role',
          'roleIndex': 1,
          'fields': {'name': '鲍勃', 'prompt': '第二位角色'},
        }),
        chunkPayload: _chunkEnvelope({
          'role:1:prompt': promptCheckpoint,
        }),
      );

      final estimate = estimator.estimateTask(task)!;
      final completedRoleRunes =
          estimator.totalRunesForAssistant(first.assistant);

      expect(estimate.usedFallback, isFalse);
      expect(
        estimate.resolvedRunes,
        completedRoleRunes +
            second.assistant.name.runes.length +
            second.assistant.prompt.runes.length,
        reason: 'field checkpoint 优先于同字段 chunk，不能重复相加',
      );
    });

    test('counts a committed opening and ignores malformed partial or fields',
        () {
      final source = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Alice'),
          ),
        ],
        initialOpening: 'Welcome 😀',
      );
      final openingCommitted = _taskFor(
        source,
        partialPayload: jsonEncode({
          ...StoryRoomTemplatePayload(
            results: const [],
            initialOpening: '欢迎 😀',
          ).toJson(),
          '_translationOpeningCompleted': true,
        }),
      );
      final malformed = _taskFor(
        source,
        partialPayload: '{broken',
        fieldPayload: '[not-a-field-envelope]',
      );

      expect(
        estimator.estimateTask(openingCommitted)?.resolvedRunes,
        source.initialOpening.runes.length,
      );
      expect(estimator.estimateTask(malformed)?.resolvedRunes, 0);
    });

    test('mismatched chunks resolve zero without invalidating the estimate',
        () {
      final source = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Alice', prompt: 'current source'),
        ),
      ]);
      final stale = const TranslationChunkPlanner().plan(
        field: 'prompt',
        source: 'stale source',
      );
      final task = _taskFor(
        source,
        chunkPayload: _chunkEnvelope({
          'role:0:prompt': _withCompletedPrefix(stale, 1),
        }),
      );

      final estimate = estimator.estimateTask(task);

      expect(estimate, isNotNull);
      expect(estimate?.usedFallback, isFalse);
      expect(estimate?.resolvedRunes, 0);
    });

    test(
        'ignores future-role checkpoints when malformed partial restarts role zero',
        () {
      final source = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Alice'),
        ),
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Bob', prompt: 'future prompt'),
        ),
      ]);
      final futurePrompt = _withCompletedPrefix(
        const TranslationChunkPlanner().plan(
          field: 'prompt',
          source: 'future prompt',
        ),
        1,
      );
      final task = _taskFor(
        source,
        roleIndex: 1,
        partialPayload: '{broken',
        fieldPayload: jsonEncode({
          'scope': 'role',
          'roleIndex': 1,
          'fields': {'name': '鲍勃'},
        }),
        chunkPayload: _chunkEnvelope({
          'role:1:prompt': futurePrompt,
        }),
      );

      expect(estimator.estimateTask(task)?.resolvedRunes, 0);
    });

    test(
        'unsupported checkpoint metadata uses fallback but corrupt current data is null',
        () {
      final source = StoryRoomTemplatePayload(results: [
        AssistantRoleCardImportResult(
          assistant: AssistantModel(name: 'Alice'),
        ),
      ]);
      final unsupported = _taskFor(
        source,
        checkpointVersion: TranslationChunkCheckpoint.currentVersion + 1,
        chunkPayload: jsonEncode({
          'version': TranslationChunkCheckpoint.currentVersion + 1,
          'checkpoints': const {},
        }),
      );
      final corruptCurrent = _taskFor(
        source,
        checkpointVersion: TranslationChunkCheckpoint.currentVersion,
        chunkPayload: jsonEncode({
          'version': TranslationChunkCheckpoint.currentVersion,
          'checkpoints': {
            'role:0:name': {'version': 1},
          },
        }),
      );

      final fallback = estimator.estimateTask(unsupported);

      expect(fallback, isNotNull);
      expect(fallback?.usedFallback, isTrue);
      expect(fallback?.totalRunes, 'Alice'.runes.length);
      expect(estimator.estimateTask(corruptCurrent), isNull);
    });

    test('rejects structurally empty sources exactly like the runner', () {
      final empty = StoryTemplateTranslationTaskModel(
        sourceTitle: 'empty source',
        sourcePayload: jsonEncode(
          const StoryRoomTemplatePayload(results: []).toJson(),
        ),
      );
      final skippedMalformed = StoryTemplateTranslationTaskModel(
        sourceTitle: 'malformed entries',
        sourcePayload: jsonEncode({
          'results': [null, 'not-a-role'],
        }),
      );

      expect(estimator.estimateTask(empty), isNull);
      expect(estimator.estimateTask(skippedMalformed), isNull);
    });
  });

  group('TranslationProgressAnchor', () {
    test('advances immediately when legacy progress is above canonical work',
        () {
      final anchor = TranslationProgressAnchor(
        totalRunes: 100,
        anchorResolvedRunes: 50,
        anchorProgress: 0.80,
      );

      expect(anchor.map(50), 0.80);
      expect(anchor.map(60), greaterThan(0.80));
      expect(anchor.map(75), closeTo(0.87, 0.000001));
    });

    test('clamps translating progress and invalid rune bounds', () {
      final anchor = TranslationProgressAnchor(
        totalRunes: 100,
        anchorResolvedRunes: 0,
        anchorProgress: 1,
      );
      final empty = TranslationProgressAnchor(
        totalRunes: 0,
        anchorResolvedRunes: 0,
        anchorProgress: 0,
      );

      expect(anchor.map(-20), 0.94);
      expect(anchor.map(200), 0.94);
      expect(empty.map(0), 0.04);
    });

    test('caps an exhausted anchor at translating maximum', () {
      final anchor = TranslationProgressAnchor(
        totalRunes: 10,
        anchorResolvedRunes: 10,
        anchorProgress: 0.7,
      );

      expect(anchor.map(10), 0.94);
    });
  });

  test('TranslationWorkEstimate clamps resolved runes to valid work', () {
    final over = TranslationWorkEstimate(
      totalRunes: 5,
      resolvedRunes: 9,
      usedFallback: false,
    );
    final under = TranslationWorkEstimate(
      totalRunes: -5,
      resolvedRunes: -2,
      usedFallback: true,
    );

    expect((over.totalRunes, over.resolvedRunes, over.usedFallback),
        (5, 5, false));
    expect((under.totalRunes, under.resolvedRunes, under.usedFallback),
        (0, 0, true));
  });

  test('formatRuneProgress formats body-weighted progress for task details',
      () {
    expect(formatRuneProgress(8420, 33322), '已完成 8,420/33,322 字');
  });
}

StoryTemplateTranslationTaskModel _taskFor(
  StoryRoomTemplatePayload source, {
  int roleIndex = 0,
  int checkpointVersion = TranslationChunkCheckpoint.currentVersion,
  String chunkPayload = '',
  String fieldPayload = '',
  String partialPayload = '',
}) =>
    StoryTemplateTranslationTaskModel(
      sourceTitle: 'estimate source',
      sourcePayload: jsonEncode(source.toJson()),
      roleIndex: roleIndex,
      roleTotal: source.results.length,
      checkpointVersion: checkpointVersion,
      chunkPayload: chunkPayload,
      fieldPayload: fieldPayload,
      partialPayload: partialPayload,
    );

String _chunkEnvelope(Map<String, TranslationChunkCheckpoint> checkpoints) =>
    jsonEncode({
      'version': TranslationChunkCheckpoint.currentVersion,
      'checkpoints': {
        for (final entry in checkpoints.entries)
          entry.key: entry.value.toJson(),
      },
    });

TranslationChunkCheckpoint _withCompletedPrefix(
  TranslationChunkCheckpoint checkpoint,
  int completedCount,
) =>
    TranslationChunkCheckpoint(
      field: checkpoint.field,
      sourceHash: checkpoint.sourceHash,
      chunks: [
        for (var index = 0; index < checkpoint.chunks.length; index += 1)
          TranslationChunkState(
            chunk: checkpoint.chunks[index].chunk,
            status: index < completedCount
                ? TranslationChunkStatus.completed
                : TranslationChunkStatus.pending,
            translatedText: index < completedCount
                ? checkpoint.chunks[index].chunk.sourceText
                : '',
            attempts: index < completedCount ? 1 : 0,
            lastErrorKind: null,
          ),
      ],
    );

TranslationChunkCheckpoint _checkpointWith({
  List<(String, String)> completed = const [],
  List<(String, String)> retained = const [],
  List<(String, String)> pending = const [],
  String checkpointSourceHash = 'same-source',
  String? chunkSourceHash,
}) {
  final entries = <(TranslationChunkStatus, String, String)>[
    for (final entry in completed)
      (TranslationChunkStatus.completed, entry.$1, entry.$2),
    for (final entry in retained)
      (TranslationChunkStatus.retainedOriginal, entry.$1, entry.$2),
    for (final entry in pending)
      (TranslationChunkStatus.pending, entry.$1, entry.$2),
  ];
  var cursor = 0;
  return TranslationChunkCheckpoint(
    field: 'memoryBook',
    sourceHash: checkpointSourceHash,
    chunks: [
      for (var index = 0; index < entries.length; index += 1)
        () {
          final entry = entries[index];
          final start = cursor;
          final end = start + entry.$2.runes.length;
          cursor = end + entry.$3.runes.length;
          final chunk = TranslationChunk(
            id: 'chunk-$index',
            index: index,
            sourceStartRune: start,
            sourceEndRune: end,
            sourceText: entry.$2,
            separatorAfter: entry.$3,
            sourceHash: chunkSourceHash ?? checkpointSourceHash,
            inputHash: 'input-$index',
          );
          return TranslationChunkState(
            chunk: chunk,
            status: entry.$1,
            translatedText:
                entry.$1 == TranslationChunkStatus.pending ? '' : entry.$2,
            attempts: index + 1,
            lastErrorKind: null,
          );
        }(),
    ],
  );
}
