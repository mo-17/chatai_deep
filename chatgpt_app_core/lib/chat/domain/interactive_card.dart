import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 卡片仅是模型原文的显示投影；本地勾选状态不属于模型协议。
const interactiveCardSystemPrompt = '''
仅当用户明确要求交互卡片、可勾选清单或对比卡时，可以用独立行的 ```chatai-card 围栏输出以下严格 JSON（其它回复照常）。
清单：{"schema":"chatai.card","version":1,"type":"checklist","title":"标题","items":[{"id":"item1","text":"事项"}]}
对比：{"schema":"chatai.card","version":1,"type":"comparison","title":"标题","options":[{"id":"a","label":"方案 A"},{"id":"b","label":"方案 B"}],"rows":[{"id":"row1","label":"维度","values":{"a":"值","b":"值"}}]}
上述字段全部必需，不添加其它字段。id 为 1–64 个英文字母、数字、下划线或连字符。标题/标签最多 120 字，事项/值最多 500 字。清单 1–20 项，对比 2–4 个方案、1–12 行；values 必须包含且仅包含全部方案 id。每条回复最多 4 张卡，每张 JSON 最多 32KiB。正文均为纯文本，不放脚本、执行指令或本地状态。
''';

sealed class InteractiveCard {
  final String title;
  const InteractiveCard(this.title);
  Map<String, Object> toJson();
  String get schemaHash =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

class ChecklistItem {
  final String id;
  final String text;
  const ChecklistItem(this.id, this.text);
}

class ChecklistCard extends InteractiveCard {
  final List<ChecklistItem> items;
  ChecklistCard(super.title, List<ChecklistItem> items)
      : items = List.unmodifiable(items);
  @override
  Map<String, Object> toJson() => {
        'schema': 'chatai.card',
        'version': 1,
        'type': 'checklist',
        'title': title,
        'items': [
          for (final i in items) {'id': i.id, 'text': i.text}
        ],
      };
}

class ComparisonOption {
  final String id;
  final String label;
  const ComparisonOption(this.id, this.label);
}

class ComparisonRow {
  final String id;
  final String label;
  final Map<String, String> values;
  ComparisonRow(this.id, this.label, Map<String, String> values)
      : values = Map.unmodifiable(values);
}

class ComparisonCard extends InteractiveCard {
  final List<ComparisonOption> options;
  final List<ComparisonRow> rows;
  ComparisonCard(
      super.title, List<ComparisonOption> options, List<ComparisonRow> rows)
      : options = List.unmodifiable(options),
        rows = List.unmodifiable(rows);
  @override
  Map<String, Object> toJson() => {
        'schema': 'chatai.card',
        'version': 1,
        'type': 'comparison',
        'title': title,
        'options': [
          for (final o in options) {'id': o.id, 'label': o.label}
        ],
        'rows': [
          for (final r in rows)
            {
              'id': r.id,
              'label': r.label,
              'values': {for (final o in options) o.id: r.values[o.id]!},
            }
        ],
      };
}

sealed class CardTextPart {
  const CardTextPart();
}

class CardPlainText extends CardTextPart {
  final String text;
  const CardPlainText(this.text);
}

class CardProjection extends CardTextPart {
  final InteractiveCard card;
  final int ordinal;
  final String original;
  const CardProjection(this.card, this.ordinal, this.original);
  String get key => '$ordinal:${card.schemaHash}';
}

/// 有界逐行扫描；不修改输入，不修补 JSON。未完成回复一律保持原文。
class InteractiveCardParser {
  static const maxJsonBytes = 32 * 1024;
  static const maxTextBytes = 512 * 1024;
  static const maxCards = 4;

  static bool fitsMessageBudget(Iterable<String> texts) {
    var remaining = maxTextBytes;
    for (final text in texts) {
      final bytes = _boundedUtf8Length(text, remaining);
      if (bytes > remaining) {
        return false;
      }
      remaining -= bytes;
    }
    return true;
  }

