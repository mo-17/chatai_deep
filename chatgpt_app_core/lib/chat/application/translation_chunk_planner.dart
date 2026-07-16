import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:crypto/crypto.dart';

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

  const TranslationChunk({
    required this.id,
    required this.index,
    required this.sourceStartRune,
    required this.sourceEndRune,
    required this.sourceText,
    required this.separatorAfter,
    required this.sourceHash,
    required this.inputHash,
  });

  TranslationChunk _withIndex(int value) => TranslationChunk(
        id: id,
        index: value,
        sourceStartRune: sourceStartRune,
        sourceEndRune: sourceEndRune,
        sourceText: sourceText,
        separatorAfter: separatorAfter,
        sourceHash: sourceHash,
        inputHash: inputHash,
      );
}

final class TranslationChunkState {
  final TranslationChunk chunk;
  final TranslationChunkStatus status;
  final String translatedText;
  final int attempts;
  final TranslationFailureKind? lastErrorKind;

  const TranslationChunkState({
    required this.chunk,
    required this.status,
    required this.translatedText,
    required this.attempts,
    required this.lastErrorKind,
  });

  TranslationChunkState _withChunk(TranslationChunk value) =>
      TranslationChunkState(
        chunk: value,
        status: status,
        translatedText: translatedText,
        attempts: attempts,
        lastErrorKind: lastErrorKind,
      );
}

final class TranslationChunkCheckpoint {
  static const currentVersion = 1;

  final String field;
  final String sourceHash;
  final List<TranslationChunkState> chunks;

  TranslationChunkCheckpoint({
    required this.field,
    required this.sourceHash,
    required List<TranslationChunkState> chunks,
  }) : chunks = List<TranslationChunkState>.unmodifiable(chunks);

  bool matchesSource(String field, String source) =>
      this.field == field && sourceHash == _hashSource(source);

  Map<String, dynamic> toJson() {
    final validationError = _validateCheckpoint(this);
    if (validationError != null) throw StateError(validationError);
    return {
      'version': currentVersion,
      'field': field,
      'sourceHash': sourceHash,
      'chunks': chunks.map(_stateToJson).toList(growable: false),
    };
  }

  factory TranslationChunkCheckpoint.fromJson(Map<String, dynamic> json) {
    _expectKeys(
      json,
      const {'version', 'field', 'sourceHash', 'chunks'},
      'checkpoint',
    );
    if (json['version'] is! int || json['version'] != currentVersion) {
      throw const FormatException('不支持的翻译分块 checkpoint 版本');
    }
    final field = _nonEmptyString(json['field'], 'field');
    final sourceHash = _hashString(json['sourceHash'], 'sourceHash');
    final rawChunks = json['chunks'];
    if (rawChunks is! List || rawChunks.isEmpty) {
      throw const FormatException('chunks 必须是非空数组');
    }
    final chunks = <TranslationChunkState>[];
    for (var index = 0; index < rawChunks.length; index += 1) {
      chunks.add(_stateFromJson(rawChunks[index], index));
    }
    final checkpoint = TranslationChunkCheckpoint(
      field: field,
      sourceHash: sourceHash,
      chunks: chunks,
    );
    final validationError = _validateCheckpoint(checkpoint);
    if (validationError != null) throw FormatException(validationError);
    return checkpoint;
  }
}

final class TranslationChunkPlanner {
  const TranslationChunkPlanner();

  TranslationChunkCheckpoint plan({
    required String field,
    required String source,
  }) {
    if (field.trim().isEmpty) {
      throw ArgumentError.value(field, 'field', '不能为空');
    }
    final sourceHash = _hashSource(source);
    final config = _configFor(field);
    final runes = source.runes.toList(growable: false);
    final chunks = _planRunes(
      field: field,
      runes: runes,
      sourceHash: sourceHash,
      config: config,
    );
    final checkpoint = TranslationChunkCheckpoint(
      field: field,
      sourceHash: sourceHash,
      chunks: chunks,
    );
    final validationError = _validateCheckpoint(checkpoint);
    if (validationError != null) throw StateError(validationError);
    return checkpoint;
  }

