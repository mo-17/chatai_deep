import 'dart:convert';

/// Regex scripts run only on a named text boundary. They never contain code.
enum StoryRegexStage {
  userInput('userInput'),
  assistantOutput('assistantOutput'),
  assistantDisplay('assistantDisplay');

  final String value;

  const StoryRegexStage(this.value);

  static StoryRegexStage? tryParse(Object? raw) {
    final value = _text(raw).replaceAll(RegExp(r'[_\s-]+'), '').toLowerCase();
    switch (value) {
      case 'userinput':
      case 'user':
        return userInput;
      case 'assistantoutput':
      case 'aioutput':
      case 'output':
        return assistantOutput;
      case 'assistantdisplay':
      case 'display':
        return assistantDisplay;
      default:
        return null;
    }
  }
}

class StoryRegexScriptLimits {
  const StoryRegexScriptLimits._();

  static const maxRules = 64;
  static const maxKeyLength = 120;
  static const maxNameLength = 160;
  static const maxPatternLength = 512;
  static const maxReplacementLength = 4000;
  static const maxTrimStrings = 32;
  static const maxTrimStringLength = 512;
  static const maxTextLength = 32000;
}

/// A single declarative regex replacement. [stage] is intentionally explicit:
/// importing a Tavern rule cannot make it run at an unspecified boundary.
class StoryRegexScript {
  final String key;
  final String name;
  final StoryRegexStage stage;
  final String find;
  final String replace;
  final List<String> trimStrings;
  final bool caseSensitive;
  final bool multiLine;
  final bool dotAll;
  final bool enabled;
  final int sortOrder;

  const StoryRegexScript({
    required this.key,
    required this.name,
    required this.stage,
    required this.find,
    this.replace = '',
    this.trimStrings = const [],
    this.caseSensitive = true,
    this.multiLine = false,
    this.dotAll = false,
    this.enabled = true,
    this.sortOrder = 0,
  });

  StoryRegexScript copyWith({
    String? key,
    String? name,
    StoryRegexStage? stage,
    String? find,
    String? replace,
    List<String>? trimStrings,
    bool? caseSensitive,
    bool? multiLine,
    bool? dotAll,
    bool? enabled,
    int? sortOrder,
  }) =>
      StoryRegexScript(
        key: key ?? this.key,
        name: name ?? this.name,
        stage: stage ?? this.stage,
        find: find ?? this.find,
        replace: replace ?? this.replace,
        trimStrings: trimStrings ?? this.trimStrings,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        multiLine: multiLine ?? this.multiLine,
        dotAll: dotAll ?? this.dotAll,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  factory StoryRegexScript.fromJson(Map<String, dynamic> json) {
    final result = tryFromJson(json);
    if (result == null) {
      throw ArgumentError.value(json, 'json', 'Invalid regex script');
    }
    return result;
  }

  static StoryRegexScript? tryFromJson(Object? raw) {
    final json = _stringMap(raw);
    if (json == null) return null;
    final key = _safeKey(json['key']);
    final stage = StoryRegexStage.tryParse(json['stage']);
    final replace =
        json.containsKey('replace') ? _safeReplacement(json['replace']) : '';
    return _fromFields(
      key: key,
      name: _safeName(json['name']),
      stage: stage,
      find: _safePattern(json['find']),
      replace: replace,
      trimStrings: _trimStrings(json['trimStrings']),
      caseSensitive: _boolValue(json['caseSensitive'], fallback: true),
      multiLine: _boolValue(json['multiLine'], fallback: false),
      dotAll: _boolValue(json['dotAll'], fallback: false),
      enabled: _boolValue(json['enabled'], fallback: true),
      sortOrder: _intValue(json['sortOrder'] ?? json['order']),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'stage': stage.value,
        'find': find,
        'replace': replace,
        'trimStrings': trimStrings,
        'caseSensitive': caseSensitive,
        'multiLine': multiLine,
        'dotAll': dotAll,
        'enabled': enabled,
        'sortOrder': sortOrder,
      };

  static StoryRegexScript? _fromFields({
    required String? key,
    required String? name,
    required StoryRegexStage? stage,
    required String? find,
    required String? replace,
    required List<String> trimStrings,
    required bool caseSensitive,
    required bool multiLine,
    required bool dotAll,
    required bool enabled,
    required int sortOrder,
  }) {
    if (key == null ||
        name == null ||
        stage == null ||
        find == null ||
        replace == null) {
      return null;
    }
    return StoryRegexScript(
      key: key,
      name: name,
      stage: stage,
      find: find,
      replace: replace,
      trimStrings: List.unmodifiable(trimStrings),
      caseSensitive: caseSensitive,
      multiLine: multiLine,
      dotAll: dotAll,
      enabled: enabled,
      sortOrder: sortOrder,
    );
  }
}

/// JSON boundary for room-owned regex rules and declarative Tavern imports.
class StoryRegexScripts {
  final List<StoryRegexScript> rules;

  const StoryRegexScripts({this.rules = const []});

  factory StoryRegexScripts.fromJson(Map<String, dynamic> json) =>
      StoryRegexScriptsCodec.fromJson(json);

  Map<String, dynamic> toJson() => {
        'version': StoryRegexScriptsCodec.currentVersion,
        'rules': rules.map((rule) => rule.toJson()).toList(),
      };

  List<StoryRegexScript> get orderedRules {
    final ordered = [...rules]..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.key.compareTo(b.key);
      });
    return List.unmodifiable(ordered);
  }
}