  static List<CardTextPart> parse(String content,
      {bool completed = true, int cardLimit = maxCards}) {
    if (!completed || cardLimit <= 0 || !_fitsUtf8(content, maxTextBytes)) {
      return [CardPlainText(content)];
    }
    final parts = <CardTextPart>[];
    var cursor = 0, plainStart = 0, ordinal = 0, accepted = 0;
    var otherFence = false;
    while (cursor < content.length) {
      final start = cursor;
      final nl = content.indexOf('\n', start);
      final end = nl < 0 ? content.length : nl;
      final line =
          content.substring(start, end).replaceFirst(RegExp(r'\r$'), '');
      cursor = nl < 0 ? content.length : nl + 1;
      if (line == '```' && otherFence) {
        otherFence = false;
        continue;
      }
      if (otherFence) {
        continue;
      }
      if (line != '```chatai-card') {
        if (line.startsWith('```')) otherFence = true;
        continue;
      }
      final candidateOrdinal = ordinal++;
      final jsonStart = cursor;
      int? jsonEnd;
      while (cursor < content.length) {
        final rowStart = cursor;
        final rowNl = content.indexOf('\n', rowStart);
        final rowEnd = rowNl < 0 ? content.length : rowNl;
        final row = content
            .substring(rowStart, rowEnd)
            .replaceFirst(RegExp(r'\r$'), '');
        cursor = rowNl < 0 ? content.length : rowNl + 1;
        if (row == '```') {
          jsonEnd = rowStart;
          break;
        }
      }
      if (jsonEnd == null) {
        break;
      }
      if (accepted >= cardLimit) {
        continue;
      }
      // UTF-16 长度先拦截，避免超大候选的额外 UTF-8 分配。
      if (jsonEnd - jsonStart > maxJsonBytes) {
        continue;
      }
      final json = content.substring(jsonStart, jsonEnd);
      final card = tryParseJson(json);
      if (card == null) {
        continue;
      }
      if (start > plainStart) {
        parts.add(CardPlainText(content.substring(plainStart, start)));
      }
      parts.add(CardProjection(
          card, candidateOrdinal, content.substring(start, cursor)));
      plainStart = cursor;
      accepted++;
    }
    if (plainStart < content.length || parts.isEmpty) {
      parts.add(CardPlainText(content.substring(plainStart)));
    }
    return List.unmodifiable(parts);
  }