  TranslationChunkCheckpoint splitTimedOut({
    required TranslationChunkCheckpoint checkpoint,
    required String chunkId,
  }) {
    final validationError = _validateCheckpoint(checkpoint);
    if (validationError != null) throw StateError(validationError);

    final parentIndex = checkpoint.chunks.indexWhere(
      (state) => state.chunk.id == chunkId,
    );
    if (parentIndex < 0) {
      throw StateError('找不到待拆分的翻译块');
    }
    final parent = checkpoint.chunks[parentIndex];
    if (parent.status != TranslationChunkStatus.pending) {
      throw StateError('只能拆分 pending 翻译块');
    }

    final config = _configFor(checkpoint.field);
    final parentRunes = parent.chunk.sourceText.runes.toList(growable: false);
    if (parentRunes.length <= config.splitThreshold) {
      throw StateError('翻译块已达到 timeout 细分下限');
    }

    final desired = parentRunes.length ~/ 2;
    final cut = _chooseBoundary(
      parentRunes,
      start: 0,
      maxEnd: parentRunes.length - 1,
      desiredEnd: desired,
    );
    final safeCut = _clampInt(cut, 1, parentRunes.length - 1);
    final firstRunes = parentRunes.sublist(0, safeCut);
    final secondRunes = parentRunes.sublist(safeCut);
    final firstParts = _separateTrailingWhitespace(firstRunes);
    final secondParts = _separateTrailingWhitespace(secondRunes);

    final first = _pendingState(_makeChunk(
      field: checkpoint.field,
      index: parentIndex,
      sourceStartRune: parent.chunk.sourceStartRune,
      sourceText: firstParts.sourceText,
      separatorAfter: firstParts.separator,
      sourceHash: checkpoint.sourceHash,
    ));
    final second = _pendingState(_makeChunk(
      field: checkpoint.field,
      index: parentIndex + 1,
      sourceStartRune: parent.chunk.sourceStartRune + safeCut,
      sourceText: secondParts.sourceText,
      separatorAfter: '${secondParts.separator}${parent.chunk.separatorAfter}',
      sourceHash: checkpoint.sourceHash,
    ));

    final replaced = <TranslationChunkState>[
      ...checkpoint.chunks.take(parentIndex),
      first,
      second,
      ...checkpoint.chunks.skip(parentIndex + 1),
    ];
    final reindexed = <TranslationChunkState>[
      for (var index = 0; index < replaced.length; index += 1)
        replaced[index].chunk.index == index
            ? replaced[index]
            : replaced[index]
                ._withChunk(replaced[index].chunk._withIndex(index)),
    ];
    final result = TranslationChunkCheckpoint(
      field: checkpoint.field,
      sourceHash: checkpoint.sourceHash,
      chunks: reindexed,
    );
    final resultError = _validateCheckpoint(result);
    if (resultError != null) throw StateError(resultError);
    return result;
  }
}

final class _ChunkConfig {
  final int target;
  final int hardLimit;
  final int splitThreshold;

  const _ChunkConfig({
    required this.target,
    required this.hardLimit,
    required this.splitThreshold,
  });
}

const _worldBookConfig = _ChunkConfig(
  target: 900,
  hardLimit: 1200,
  splitThreshold: 400,
);

const _otherFieldConfig = _ChunkConfig(
  target: 1800,
  hardLimit: 2400,
  splitThreshold: 800,
);

_ChunkConfig _configFor(String field) =>
    field == 'memoryBook' || field == 'worldBook'
        ? _worldBookConfig
        : _otherFieldConfig;

List<TranslationChunkState> _planRunes({
  required String field,
  required List<int> runes,
  required String sourceHash,
  required _ChunkConfig config,
}) {
  if (runes.isEmpty || runes.every(_isWhitespace)) {
    final parts = _separateTrailingWhitespace(runes);
    return [
      _pendingState(_makeChunk(
        field: field,
        index: 0,
        sourceStartRune: 0,
        sourceText: parts.sourceText,
        separatorAfter: parts.separator,
        sourceHash: sourceHash,
      )),
    ];
  }

  final chunks = <TranslationChunkState>[];
  var start = 0;
  while (start < runes.length) {
    final remaining = runes.length - start;
    final end = remaining <= config.hardLimit
        ? runes.length
        : _chooseBoundary(
            runes,
            start: start,
            maxEnd: start + config.hardLimit,
            desiredEnd: start + config.target,
          );
    final safeEnd = end <= start ? start + config.hardLimit : end;
    final parts = _separateTrailingWhitespace(runes.sublist(start, safeEnd));
    chunks.add(_pendingState(_makeChunk(
      field: field,
      index: chunks.length,
      sourceStartRune: start,
      sourceText: parts.sourceText,
      separatorAfter: parts.separator,
      sourceHash: sourceHash,
    )));
    start = safeEnd;
  }
  return chunks;
}

