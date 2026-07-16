import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const planner = TranslationChunkPlanner();

  group('TranslationChunkPlanner.plan', () {
    test('plans 33,322 world-book runes near 900 without exceeding 1200', () {
      final source = _worldBookSource(33322);

      final checkpoint = planner.plan(field: 'memoryBook', source: source);

      expect(source.runes.length, 33322);
      expect(checkpoint.matchesSource('memoryBook', source), isTrue);
      expect(_reconstruct(checkpoint), source);
      _expectSequential(checkpoint);
      final lengths = checkpoint.chunks
          .map((state) => state.chunk.sourceText.runes.length)
          .where((length) => length > 0)
          .toList();
      expect(lengths, isNotEmpty);
      expect(lengths.every((length) => length <= 1200), isTrue);
      expect(
        lengths.where((length) => length >= 800 && length <= 1000).length,
        greaterThanOrEqualTo((lengths.length * 0.6).floor()),
      );
    });

    test('uses the 1800 target and 2400 hard limit for other fields', () {
      final source = List.generate(
        12,
        (index) => '段落$index：${_repeat('文', 430)}。',
      ).join('\n\n');

      final checkpoint = planner.plan(field: 'prompt', source: source);

      expect(_reconstruct(checkpoint), source);
      expect(
        checkpoint.chunks.every(
          (state) => state.chunk.sourceText.runes.length <= 2400,
        ),
        isTrue,
      );
      expect(
        checkpoint.chunks
            .take(checkpoint.chunks.length - 1)
            .any((state) => state.chunk.sourceText.runes.length >= 1500),
        isTrue,
      );
    });

    test('preserves emoji, CRLF, spaces and exact separator order', () {
      final source = [
        '[entry:emoji]\r\n',
        '${_repeat('😀', 460)}。  \r\n\r\n',
        '[entry:spaces]\r\n',
        '${_repeat('甲', 720)}！\t \r\n',
        '尾部 😀  \r\n',
      ].join();

      final checkpoint = planner.plan(field: 'memoryBook', source: source);

      expect(_reconstruct(checkpoint), source);
      _expectSequential(checkpoint);
      for (final state in checkpoint.chunks) {
        expect(state.chunk.sourceText, isNot(contains('\uFFFD')));
        expect(state.chunk.separatorAfter, isNot(contains('\uFFFD')));
      }
    });

    test('represents empty and separator-only sources losslessly', () {
      final empty = planner.plan(field: 'memoryBook', source: '');
      final separators = planner.plan(
        field: 'memoryBook',
        source: '\r\n  \t\r\n',
      );

      expect(empty.chunks, hasLength(1));
      expect(empty.chunks.single.chunk.sourceText, isEmpty);
      expect(empty.chunks.single.chunk.separatorAfter, isEmpty);
      expect(_reconstruct(empty), isEmpty);
      expect(separators.chunks, hasLength(1));
      expect(separators.chunks.single.chunk.sourceText, isEmpty);
      expect(separators.chunks.single.chunk.separatorAfter, '\r\n  \t\r\n');
      expect(_reconstruct(separators), '\r\n  \t\r\n');
      _expectSequential(empty);
      _expectSequential(separators);
    });

    test('prefers a world-book marker boundary and stores its separator', () {
      final firstEntry = '[entry:first]\n${_repeat('甲', 850)}';
      final secondEntry = '[entry:second]\n${_repeat('乙', 500)}';
      final source = '$firstEntry\r\n\r\n$secondEntry';

      final checkpoint = planner.plan(field: 'memoryBook', source: source);

      expect(checkpoint.chunks, hasLength(2));
      expect(checkpoint.chunks.first.chunk.sourceText, firstEntry);
      expect(checkpoint.chunks.first.chunk.separatorAfter, '\r\n\r\n');
      expect(
        checkpoint.chunks.last.chunk.sourceText,
        startsWith('[entry:second]'),
      );
      expect(_reconstruct(checkpoint), source);
    });

    test('prefers an early entry marker over a later hard cut', () {
      final firstEntry = '[entry:first]${_repeat('甲', 320)}';
      final secondEntry = '[entry:second]${_repeat('乙', 1080)}';
      final source = '$firstEntry\n$secondEntry';

      final checkpoint = planner.plan(field: 'memoryBook', source: source);

      expect(checkpoint.chunks, hasLength(2));
      expect(checkpoint.chunks.first.chunk.sourceText, firstEntry);
      expect(checkpoint.chunks.first.chunk.separatorAfter, '\n');
      expect(checkpoint.chunks.last.chunk.sourceText, secondEntry);
      expect(_reconstruct(checkpoint), source);
    });

    test('entry-marker priority outranks nearer whitespace', () {
      final firstEntry = '[entry:first]${_repeat('甲', 320)}';
      final secondEntry =
          '[entry:second]${_repeat('乙', 550)} ${_repeat('丙', 600)}';
      final source = '$firstEntry\n$secondEntry';

      final checkpoint = planner.plan(field: 'memoryBook', source: source);

      expect(checkpoint.chunks.first.chunk.sourceText, firstEntry);
      expect(checkpoint.chunks.first.chunk.separatorAfter, '\n');
      expect(checkpoint.chunks[1].chunk.sourceText, secondEntry);
      expect(_reconstruct(checkpoint), source);
    });

    test('falls back to hard rune cuts for overlong single lines', () {
      final worldBook = _repeat('界', 2501);
      final other = _repeat('文', 4901);

      final worldPlan = planner.plan(field: 'memoryBook', source: worldBook);
      final otherPlan = planner.plan(field: 'exampleDialogs', source: other);

      expect(
        worldPlan.chunks.map((state) => state.chunk.sourceText.runes.length),
        [1200, 1200, 101],
      );
      expect(
        otherPlan.chunks.map((state) => state.chunk.sourceText.runes.length),
        [2400, 2400, 101],
      );
      expect(_reconstruct(worldPlan), worldBook);
      expect(_reconstruct(otherPlan), other);
    });

    test('repeated planning is stable and repeated paragraphs have unique ids',
        () {
      final paragraph = '${_repeat('重复', 230)}。';
      final source = List.filled(10, paragraph).join('\n\n');

      final first = planner.plan(field: 'memoryBook', source: source);
      final second = planner.plan(field: 'memoryBook', source: source);

      expect(second.toJson(), first.toJson());
      expect(
        first.chunks.map((state) => state.chunk.id).toSet(),
        hasLength(first.chunks.length),
      );
      expect(
        first.chunks.map((state) => state.chunk.inputHash).toSet(),
        hasLength(first.chunks.length),
      );
    });

    test('matchesSource rejects field and source mismatches', () {
      final checkpoint = planner.plan(
        field: 'memoryBook',
        source: 'alpha\r\nbeta',
      );

      expect(checkpoint.matchesSource('memoryBook', 'alpha\r\nbeta'), isTrue);
      expect(checkpoint.matchesSource('prompt', 'alpha\r\nbeta'), isFalse);
      expect(checkpoint.matchesSource('memoryBook', 'alpha\nbeta'), isFalse);
      expect(checkpoint.matchesSource('memoryBook', 'alpha\r\nBeta'), isFalse);
    });
  });

  group('TranslationChunkCheckpoint JSON', () {
    test('strict roundtrip preserves status, translation, attempts and error',
        () {
      final planned = planner.plan(
        field: 'memoryBook',
        source: _worldBookSource(2600),
      );
      final states = <TranslationChunkState>[
        TranslationChunkState(
          chunk: planned.chunks[0].chunk,
          status: TranslationChunkStatus.completed,
          translatedText: '第一块译文',
          attempts: 2,
          lastErrorKind: TranslationFailureKind.network,
        ),
        TranslationChunkState(
          chunk: planned.chunks[1].chunk,
          status: TranslationChunkStatus.retainedOriginal,
          translatedText: planned.chunks[1].chunk.sourceText,
          attempts: 3,
          lastErrorKind: TranslationFailureKind.invalidOutput,
        ),
        for (final state in planned.chunks.skip(2))
          TranslationChunkState(
            chunk: state.chunk,
            status: TranslationChunkStatus.pending,
            translatedText: '',
            attempts: 1,
            lastErrorKind: TranslationFailureKind.idleTimeout,
          ),
      ];
      final checkpoint = TranslationChunkCheckpoint(
        field: planned.field,
        sourceHash: planned.sourceHash,
        chunks: states,
      );

      final encoded = checkpoint.toJson();
      final restored = TranslationChunkCheckpoint.fromJson(
        jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>,
      );

      expect(restored.toJson(), encoded);
      expect(restored.chunks[0].status, TranslationChunkStatus.completed);
      expect(restored.chunks[0].translatedText, '第一块译文');
      expect(restored.chunks[0].attempts, 2);
      expect(restored.chunks[0].lastErrorKind, TranslationFailureKind.network);
      expect(
          restored.chunks[1].status, TranslationChunkStatus.retainedOriginal);
      expect(restored.chunks[1].lastErrorKind,
          TranslationFailureKind.invalidOutput);
      expect(_reconstruct(restored), _reconstruct(planned));
    });

    test('rejects wrong version, enum, types, indexes, offsets and hashes', () {
      final checkpoint = planner.plan(
        field: 'memoryBook',
        source: _worldBookSource(2200),
      );
      final valid = checkpoint.toJson();
      final corruptions = <Map<String, dynamic> Function()>[
        () => _mutate(valid, (json) => json['version'] = 2),
        () => _mutate(valid, (json) => json['field'] = 7),
        () => _mutate(valid, (json) => json['sourceHash'] = 'not-a-hash'),
        () => _mutate(valid, (json) {
              _state(json, 0)['status'] = 'done';
            }),
        () => _mutate(valid, (json) {
              _state(json, 0)['attempts'] = -1;
            }),
        () => _mutate(valid, (json) {
              _state(json, 0)['lastErrorKind'] = 'madeUpFailure';
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['index'] = 4;
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['index'] = 0.0;
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['sourceStartRune'] = 1;
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['sourceEndRune'] = 1;
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['sourceText'] = 'tampered';
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['separatorAfter'] = '\nchanged';
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['sourceHash'] = List.filled(64, '0').join();
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['inputHash'] = List.filled(64, '0').join();
            }),
        () => _mutate(valid, (json) {
              _chunk(json, 0)['id'] = List.filled(64, '0').join();
            }),
        () => _mutate(valid, (json) => json['unexpected'] = true),
      ];

      for (final corrupt in corruptions) {
        expect(
          () => TranslationChunkCheckpoint.fromJson(corrupt()),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });

  group('TranslationChunkPlanner.splitTimedOut', () {
    test('splits only the selected pending world-book parent losslessly', () {
      final checkpoint = planner.plan(
        field: 'memoryBook',
        source: _repeat('界', 1000),
      );
      final parent = checkpoint.chunks.single;

      final split = planner.splitTimedOut(
        checkpoint: checkpoint,
        chunkId: parent.chunk.id,
      );

      expect(split.chunks.length, greaterThanOrEqualTo(2));
      expect(_reconstruct(split), _reconstruct(checkpoint));
      expect(split.matchesSource('memoryBook', _repeat('界', 1000)), isTrue);
      expect(
        split.chunks.every(
          (state) =>
              state.status == TranslationChunkStatus.pending &&
              state.translatedText.isEmpty &&
              state.attempts == 0 &&
              state.lastErrorKind == null &&
              state.chunk.sourceText.runes.length <
                  parent.chunk.sourceText.runes.length,
        ),
        isTrue,
      );
      _expectSequential(split);
    });

    test('uses strict 400 and 800 split thresholds', () {
      final worldAt = planner.plan(
        field: 'memoryBook',
        source: _repeat('界', 400),
      );
      final worldAbove = planner.plan(
        field: 'memoryBook',
        source: _repeat('界', 401),
      );
      final otherAt = planner.plan(
        field: 'prompt',
        source: _repeat('文', 800),
      );
      final otherAbove = planner.plan(
        field: 'prompt',
        source: _repeat('文', 801),
      );

      expect(
        () => planner.splitTimedOut(
          checkpoint: worldAt,
          chunkId: worldAt.chunks.single.chunk.id,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        _reconstruct(planner.splitTimedOut(
          checkpoint: worldAbove,
          chunkId: worldAbove.chunks.single.chunk.id,
        )),
        _repeat('界', 401),
      );
      expect(
        () => planner.splitTimedOut(
          checkpoint: otherAt,
          chunkId: otherAt.chunks.single.chunk.id,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        _reconstruct(planner.splitTimedOut(
          checkpoint: otherAbove,
          chunkId: otherAbove.chunks.single.chunk.id,
        )),
        _repeat('文', 801),
      );
    });

    test('rejects unknown, completed and retained-original chunk ids', () {
      final planned = planner.plan(
        field: 'memoryBook',
        source: _repeat('界', 1000),
      );
      TranslationChunkCheckpoint withStatus(TranslationChunkStatus status) =>
          TranslationChunkCheckpoint(
            field: planned.field,
            sourceHash: planned.sourceHash,
            chunks: [
              TranslationChunkState(
                chunk: planned.chunks.single.chunk,
                status: status,
                translatedText: status == TranslationChunkStatus.completed
                    ? '译文'
                    : planned.chunks.single.chunk.sourceText,
                attempts: 1,
                lastErrorKind: TranslationFailureKind.totalTimeout,
              ),
            ],
          );

      expect(
        () => planner.splitTimedOut(
          checkpoint: planned,
          chunkId: 'missing',
        ),
        throwsA(isA<StateError>()),
      );
      for (final status in [
        TranslationChunkStatus.completed,
        TranslationChunkStatus.retainedOriginal,
      ]) {
        final checkpoint = withStatus(status);
        expect(
          () => planner.splitTimedOut(
            checkpoint: checkpoint,
            chunkId: checkpoint.chunks.single.chunk.id,
          ),
          throwsA(isA<StateError>()),
        );
      }
    });

    test('preserves untouched states, ids and hashes while reindexing', () {
      final planned = planner.plan(
        field: 'memoryBook',
        source: _worldBookSource(2800),
      );
      expect(planned.chunks.length, greaterThanOrEqualTo(3));
      final states = [
        TranslationChunkState(
          chunk: planned.chunks[0].chunk,
          status: TranslationChunkStatus.completed,
          translatedText: '已完成',
          attempts: 2,
          lastErrorKind: TranslationFailureKind.network,
        ),
        TranslationChunkState(
          chunk: planned.chunks[1].chunk,
          status: TranslationChunkStatus.pending,
          translatedText: '',
          attempts: 1,
          lastErrorKind: TranslationFailureKind.idleTimeout,
        ),
        TranslationChunkState(
          chunk: planned.chunks[2].chunk,
          status: TranslationChunkStatus.retainedOriginal,
          translatedText: planned.chunks[2].chunk.sourceText,
          attempts: 4,
          lastErrorKind: TranslationFailureKind.invalidOutput,
        ),
        ...planned.chunks.skip(3),
      ];
      final checkpoint = TranslationChunkCheckpoint(
        field: planned.field,
        sourceHash: planned.sourceHash,
        chunks: states,
      );

      final split = planner.splitTimedOut(
        checkpoint: checkpoint,
        chunkId: states[1].chunk.id,
      );

      final first = split.chunks.singleWhere(
        (state) => state.chunk.id == states[0].chunk.id,
      );
      final retained = split.chunks.singleWhere(
        (state) => state.chunk.id == states[2].chunk.id,
      );
      expect(first.status, states[0].status);
      expect(first.translatedText, states[0].translatedText);
      expect(first.attempts, states[0].attempts);
      expect(first.lastErrorKind, states[0].lastErrorKind);
      expect(first.chunk.inputHash, states[0].chunk.inputHash);
      expect(first.chunk.sourceHash, states[0].chunk.sourceHash);
      expect(retained.status, states[2].status);
      expect(retained.translatedText, states[2].translatedText);
      expect(retained.attempts, states[2].attempts);
      expect(retained.lastErrorKind, states[2].lastErrorKind);
      expect(retained.chunk.inputHash, states[2].chunk.inputHash);
      expect(retained.chunk.sourceHash, states[2].chunk.sourceHash);
      expect(_reconstruct(split), _reconstruct(checkpoint));
      _expectSequential(split);
    });
  });
}

String _worldBookSource(int runeLength) {
  final buffer = StringBuffer();
  var index = 0;
  while (buffer.toString().runes.length < runeLength) {
    buffer
      ..write('[entry:$index]\r\n')
      ..write(_repeat(index.isEven ? '界' : '域', 900))
      ..write('。\r\n\r\n');
    index += 1;
  }
  return String.fromCharCodes(buffer.toString().runes.take(runeLength));
}

String _repeat(String value, int count) => List.filled(count, value).join();

String _reconstruct(TranslationChunkCheckpoint checkpoint) => checkpoint.chunks
    .map((state) => '${state.chunk.sourceText}${state.chunk.separatorAfter}')
    .join();

void _expectSequential(TranslationChunkCheckpoint checkpoint) {
  var cursor = 0;
  for (var index = 0; index < checkpoint.chunks.length; index += 1) {
    final chunk = checkpoint.chunks[index].chunk;
    expect(chunk.index, index);
    expect(chunk.sourceStartRune, cursor);
    expect(
      chunk.sourceEndRune,
      chunk.sourceStartRune + chunk.sourceText.runes.length,
    );
    expect(chunk.sourceHash, checkpoint.sourceHash);
    expect(chunk.id, chunk.inputHash);
    expect(chunk.sourceHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(chunk.inputHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    cursor = chunk.sourceEndRune + chunk.separatorAfter.runes.length;
  }
  expect(cursor, _reconstruct(checkpoint).runes.length);
}

Map<String, dynamic> _mutate(
  Map<String, dynamic> source,
  void Function(Map<String, dynamic>) mutate,
) {
  final copy = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  mutate(copy);
  return copy;
}

Map<String, dynamic> _state(Map<String, dynamic> json, int index) =>
    (json['chunks'] as List<dynamic>)[index] as Map<String, dynamic>;

Map<String, dynamic> _chunk(Map<String, dynamic> json, int index) =>
    _state(json, index)['chunk'] as Map<String, dynamic>;