  static InteractiveCard? tryParseJson(String raw) {
    if (!_fitsUtf8(raw, maxJsonBytes)) {
      return null;
    }
    try {
      final value = _StrictJson(raw).read();
      if (value is! Map<String, dynamic> ||
          value['schema'] != 'chatai.card' ||
          value['version'] is! int ||
          value['version'] != 1 ||
          !_text(value['title'], 120)) {
        return null;
      }
      final title = value['title'] as String;
      if (value['type'] == 'checklist') {
        if (!_keys(value, {'schema', 'version', 'type', 'title', 'items'})) {
          return null;
        }
        final items = value['items'];
        if (items is! List || items.isEmpty || items.length > 20) {
          return null;
        }
        final ids = <String>{};
        final result = <ChecklistItem>[];
        for (final i in items) {
          if (i is! Map<String, dynamic> ||
              !_keys(i, {'id', 'text'}) ||
              !_id(i['id']) ||
              !ids.add(i['id'] as String) ||
              !_text(i['text'], 500)) {
            return null;
          }
          result.add(ChecklistItem(i['id'] as String, i['text'] as String));
        }
        return ChecklistCard(title, result);
      }
      if (value['type'] == 'comparison') {
        if (!_keys(
            value, {'schema', 'version', 'type', 'title', 'options', 'rows'})) {
          return null;
        }
        final options = value['options'], rows = value['rows'];
        if (options is! List ||
            options.length < 2 ||
            options.length > 4 ||
            rows is! List ||
            rows.isEmpty ||
            rows.length > 12) {
          return null;
        }
        final ids = <String>{};
        final resultOptions = <ComparisonOption>[];
        for (final o in options) {
          if (o is! Map<String, dynamic> ||
              !_keys(o, {'id', 'label'}) ||
              !_id(o['id']) ||
              !ids.add(o['id'] as String) ||
              !_text(o['label'], 120)) {
            return null;
          }
          resultOptions
              .add(ComparisonOption(o['id'] as String, o['label'] as String));
        }
        final rowIds = <String>{};
        final resultRows = <ComparisonRow>[];
        for (final r in rows) {
          if (r is! Map<String, dynamic> ||
              !_keys(r, {'id', 'label', 'values'}) ||
              !_id(r['id']) ||
              !rowIds.add(r['id'] as String) ||
              !_text(r['label'], 120)) {
            return null;
          }
          final values = r['values'];
          if (values is! Map<String, dynamic> ||
              !_keys(values, ids) ||
              values.values.any((v) => !_text(v, 500))) {
            return null;
          }
          resultRows.add(ComparisonRow(r['id'] as String, r['label'] as String,
              values.cast<String, String>()));
        }
        return ComparisonCard(title, resultOptions, resultRows);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

class ChecklistLocalState {
  final Set<String> checkedItemIds;
  ChecklistLocalState(Iterable<String> ids)
      : checkedItemIds = Set.unmodifiable(ids);
  Map<String, Object> toJson() =>
      {'version': 1, 'checkedItemIds': checkedItemIds.toList()..sort()};
}

/// 损坏状态逐卡忽略，不影响正文、协议或其它有效卡。
Map<String, ChecklistLocalState> decodeLocalCardStates(
    Object? raw, String content) {
  if (raw is! Map) {
    return const {};
  }
  final cards = {
    for (final p
        in InteractiveCardParser.parse(content).whereType<CardProjection>())
      p.key: p.card
  };
  final result = <String, ChecklistLocalState>{};
  for (final entry in cards.entries) {
    final card = entry.value;
    if (card is! ChecklistCard) {
      continue;
    }
    final state = raw[entry.key];
    if (state is! Map ||
        !_keys(state, {'version', 'checkedItemIds'}) ||
        state['version'] is! int ||
        state['version'] != 1) {
      continue;
    }
    final checked = state['checkedItemIds'];
    if (checked is! List ||
        checked.length > card.items.length ||
        checked.any((id) => id is! String)) {
      continue;
    }
    final ids = checked.cast<String>().toSet();
    if (ids.length != checked.length ||
        !card.items.map((i) => i.id).toSet().containsAll(ids)) {
      continue;
    }
    result[entry.key] = ChecklistLocalState(ids);
  }
  return Map.unmodifiable(result);
}

String exportInteractiveCard(InteractiveCard card,
    {Set<String> checked = const {}}) {
  String escape(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAllMapped(RegExp(r'([`*_\[\]#<>])'), (m) => '\\${m[0]}')
      .replaceAll('|', r'\|')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', ' / ');
  final out = StringBuffer('### ${escape(card.title)}\n\n');
  switch (card) {
    case ChecklistCard():
      for (final item in card.items) {
        out.writeln(
            '- [${checked.contains(item.id) ? 'x' : ' '}] ${escape(item.text)}');
      }
    case ComparisonCard():
      out.writeln(
          '| 维度 | ${card.options.map((o) => escape(o.label)).join(' | ')} |');
      out.writeln('| --- | ${card.options.map((_) => '---').join(' | ')} |');
      for (final row in card.rows) {
        out.writeln(
            '| ${escape(row.label)} | ${card.options.map((o) => escape(row.values[o.id]!)).join(' | ')} |');
      }
  }
  return out.toString().trimRight();
}

bool _keys(Map map, Set<String> keys) =>
    map.length == keys.length && keys.every(map.containsKey);
bool _text(Object? value, int max) =>
    value is String && value.trim().isNotEmpty && value.runes.length <= max;
bool _id(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value);

bool _fitsUtf8(String value, int limit) =>
    _boundedUtf8Length(value, limit) <= limit;

int _boundedUtf8Length(String value, int limit) {
  var bytes = 0;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c < 0x80) {
      bytes++;
    } else if (c < 0x800) {
      bytes += 2;
    } else if (c >= 0xd800 &&
        c <= 0xdbff &&
        i + 1 < value.length &&
        value.codeUnitAt(i + 1) >= 0xdc00 &&
        value.codeUnitAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
    if (bytes > limit) {
      return bytes;
    }
  }
  return bytes;
}

/// JSON 词法由标准解码器验证；对象由本解析器构造，拒绝重复键及过深嵌套。
class _StrictJson {
  final String source;
  int i = 0;
  _StrictJson(this.source);
  Never _bad() => throw const FormatException('非法卡片 JSON');
  void _space() {
    while (i < source.length &&
        const [0x20, 9, 10, 13].contains(source.codeUnitAt(i))) {
      i++;
    }
  }

  Object? read() {
    final result = _value(0);
    _space();
    if (i != source.length) _bad();
    return result;
  }

  Object? _value(int depth) {
    _space();
    if (i >= source.length) _bad();
    final c = source[i];
    if (c == '"') {
      return _string();
    }
    if (c == '{' || c == '[') {
      if (depth >= 8) _bad();
      i++;
      _space();
      final object = c == '{';
      final close = object ? '}' : ']';
      final map = <String, dynamic>{};
      final list = <Object?>[];
      if (i < source.length && source[i] == close) {
        i++;
        return object ? map : list;
      }
      while (true) {
        if (object) {
          _space();
          if (i >= source.length || source[i] != '"') _bad();
          final key = _string();
          if (map.containsKey(key)) _bad();
          _space();
          if (i >= source.length || source[i++] != ':') _bad();
          map[key] = _value(depth + 1);
        } else {
          list.add(_value(depth + 1));
        }
        _space();
        if (i >= source.length) _bad();
        final separator = source[i++];
        if (separator == close) {
          return object ? map : list;
        }
        if (separator != ',') _bad();
      }
    }
    final start = i;
    while (i < source.length &&
        !const [',', '}', ']', ' ', '\t', '\n', '\r'].contains(source[i])) {
      i++;
    }
    if (i == start) _bad();
    final token = jsonDecode(source.substring(start, i));
    if (token is Map || token is List || token is String) _bad();
    return token;
  }

  String _string() {
    final start = i++;
    while (i < source.length) {
      final c = source[i++];
      if (c == '\\') {
        if (i >= source.length) _bad();
        i++;
      } else if (c == '"') {
        return jsonDecode(source.substring(start, i)) as String;
      }
    }
    _bad();
  }
}