int _chooseBoundary(
  List<int> runes, {
  required int start,
  required int maxEnd,
  required int desiredEnd,
}) {
  final boundedMax = _clampInt(maxEnd, start + 1, runes.length);
  final candidates = List.generate(4, (_) => <int>[]);

  for (var position = start + 1; position <= boundedMax; position += 1) {
    final kind = _boundaryKind(runes, position);
    if (kind != null) candidates[kind].add(position);
  }
  for (final priority in candidates) {
    if (priority.isNotEmpty) return _closestTo(priority, desiredEnd);
  }
  return boundedMax;
}

int? _boundaryKind(List<int> runes, int position) {
  if (_startsMarkerAt(runes, position)) return 0;
  final previous = runes[position - 1];
  if (previous == 0x0A ||
      (previous == 0x0D &&
          (position == runes.length || runes[position] != 0x0A))) {
    return 1;
  }
  if (_endsSentenceAt(runes, position)) return 2;
  if (_isWhitespace(previous) &&
      (position == runes.length || !_isWhitespace(runes[position]))) {
    return 3;
  }
  return null;
}

bool _startsMarkerAt(List<int> runes, int position) {
  if (position >= runes.length || !_isLineStart(runes, position)) return false;
  var cursor = position;
  while (cursor < runes.length &&
      runes[cursor] != 0x0A &&
      runes[cursor] != 0x0D &&
      _isHorizontalWhitespace(runes[cursor])) {
    cursor += 1;
  }
  if (cursor >= runes.length) return false;
  final rune = runes[cursor];
  if (rune == 0x5B ||
      rune == 0x3C ||
      rune == 0x23 ||
      rune == 0x3E ||
      rune == 0x2D ||
      rune == 0x3D) {
    return true;
  }
  final preview = String.fromCharCodes(
    runes.sublist(cursor, _clampInt(cursor + 12, cursor, runes.length)),
  ).toLowerCase();
  return preview.startsWith('entry') ||
      preview.startsWith('条目') ||
      preview.startsWith('角色');
}

bool _isLineStart(List<int> runes, int position) {
  if (position == 0) return true;
  final previous = runes[position - 1];
  return previous == 0x0A || previous == 0x0D;
}

bool _endsSentenceAt(List<int> runes, int position) {
  if (_isWhitespace(runes[position - 1]) &&
      position < runes.length &&
      _isWhitespace(runes[position])) {
    return false;
  }
  var cursor = position - 1;
  while (cursor >= 0 && _isWhitespace(runes[cursor])) {
    cursor -= 1;
  }
  if (cursor < 0) return false;
  return const {
    0x2E,
    0x21,
    0x3F,
    0x3B,
    0x3002,
    0xFF01,
    0xFF1F,
    0xFF1B,
  }.contains(runes[cursor]);
}

int _closestTo(List<int> values, int target) {
  var best = values.first;
  var distance = (best - target).abs();
  for (final value in values.skip(1)) {
    final candidateDistance = (value - target).abs();
    if (candidateDistance < distance ||
        (candidateDistance == distance && value < best)) {
      best = value;
      distance = candidateDistance;
    }
  }
  return best;
}

final class _SeparatedText {
  final String sourceText;
  final String separator;

  const _SeparatedText(this.sourceText, this.separator);
}

_SeparatedText _separateTrailingWhitespace(List<int> runes) {
  var separatorStart = runes.length;
  while (separatorStart > 0 && _isWhitespace(runes[separatorStart - 1])) {
    separatorStart -= 1;
  }
  return _SeparatedText(
    String.fromCharCodes(runes.take(separatorStart)),
    String.fromCharCodes(runes.skip(separatorStart)),
  );
}

