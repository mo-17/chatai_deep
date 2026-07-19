import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/role_card_translation_fields.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/application/translation_work_estimator.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
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
}

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