class StoryRegexScriptsCodec {
  const StoryRegexScriptsCodec._();

  static const currentVersion = 1;

  static StoryRegexScripts decode(Object? raw) {
    if (raw is String) {
      final value = raw.trim();
      if (value.isEmpty) return const StoryRegexScripts();
      try {
        return fromDecoded(jsonDecode(value));
      } catch (_) {
        return const StoryRegexScripts();
      }
    }
    return fromDecoded(raw);
  }

  static String encode(StoryRegexScripts scripts) =>
      jsonEncode(scripts.toJson());

  static StoryRegexScripts fromJson(Map<String, dynamic> json) =>
      fromDecoded(json);

  static StoryRegexScripts fromDecoded(Object? raw) {
    final json = _stringMap(raw);
    final entries = raw is List
        ? raw
        : json?['rules'] ?? json?['regexScripts'] ?? json?['regex_scripts'];
    if (entries is! List) return const StoryRegexScripts();
    return StoryRegexScripts(rules: _readOwnRules(entries));
  }

  /// Imports only the two text placements that have a defined local boundary.
  /// Tavern's other placements are deliberately ignored instead of guessed.
  static StoryRegexScripts fromTavernExtensions(Map<String, dynamic> source) {
    final extensions = _stringMap(source['extensions']) ?? source;
    final entries = extensions['regex_scripts'] ?? extensions['regexScripts'];
    if (entries is! List) return const StoryRegexScripts();

    final rules = <StoryRegexScript>[];
    final keys = <String>{};
    for (var index = 0; index < entries.length; index++) {
      if (rules.length >= StoryRegexScriptLimits.maxRules) break;
      final json = _stringMap(entries[index]);
      if (json == null) continue;
      final parsedPattern =
          _parseTavernPattern(json['findRegex'] ?? json['find']);
      final find = parsedPattern?.pattern;
      final replace =
          _safeReplacement(json['replaceString'] ?? json['replace']);
      if (find == null || replace == null) continue;

      final name = _safeName(json['scriptName'] ?? json['name']) ??
          'Regex rule ${index + 1}';
      final baseKey = _tavernKey(json['key'], name, index);
      final markdownOnly = _boolValue(json['markdownOnly'], fallback: false);
      final promptOnly = _boolValue(json['promptOnly'], fallback: false);
      if (promptOnly) continue;
      final stages = _tavernStages(
        json['placement'],
        markdownOnly: markdownOnly,
      );
      final enabled = _boolValue(json['disabled'], fallback: false)
          ? false
          : _boolValue(json['enabled'], fallback: true);
      for (final stage in stages) {
        if (rules.length >= StoryRegexScriptLimits.maxRules) break;
        final key = _tavernStageKey(
          baseKey: baseKey,
          stage: stage,
          index: index,
          multipleStages: stages.length > 1,
        );
        if (!keys.add(key)) continue;
        rules.add(StoryRegexScript(
          key: key,
          name: name,
          stage: stage,
          find: find,
          replace: replace,
          trimStrings: List.unmodifiable(_trimStrings(json['trimStrings'])),
          caseSensitive: parsedPattern!.caseSensitive,
          multiLine: parsedPattern.multiLine,
          dotAll: parsedPattern.dotAll,
          enabled: enabled,
          sortOrder: _intValue(json['sortOrder'] ?? json['order']) == 0
              ? index * 10
              : _intValue(json['sortOrder'] ?? json['order']),
        ));
      }
    }
    return StoryRegexScripts(rules: List.unmodifiable(rules));
  }

  static List<StoryRegexScript> _readOwnRules(List entries) {
    final rules = <StoryRegexScript>[];
    final keys = <String>{};
    for (final entry in entries) {
      if (rules.length >= StoryRegexScriptLimits.maxRules) break;
      final rule = StoryRegexScript.tryFromJson(entry);
      if (rule == null || !keys.add(rule.key)) continue;
      rules.add(rule);
    }
    return List.unmodifiable(rules);
  }