bool _isWhitespace(int rune) =>
    _whitespace.hasMatch(String.fromCharCode(rune)) || rune == 0x00A0;

bool _isHorizontalWhitespace(int rune) =>
    rune != 0x0A && rune != 0x0D && _isWhitespace(rune);

final _whitespace = RegExp(r'^\s$', unicode: true);

TranslationChunk _makeChunk({
  required String field,
  required int index,
  required int sourceStartRune,
  required String sourceText,
  required String separatorAfter,
  required String sourceHash,
}) {
  final sourceEndRune = sourceStartRune + sourceText.runes.length;
  final inputHash = _hashChunkInput(
    field: field,
    sourceStartRune: sourceStartRune,
    sourceEndRune: sourceEndRune,
    sourceText: sourceText,
  );
  return TranslationChunk(
    id: inputHash,
    index: index,
    sourceStartRune: sourceStartRune,
    sourceEndRune: sourceEndRune,
    sourceText: sourceText,
    separatorAfter: separatorAfter,
    sourceHash: sourceHash,
    inputHash: inputHash,
  );
}

TranslationChunkState _pendingState(TranslationChunk chunk) =>
    TranslationChunkState(
      chunk: chunk,
      status: TranslationChunkStatus.pending,
      translatedText: '',
      attempts: 0,
      lastErrorKind: null,
    );

Map<String, dynamic> _stateToJson(TranslationChunkState state) => {
      'chunk': {
        'id': state.chunk.id,
        'index': state.chunk.index,
        'sourceStartRune': state.chunk.sourceStartRune,
        'sourceEndRune': state.chunk.sourceEndRune,
        'sourceText': state.chunk.sourceText,
        'separatorAfter': state.chunk.separatorAfter,
        'sourceHash': state.chunk.sourceHash,
        'inputHash': state.chunk.inputHash,
      },
      'status': state.status.name,
      'translatedText': state.translatedText,
      'attempts': state.attempts,
      'lastErrorKind': state.lastErrorKind?.name,
    };

TranslationChunkState _stateFromJson(Object? raw, int expectedIndex) {
  final json = _jsonMap(raw, 'chunks[$expectedIndex]');
  _expectKeys(
    json,
    const {
      'chunk',
      'status',
      'translatedText',
      'attempts',
      'lastErrorKind',
    },
    'chunks[$expectedIndex]',
  );
  final chunkJson = _jsonMap(json['chunk'], 'chunks[$expectedIndex].chunk');
  _expectKeys(
    chunkJson,
    const {
      'id',
      'index',
      'sourceStartRune',
      'sourceEndRune',
      'sourceText',
      'separatorAfter',
      'sourceHash',
      'inputHash',
    },
    'chunks[$expectedIndex].chunk',
  );
  final status = _enumByName(
    json['status'],
    TranslationChunkStatus.values,
    'status',
  );
  final attempts = _integer(json['attempts'], 'attempts');
  if (attempts < 0) throw const FormatException('attempts 不能为负数');
  final lastErrorRaw = json['lastErrorKind'];
  final lastErrorKind = lastErrorRaw == null
      ? null
      : _enumByName(
          lastErrorRaw,
          TranslationFailureKind.values,
          'lastErrorKind',
        );
  return TranslationChunkState(
    chunk: TranslationChunk(
      id: _hashString(chunkJson['id'], 'id'),
      index: _integer(chunkJson['index'], 'index'),
      sourceStartRune:
          _integer(chunkJson['sourceStartRune'], 'sourceStartRune'),
      sourceEndRune: _integer(chunkJson['sourceEndRune'], 'sourceEndRune'),
      sourceText: _string(chunkJson['sourceText'], 'sourceText'),
      separatorAfter: _string(chunkJson['separatorAfter'], 'separatorAfter'),
      sourceHash: _hashString(chunkJson['sourceHash'], 'sourceHash'),
      inputHash: _hashString(chunkJson['inputHash'], 'inputHash'),
    ),
    status: status,
    translatedText: _string(json['translatedText'], 'translatedText'),
    attempts: attempts,
    lastErrorKind: lastErrorKind,
  );
}

