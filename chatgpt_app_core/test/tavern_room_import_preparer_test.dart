import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/tavern_room_import_preparer.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('不翻译时直接返回原始角色卡结果', () async {
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Alice', memoryBook: 'English memory'),
    );
    final results = [result];
    var callbacks = 0;

    final prepared = await TavernRoomImportPreparer.prepare(
      results,
      translateToSimplifiedChinese: false,
      initialChunkCheckpoints: {
        '0:memoryBook': _completedCheckpoint(
          field: 'memoryBook',
          source: result.assistant.memoryBook,
          translated: '中文记忆',
        ),
      },
      onProgress: (_) => callbacks += 1,
      onFieldCheckpoint: (_, __, ___) async => callbacks += 1,
      onChunkCheckpoint: (_, __) async => callbacks += 1,
      complete: (_) async => throw StateError('不应调用翻译'),
    );

    expect(prepared, same(results));
    expect(prepared.single, same(result));
    expect(callbacks, 0);
  });

  test('翻译酒馆房间角色卡并同步 Tavern 备选开场', () async {
    const resource = AssistantRoleCardResource(
      type: 'icon',
      uri: 'embeded://assets/icon/main.png',
      name: 'main',
      ext: 'png',
      archivePath: 'assets/icon/main.png',
      mimeType: 'image/png',
      size: 3,
    );
    final source = AssistantRoleCardImportResult(
      assistant: AssistantModel(
        name: 'Alice',
        description: 'A detective.',
        prompt: 'Stay careful.',
        openingMessage: 'Good evening.',
        exampleDialogs: '''
[备选开场白]
She stands by the door.
''',
        roleCardAssets: '[{"name":"main"}]',
      ),
      avatarPngBytes: [1, 2, 3],
      avatarExtension: 'png',
      resources: const [resource],
      sourceName: 'alice.png',
      tavernMeta: const AssistantRoleCardTavernMeta(
        creator: 'card maker',
        alternateGreetings: ['She stands by the door.'],
      ),
    );
    final progresses = <TavernRoomImportProgress>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      [source],
      translateToSimplifiedChinese: true,
      onProgress: progresses.add,
      complete: (prompt) async {
        expect(prompt, contains('"name":"Alice"'));
        return jsonEncode({
          'name': '爱丽丝',
          'description': '一位侦探。',
          'prompt': '保持谨慎。',
          'openingMessage': '晚上好。',
          'exampleDialogs': '[备选开场白]\n她站在门边。',
          'memoryBook': '',
        });
      },
    );

    expect(prepared.single.assistant.name, '爱丽丝');
    expect(prepared.single.assistant.roleCardAssets, '[{"name":"main"}]');
    expect(prepared.single.avatarPngBytes, [1, 2, 3]);
    expect(prepared.single.avatarExtension, 'png');
    expect(prepared.single.resources, same(source.resources));
    expect(prepared.single.sourceName, 'alice.png');
    expect(prepared.single.tavernMeta?.creator, 'card maker');
    expect(prepared.single.tavernMeta?.alternateGreetings, ['她站在门边。']);
    expect(progresses.map((item) => item.stage), [
      '准备翻译角色',
      '提交整卡翻译',
      '解析整卡翻译',
      '已翻译',
    ]);
    expect(progresses[1].fieldLabel, '整卡');
    expect(progresses[1].fieldCurrent, 1);
    expect(progresses[1].fieldTotal, 1);
    expect(progresses.last.name, '爱丽丝');
  });

  test('翻译后世界书角色数减少时回退原 memoryBook', () async {
    final memoryBook = [
      'Alice => Name: Alice',
      'Type: character',
      'Personality: careful.',
      '',
      'Bob => Name: Bob',
      'Type: character',
      'Personality: brave.',
    ].join('\n');
    final source = AssistantRoleCardImportResult(
      assistant: AssistantModel(
        name: 'Party',
        description: 'Many characters.',
        prompt: 'Stay in scene.',
        memoryBook: memoryBook,
      ),
    );
    final progresses = <TavernRoomImportProgress>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      [source],
      translateToSimplifiedChinese: true,
      initialChunkCheckpoints: {
        '10:memoryBook': _completedCheckpoint(
          field: 'memoryBook',
          source: memoryBook,
          translated: '不应被 role 0 使用',
        ),
      },
      onProgress: progresses.add,
      complete: (prompt) async {
        return jsonEncode({
          'name': '队伍',
          'description': '许多角色。',
          'prompt': '保持场景。',
          'openingMessage': '',
          'exampleDialogs': '',
          'memoryBook': [
            'Alice => Name: Alice',
            'Type: character',
            'Personality: careful.',
          ].join('\n'),
        });
      },
    );

    expect(prepared.single.assistant.name, '队伍');
    expect(prepared.single.assistant.memoryBook, memoryBook);
    expect(
      progresses.map((item) => item.stage),
      contains('世界书角色数减少，已回退原文'),
    );
    final rollback = progresses.firstWhere(
      (item) => item.stage == '世界书角色数减少，已回退原文',
    );
    expect(rollback.detail, '2 -> 1');
    expect(rollback.fieldLabel, '世界书');
  });

  test('forwards stable role chunk keys and awaits before the next role',
      () async {
    final results = [
      AssistantRoleCardImportResult(
        assistant: AssistantModel(
          name: 'Role 0',
          memoryBook: 'Role zero English memory.',
        ),
      ),
      AssistantRoleCardImportResult(
        assistant: AssistantModel(
          name: 'Role 1',
          memoryBook: 'Role one English memory.',
        ),
      ),
    ];
    final checkpointEntered = Completer<void>();
    final releaseCheckpoint = Completer<void>();
    final sent = <String>[];
    final keys = <String>[];
    final fieldKeys = <String>[];
    final progresses = <TavernRoomImportProgress>[];

    final preparation = TavernRoomImportPreparer.prepare(
      results,
      translateToSimplifiedChinese: true,
      initialTranslatedFields: {
        0: _translatedFieldsExceptMemory(results[0].assistant),
        1: _translatedFieldsExceptMemory(results[1].assistant),
      },
      onChunkCheckpoint: (key, checkpoint) async {
        keys.add(key);
        expect(checkpoint.field, 'memoryBook');
        if (key == '0:memoryBook') {
          checkpointEntered.complete();
          await releaseCheckpoint.future;
        }
      },
      onFieldCheckpoint: (index, field, _) async {
        fieldKeys.add('$index:$field');
      },
      onProgress: progresses.add,
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({
          'memoryBook': value.replaceAll('English', '中文'),
        });
      },
    );

    await checkpointEntered.future;
    expect(sent, ['Role zero English memory.']);
    expect(keys, ['0:memoryBook']);
    expect(fieldKeys, isEmpty);

    releaseCheckpoint.complete();
    final prepared = await preparation;

    expect(sent, [
      'Role zero English memory.',
      'Role one English memory.',
    ]);
    expect(keys, ['0:memoryBook', '1:memoryBook']);
    expect(fieldKeys, ['0:memoryBook', '1:memoryBook']);
    expect(prepared[0].assistant.memoryBook, 'Role zero 中文 memory.');
    expect(prepared[1].assistant.memoryBook, 'Role one 中文 memory.');
    expect(
      progresses.any((progress) =>
          progress.current == 1 &&
          progress.name == 'Role 0' &&
          progress.fieldLabel == '世界书' &&
          progress.fieldCurrent == 6),
      isTrue,
    );
    expect(
      progresses.any((progress) =>
          progress.current == 2 &&
          progress.name == 'Role 1' &&
          progress.fieldLabel == '世界书' &&
          progress.fieldCurrent == 6),
      isTrue,
    );
  });

  test('chunk participant loss persists a retryable checkpoint before pausing',
      () async {
    final sourceMemoryBook = [
      'Alice => Name: Alice',
      'Type: character',
      'Personality: careful.',
      '',
      'Bob => Name: Bob',
      'Type: character',
      'Personality: brave.',
    ].join('\n');
    final translatedMemoryBook = [
      'Alice => Name: 爱丽丝',
      'Type: character',
      'Personality: 谨慎。',
      '',
      'Bob => Type: location',
      'Summary: 一处地点。',
    ].join('\n');
    final source = AssistantRoleCardImportResult(
      assistant: AssistantModel(
        name: 'Party',
        memoryBook: sourceMemoryBook,
      ),
    );
    final completedWithZeroAttempts = _completedCheckpoint(
      field: 'memoryBook',
      source: sourceMemoryBook,
      translated: translatedMemoryBook,
      attempts: 0,
    );
    final progresses = <TavernRoomImportProgress>[];
    final resetEntered = Completer<void>();
    final releaseReset = Completer<void>();
    TranslationChunkCheckpoint? lastMemoryBookCheckpoint;
    final persistedMemoryBookFields = <String>[];
    var resetPersisted = false;
    var futureSettled = false;

    final preparation = TavernRoomImportPreparer.prepare(
      [source],
      translateToSimplifiedChinese: true,
      initialTranslatedFields: {
        0: _translatedFieldsExceptMemory(source.assistant),
      },
      initialChunkCheckpoints: {
        '0:memoryBook': completedWithZeroAttempts,
      },
      onProgress: progresses.add,
      onFieldCheckpoint: (_, field, value) async {
        if (field == 'memoryBook') persistedMemoryBookFields.add(value);
      },
      onChunkCheckpoint: (key, checkpoint) async {
        if (key != '0:memoryBook') return;
        lastMemoryBookCheckpoint = checkpoint;
        final retryable = checkpoint.chunks.every(
          (state) =>
              state.status == TranslationChunkStatus.pending &&
              state.translatedText.isEmpty &&
              state.lastErrorKind == TranslationFailureKind.invalidOutput,
        );
        if (!retryable) return;
        if (!resetEntered.isCompleted) resetEntered.complete();
        await releaseReset.future;
        resetPersisted = true;
      },
      complete: (_) => throw StateError('completed chunk must not be resent'),
    );
    unawaited(preparation.then<void>(
      (_) => futureSettled = true,
      onError: (Object _, StackTrace __) => futureSettled = true,
    ));

    await resetEntered.future.timeout(const Duration(seconds: 1));
    expect(futureSettled, isFalse);
    expect(resetPersisted, isFalse);
    releaseReset.complete();

    await expectLater(
      preparation,
      throwsA(
        isA<TranslationWorkPaused>().having(
          (error) => error.failure.kind,
          'kind',
          TranslationFailureKind.invalidOutput,
        ),
      ),
    );

    expect(resetPersisted, isTrue);
    expect(persistedMemoryBookFields, isEmpty);
    expect(lastMemoryBookCheckpoint, isNotNull);
    expect(
      lastMemoryBookCheckpoint!.chunks.every(
        (state) => state.status != TranslationChunkStatus.retainedOriginal,
      ),
      isTrue,
    );
    expect(
      lastMemoryBookCheckpoint!.chunks.every((state) => state.attempts == 0),
      isTrue,
    );
    expect(
      progresses.map((progress) => progress.stage),
      isNot(contains('世界书角色数减少，已回退原文')),
    );
    expect(
        progresses.map((progress) => progress.stage), isNot(contains('已翻译')));
  });

  test('resume skips role zero completed chunks but still sends role one',
      () async {
    const role0Source = 'Role zero English memory.';
    const role1Source = 'Role one English memory.';
    final results = [
      AssistantRoleCardImportResult(
        assistant: AssistantModel(name: 'Role 0', memoryBook: role0Source),
      ),
      AssistantRoleCardImportResult(
        assistant: AssistantModel(name: 'Role 1', memoryBook: role1Source),
      ),
    ];
    final role0Completed = _completedCheckpoint(
      field: 'memoryBook',
      source: role0Source,
      translated: 'Role zero 中文 memory.',
    );
    final role1Collision = _completedCheckpoint(
      field: 'memoryBook',
      source: role1Source,
      translated: 'wrong role ten translation',
    );
    final role1WrongField = _completedCheckpoint(
      field: 'description',
      source: role1Source,
      translated: 'wrong field translation',
    );
    final sent = <String>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      results,
      translateToSimplifiedChinese: true,
      initialTranslatedFields: {
        0: _translatedFieldsExceptMemory(results[0].assistant),
        1: _translatedFieldsExceptMemory(results[1].assistant),
      },
      initialChunkCheckpoints: {
        '0:memoryBook': role0Completed,
        '1:memoryBook': role1WrongField,
        '10:memoryBook': role1Collision,
      },
      onChunkCheckpoint: (_, __) async {},
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({
          'memoryBook': value.replaceAll('English', '中文'),
        });
      },
    );

    expect(sent, [role1Source]);
    expect(prepared[0].assistant.memoryBook, 'Role zero 中文 memory.');
    expect(prepared[1].assistant.memoryBook, 'Role one 中文 memory.');
  });

  test('pending chunk checkpoint outranks a bad legacy memoryBook on resume',
      () async {
    final sourceMemoryBook = [
      'Alice => Name: Alice',
      'Type: character',
      'Personality: careful.',
      '',
      'Bob => Name: Bob',
      'Type: character',
      'Personality: brave.',
    ].join('\n');
    const planner = TranslationChunkPlanner();
    final planned = planner.plan(
      field: 'memoryBook',
      source: sourceMemoryBook,
    );
    final reset = TranslationChunkCheckpoint(
      field: planned.field,
      sourceHash: planned.sourceHash,
      chunks: [
        for (final state in planned.chunks)
          TranslationChunkState(
            chunk: state.chunk,
            status: TranslationChunkStatus.pending,
            translatedText: '',
            attempts: 1,
            lastErrorKind: TranslationFailureKind.invalidOutput,
          ),
      ],
    );
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Party', memoryBook: sourceMemoryBook),
    );
    final sent = <String>[];
    final persistedFields = <String>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      [result],
      translateToSimplifiedChinese: true,
      initialTranslatedFields: {
        0: {
          ..._translatedFieldsExceptMemory(result.assistant),
          'memoryBook': '坏 legacy memoryBook',
        },
      },
      initialChunkCheckpoints: {'0:memoryBook': reset},
      onChunkCheckpoint: (_, __) async {},
      onFieldCheckpoint: (_, field, value) async {
        if (field == 'memoryBook') persistedFields.add(value);
      },
      complete: (prompt) async {
        expect(prompt, contains('修复'));
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({
          'memoryBook':
              value.replaceAll('careful', '谨慎').replaceAll('brave', '勇敢'),
        });
      },
    );

    expect(sent, isNotEmpty);
    expect(prepared.single.assistant.memoryBook, contains('谨慎'));
    expect(prepared.single.assistant.memoryBook, contains('勇敢'));
    expect(prepared.single.assistant.memoryBook, isNot(contains('坏 legacy')));
    expect(persistedFields, [prepared.single.assistant.memoryBook]);
  });

  test('source hash mismatch replans the current role source', () async {
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(
        name: 'Role',
        memoryBook: 'new English memory',
      ),
    );
    final stale = _completedCheckpoint(
      field: 'memoryBook',
      source: 'old English memory',
      translated: '过期译文',
    );
    final sent = <String>[];

    final prepared = await TavernRoomImportPreparer.prepare(
      [result],
      translateToSimplifiedChinese: true,
      initialTranslatedFields: {
        0: _translatedFieldsExceptMemory(result.assistant),
      },
      initialChunkCheckpoints: {'0:memoryBook': stale},
      onChunkCheckpoint: (_, __) async {},
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({
          'memoryBook': value.replaceAll('English', '中文'),
        });
      },
    );

    expect(sent, ['new English memory']);
    expect(prepared.single.assistant.memoryBook, 'new 中文 memory');
    expect(prepared.single.assistant.memoryBook, isNot(contains('过期译文')));
  });

  test('forwards retry policy and propagates deferred work', () async {
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Role', memoryBook: 'English memory'),
    );
    final startedAt = DateTime.now();

    try {
      await TavernRoomImportPreparer.prepare(
        [result],
        translateToSimplifiedChinese: true,
        initialTranslatedFields: {
          0: _translatedFieldsExceptMemory(result.assistant),
        },
        onChunkCheckpoint: (_, __) async {},
        retryPolicy: const TranslationRetryPolicy(
          random: _FixedRandom(0.5),
        ),
        complete: (_) => throw const TranslationRequestFailure(
          kind: TranslationFailureKind.rateLimited,
          safeCode: 'rate_limited',
        ),
      );
      fail('expected deferred work');
    } on TranslationWorkDeferred catch (error) {
      final finishedAt = DateTime.now();
      expect(error.failure.kind, TranslationFailureKind.rateLimited);
      expect(
        error.nextRunAt.isAfter(
          startedAt.add(const Duration(milliseconds: 900)),
        ),
        isTrue,
      );
      expect(
        error.nextRunAt.isBefore(
          finishedAt.add(const Duration(milliseconds: 1100)),
        ),
        isTrue,
      );
    }
  });

  test('propagates paused work without retaining the source', () async {
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Role', memoryBook: 'English memory'),
    );

    await expectLater(
      TavernRoomImportPreparer.prepare(
        [result],
        translateToSimplifiedChinese: true,
        initialTranslatedFields: {
          0: _translatedFieldsExceptMemory(result.assistant),
        },
        onChunkCheckpoint: (_, __) async {},
        complete: (_) => throw const TranslationRequestFailure(
          kind: TranslationFailureKind.invalidRequest,
          safeCode: 'invalid_request',
        ),
      ),
      throwsA(
        isA<TranslationWorkPaused>().having(
          (error) => error.failure.kind,
          'kind',
          TranslationFailureKind.invalidRequest,
        ),
      ),
    );
  });

  test('propagates typed cancellation without retaining the source', () async {
    final result = AssistantRoleCardImportResult(
      assistant: AssistantModel(name: 'Role', memoryBook: 'English memory'),
    );

    await expectLater(
      TavernRoomImportPreparer.prepare(
        [result],
        translateToSimplifiedChinese: true,
        initialTranslatedFields: {
          0: _translatedFieldsExceptMemory(result.assistant),
        },
        onChunkCheckpoint: (_, __) async {},
        complete: (_) => throw const TranslationRequestFailure(
          kind: TranslationFailureKind.cancelled,
          safeCode: 'cancelled',
        ),
      ),
      throwsA(isA<RoleCardTranslationCancelled>()),
    );
  });
}

Map<String, String> _translatedFieldsExceptMemory(AssistantModel assistant) => {
      'name': assistant.name,
      'description': assistant.description,
      'prompt': assistant.prompt,
      'openingMessage': assistant.openingMessage,
      'exampleDialogs': assistant.exampleDialogs,
    };

TranslationChunkCheckpoint _completedCheckpoint({
  required String field,
  required String source,
  required String translated,
  int attempts = 1,
}) {
  const planner = TranslationChunkPlanner();
  final planned = planner.plan(field: field, source: source);
  expect(planned.chunks, hasLength(1));
  return TranslationChunkCheckpoint(
    field: field,
    sourceHash: planned.sourceHash,
    chunks: [
      TranslationChunkState(
        chunk: planned.chunks.single.chunk,
        status: TranslationChunkStatus.completed,
        translatedText: translated,
        attempts: attempts,
        lastErrorKind: null,
      ),
    ],
  );
}

final class _FixedRandom implements Random {
  final double value;

  const _FixedRandom(this.value);

  @override
  bool nextBool() => value >= 0.5;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor().clamp(0, max - 1);
}