  static List<StoryRegexStage> _tavernStages(
    Object? raw, {
    required bool markdownOnly,
  }) {
    final values = raw is List ? raw : [raw];
    if (markdownOnly) {
      final hasAssistantOutput = values.any((value) {
        final placement = value is num ? value.toInt() : int.tryParse('$value');
        return placement == 2;
      });
      return hasAssistantOutput
          ? const [StoryRegexStage.assistantDisplay]
          : const [];
    }
    final stages = <StoryRegexStage>[];
    for (final value in values) {
      final placement = value is num ? value.toInt() : int.tryParse('$value');
      final stage = switch (placement) {
        1 => StoryRegexStage.userInput,
        2 => StoryRegexStage.assistantOutput,
        _ => null,
      };
      if (stage != null && !stages.contains(stage)) stages.add(stage);
    }
    return stages;
  }

  static _ParsedTavernPattern? _parseTavernPattern(Object? raw) {
    final value = raw is String ? raw : '';
    if (value.isEmpty) return null;
    var pattern = value;
    var flags = '';
    if (value.startsWith('/')) {
      var closing = -1;
      var escaped = false;
      for (var index = value.length - 1; index > 0; index--) {
        if (value[index] != '/') continue;
        var slashCount = 0;
        for (var cursor = index - 1;
            cursor >= 0 && value.codeUnitAt(cursor) == 92;
            cursor--) {
          slashCount++;
        }
        escaped = slashCount.isOdd;
        if (!escaped) {
          closing = index;
          break;
        }
      }
      if (closing > 0) {
        pattern = value.substring(1, closing);
        flags = value.substring(closing + 1).toLowerCase();
        if (!RegExp(r'^[gimsuy]*$').hasMatch(flags)) return null;
      }
    }
    final safe = _safePattern(pattern);
    if (safe == null) return null;
    return _ParsedTavernPattern(
      pattern: safe,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
    );
  }

  static String _tavernKey(Object? raw, String name, int index) {
    final supplied = _safeKey(raw);
    if (supplied != null) return supplied;
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final suffix = slug.isEmpty ? '${index + 1}' : slug;
    return 'tavern.regex.$suffix.$index';
  }

  static String _tavernStageKey({
    required String baseKey,
    required StoryRegexStage stage,
    required int index,
    required bool multipleStages,
  }) {
    if (!multipleStages) return baseKey;
    final suffix = '.${stage.value}';
    if (baseKey.length + suffix.length <= StoryRegexScriptLimits.maxKeyLength) {
      return '$baseKey$suffix';
    }
    return 'tavern.regex.$index.${stage.value}';
  }
}

class _ParsedTavernPattern {
  final String pattern;
  final bool caseSensitive;
  final bool multiLine;
  final bool dotAll;

  const _ParsedTavernPattern({
    required this.pattern,
    required this.caseSensitive,
    required this.multiLine,
    required this.dotAll,
  });
}

Map<String, dynamic>? _stringMap(Object? raw) {
  if (raw is! Map) return null;
  return {
    for (final entry in raw.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String _text(Object? value) => value is String ? value.trim() : '';

bool _safeText(String value, int maxLength) =>
    value.isNotEmpty &&
    value.length <= maxLength &&
    !value.contains(RegExp(r'[\x00-\x1F\x7F]'));

String? _safeKey(Object? value) {
  final text = _text(value);
  return _safeText(text, StoryRegexScriptLimits.maxKeyLength) ? text : null;
}

String? _safeName(Object? value) {
  final text = _text(value);
  return _safeText(text, StoryRegexScriptLimits.maxNameLength) ? text : null;
}

String? _safePattern(Object? value) {
  final text = value is String ? value : '';
  if (text.isEmpty || text.length > StoryRegexScriptLimits.maxPatternLength) {
    return null;
  }
  return _hasUnsafeControlCharacter(text) ? null : text;
}

String? _safeReplacement(Object? value) {
  final text = value is String ? value : '';
  if (text.length > StoryRegexScriptLimits.maxReplacementLength ||
      _hasUnsafeControlCharacter(text)) {
    return null;
  }
  return text;
}

List<String> _trimStrings(Object? value) {
  final values = value is List
      ? value
      : value is String
          ? [value]
          : const [];
  final result = <String>[];
  for (final item in values) {
    if (result.length >= StoryRegexScriptLimits.maxTrimStrings) break;
    if (item is! String || item.isEmpty) continue;
    if (item.length > StoryRegexScriptLimits.maxTrimStringLength ||
        _hasUnsafeControlCharacter(item)) {
      continue;
    }
    result.add(item);
  }
  return result;
}

bool _hasUnsafeControlCharacter(String value) =>
    value.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'));

bool _boolValue(Object? value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  switch (_text(value).toLowerCase()) {
    case 'true':
    case '1':
    case 'yes':
      return true;
    case 'false':
    case '0':
    case 'no':
      return false;
    default:
      return fallback;
  }
}

int _intValue(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}