String? _validateCheckpoint(TranslationChunkCheckpoint checkpoint) {
  if (checkpoint.field.trim().isEmpty) return 'field 不能为空';
  if (!_sha256Pattern.hasMatch(checkpoint.sourceHash)) {
    return 'sourceHash 必须是小写 SHA-256';
  }
  if (checkpoint.chunks.isEmpty) return 'chunks 不能为空';

  final reconstructed = StringBuffer();
  final ids = <String>{};
  var cursor = 0;
  for (var index = 0; index < checkpoint.chunks.length; index += 1) {
    final state = checkpoint.chunks[index];
    final chunk = state.chunk;
    if (state.attempts < 0) return 'attempts 不能为负数';
    if (chunk.index != index) return 'chunk index 不连续';
    if (chunk.sourceStartRune != cursor) return 'chunk offset 不连续';
    if (chunk.sourceEndRune !=
        chunk.sourceStartRune + chunk.sourceText.runes.length) {
      return 'chunk sourceEndRune 与 sourceText 不一致';
    }
    if (chunk.sourceHash != checkpoint.sourceHash) {
      return 'chunk sourceHash 与 checkpoint 不一致';
    }
    if (!_sha256Pattern.hasMatch(chunk.inputHash)) {
      return 'chunk inputHash 必须是小写 SHA-256';
    }
    final expectedInputHash = _hashChunkInput(
      field: checkpoint.field,
      sourceStartRune: chunk.sourceStartRune,
      sourceEndRune: chunk.sourceEndRune,
      sourceText: chunk.sourceText,
    );
    if (chunk.inputHash != expectedInputHash) return 'chunk inputHash 校验失败';
    if (chunk.id != chunk.inputHash || !ids.add(chunk.id)) {
      return 'chunk id 校验失败或重复';
    }
    reconstructed
      ..write(chunk.sourceText)
      ..write(chunk.separatorAfter);
    cursor = chunk.sourceEndRune + chunk.separatorAfter.runes.length;
  }
  if (_hashSource(reconstructed.toString()) != checkpoint.sourceHash) {
    return 'checkpoint sourceHash 与重建原文不一致';
  }
  return null;
}

String _hashSource(String source) =>
    sha256.convert(utf8.encode(source)).toString();

String _hashChunkInput({
  required String field,
  required int sourceStartRune,
  required int sourceEndRune,
  required String sourceText,
}) =>
    sha256
        .convert(utf8.encode(jsonEncode([
          TranslationChunkCheckpoint.currentVersion,
          field,
          sourceStartRune,
          sourceEndRune,
          sourceText,
        ])))
        .toString();

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

Map<String, dynamic> _jsonMap(Object? raw, String field) {
  if (raw is! Map) throw FormatException('$field 必须是对象');
  try {
    return Map<String, dynamic>.from(raw);
  } catch (_) {
    throw FormatException('$field 必须只包含字符串键');
  }
}

void _expectKeys(
  Map<String, dynamic> json,
  Set<String> expected,
  String field,
) {
  if (json.keys.length != expected.length ||
      !json.keys.every(expected.contains)) {
    throw FormatException('$field 包含缺失或未知字段');
  }
}

String _string(Object? value, String field) {
  if (value is! String) throw FormatException('$field 必须是字符串');
  return value;
}

String _nonEmptyString(Object? value, String field) {
  final result = _string(value, field);
  if (result.trim().isEmpty) throw FormatException('$field 不能为空');
  return result;
}

String _hashString(Object? value, String field) {
  final result = _string(value, field);
  if (!_sha256Pattern.hasMatch(result)) {
    throw FormatException('$field 必须是小写 SHA-256');
  }
  return result;
}

int _integer(Object? value, String field) {
  if (value is! int) throw FormatException('$field 必须是整数');
  return value;
}

T _enumByName<T extends Enum>(
  Object? value,
  List<T> values,
  String field,
) {
  if (value is! String) throw FormatException('$field 必须是枚举名称');
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('$field 包含未知枚举名称');
}

int _clampInt(int value, int lower, int upper) {
  if (value < lower) return lower;
  if (value > upper) return upper;
  return value;
}
