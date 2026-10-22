/// Pure-Dart world book parsing and runtime matching.
library;

import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/story_regex_executor.dart';

class WorldBookCodec {
  const WorldBookCodec._();

  static List<WorldBookEntry> decode({
    String structuredJson = '',
    String legacyText = '',
  }) {
    final jsonText = structuredJson.trim();
    if (jsonText.isNotEmpty) {
      try {
        final decoded = jsonDecode(jsonText);
        final rawEntries = decoded is Map ? decoded['entries'] : decoded;
        if (rawEntries is List) {
          final entries = <WorldBookEntry>[];
          for (final raw in rawEntries) {
            if (raw is! Map) continue;
            final entry = WorldBookEntry.fromJson(
              Map<String, dynamic>.from(raw),
            );
            if (entry.content.trim().isNotEmpty) entries.add(entry);
          }
          if (entries.isNotEmpty || rawEntries.isEmpty) return entries;
        }
      } catch (_) {
        // 结构化数据损坏时回退旧文本，保证旧助手仍可使用。
      }
    }
    final entries = <WorldBookEntry>[];
    var index = 0;
    for (final line in legacyText.replaceAll('\r\n', '\n').split('\n')) {
      final entry = WorldBookEntry.tryParse(line, id: 'legacy-${index++}');
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  /// 修改已支持字段时按稳定 id 合并原文档；未知字段是导出数据，不能进入匹配器。
  static String encode(Iterable<WorldBookEntry> entries,
      {String preservingJson = ''}) {
    final document = readDocument(preservingJson);
    final previous = <String, Map<String, dynamic>>{};
    final rawEntries = document['entries'];
    if (rawEntries is List) {
      for (final raw in rawEntries) {
        if (raw is Map<String, dynamic> && raw['id'] is String) {
          previous[raw['id'] as String] = raw;
        }
      }
    }
    return jsonEncode({
      ...document,
      'version': 1,
      'entries': [
        for (final entry in entries)
          {
            ...?previous[entry.id],
            ...entry.toJson(),
          }
      ],
    });
  }

  static Map<String, dynamic> readDocument(String source) {
    try {
      final value = jsonDecode(source);
      if (value is Map<String, dynamic>) return value;
    } catch (_) {
      // 旧文本/无结构化数据由调用方按原有兼容路径解析。
    }
    return {};
  }
}

enum WorldBookSelectiveLogic {
  andAny,
  notAll,
  notAny,
  andAll,
}

class WorldBookEntry {
  final String id;
  final List<String> keywords;
  final String content;
  final bool enabled;
  final int priority;
  final bool regex;
  final bool caseSensitive;
  final bool wholeWords;
  final List<String> secondaryKeywords;
  final List<String> excludeKeywords;
  final String position;
  final int? depth;
  final int? probability;
  final bool probabilityEnabled;
  final bool excludeFromRecursion;
  final String group;
  final int groupWeight;
  final bool groupOverride;
  final bool useGroupScoring;
  final WorldBookSelectiveLogic selectiveLogic;
  final int sticky;
  final int cooldown;
  final int delay;
  final List<String> characterFilterNames;
  final bool characterFilterExclude;
  final bool matchPersonaDescription;
  final bool matchCharacterDescription;
  final bool matchCharacterPersonality;
  final bool matchCharacterDepthPrompt;
  final bool matchScenario;
  final bool matchCreatorNotes;
  final String? _preservedLine;

  const WorldBookEntry({
    this.id = '',
    this.keywords = const [],
    required this.content,
    this.enabled = true,
    this.priority = 0,
    this.regex = false,
    this.caseSensitive = false,
    this.wholeWords = false,
    this.secondaryKeywords = const [],
    this.excludeKeywords = const [],
    this.position = '',
    this.depth,
    this.probability,
    this.probabilityEnabled = true,
    this.excludeFromRecursion = false,
    this.group = '',
    this.groupWeight = 0,
    this.groupOverride = false,
    this.useGroupScoring = false,
    this.selectiveLogic = WorldBookSelectiveLogic.andAny,
    this.sticky = 0,
    this.cooldown = 0,
    this.delay = 0,
    this.characterFilterNames = const [],
    this.characterFilterExclude = false,
    this.matchPersonaDescription = false,
    this.matchCharacterDescription = false,
    this.matchCharacterPersonality = false,
    this.matchCharacterDepthPrompt = false,
    this.matchScenario = false,
    this.matchCreatorNotes = false,
    String? preservedLine,
  }) : _preservedLine = preservedLine;

  bool get alwaysOn => keywords.isEmpty;

  List<String> get groups => _splitList(group);

  String get activationKey =>
      id.isNotEmpty ? id : '${content.trim()}|${keywords.join('\u0000')}';

  /// Parses the line format used by the existing world-book editor.
  /// Unknown leading tags are deliberately left in the body, so an old line
  /// can be emitted unchanged even when a future tag is not known here yet.
  static WorldBookEntry? tryParse(String raw, {String id = ''}) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) return null;

    var rest = line;
    var enabled = true;
    var priority = 0;
    var regex = false;
    var caseSensitive = false;
    var wholeWords = false;
    var secondaryKeywords = const <String>[];
    var excludeKeywords = const <String>[];
    var position = '';
    int? depth;
    int? probability;
    var probabilityEnabled = true;
    var excludeFromRecursion = false;
    var group = '';
    var groupWeight = 0;
    var groupOverride = false;
    var useGroupScoring = false;
    var selectiveLogic = WorldBookSelectiveLogic.andAny;
    var sticky = 0;
    var cooldown = 0;
    var delay = 0;
    var characterFilterNames = const <String>[];
    var characterFilterExclude = false;
    var matchPersonaDescription = false;
    var matchCharacterDescription = false;
    var matchCharacterPersonality = false;
    var matchCharacterDepthPrompt = false;
    var matchScenario = false;
    var matchCreatorNotes = false;

    while (rest.startsWith('[')) {
      final end = rest.indexOf(']');
      if (end <= 0) break;
      final rawTag = rest.substring(1, end).trim();
      final tag = rawTag.toLowerCase();
      final value = _tagValue(rawTag);
      var known = true;
      if (tag == 'off' || tag == 'disabled') {
        enabled = false;
      } else if (tag == 'on' || tag == 'enabled') {
        enabled = true;
      } else if (tag.startsWith('p=')) {
        priority = _intValue(value, priority);
      } else if (tag == 're' || tag == 'regex') {
        regex = true;
      } else if (tag == 'cs' || tag == 'case') {
        caseSensitive = true;
      } else if (tag == 'ww' || tag == 'whole') {
        wholeWords = true;
      } else if (tag.startsWith('sec=') || tag.startsWith('secondary=')) {
        secondaryKeywords = _splitList(value);
      } else if (tag.startsWith('exclude=') ||
          tag.startsWith('excludes=') ||
          tag.startsWith('exclude_keys=') ||
          tag.startsWith('excludekeys=')) {
        excludeKeywords = _splitList(value);
      } else if (tag.startsWith('pos=') || tag.startsWith('position=')) {
        position = value;
      } else if (tag.startsWith('depth=')) {
        depth = _nullableInt(value);
      } else if (tag.startsWith('prob=') || tag.startsWith('probability=')) {
        probability = _nullableInt(value);
      } else if (tag == 'norec' ||
          tag == 'nonrec' ||
          tag == 'no_recursion' ||
          tag == 'exclude_recursion' ||
          tag == 'prevent_recursion') {
        excludeFromRecursion = true;
      } else if (tag.startsWith('group=')) {
        group = value;
      } else if (tag.startsWith('gw=') ||
          tag.startsWith('groupweight=') ||
          tag.startsWith('group_weight=')) {
        groupWeight = _intValue(value, groupWeight);
      } else if (tag == 'prob_enabled' || tag == 'probability_enabled') {
        probabilityEnabled = true;
      } else if (tag == 'prob_disabled' || tag == 'probability_disabled') {
        probabilityEnabled = false;
      } else if (tag == 'group_override' || tag == 'groupoverride') {
        groupOverride = true;
      } else if (tag == 'group_scoring' || tag == 'use_group_scoring') {
        useGroupScoring = true;
      } else if (tag.startsWith('logic=') ||
          tag.startsWith('selective_logic=')) {
        selectiveLogic = _logic(value);
      } else if (tag.startsWith('sticky=')) {
        sticky = _nonNegativeInt(value);
      } else if (tag.startsWith('cooldown=')) {
        cooldown = _nonNegativeInt(value);
      } else if (tag.startsWith('delay=')) {
        delay = _nonNegativeInt(value);
      } else if (tag.startsWith('characters=') ||
          tag.startsWith('character=')) {
        characterFilterNames = _splitList(value);
      } else if (tag == 'characters_exclude' || tag == 'character_exclude') {
        characterFilterExclude = true;
      } else if (tag == 'persona' || tag == 'match_persona_description') {
        matchPersonaDescription = true;
      } else if (tag == 'character_description' ||
          tag == 'match_character_description') {
        matchCharacterDescription = true;
      } else if (tag == 'character_personality' ||
          tag == 'match_character_personality') {
        matchCharacterPersonality = true;
      } else if (tag == 'character_depth_prompt' ||
          tag == 'match_character_depth_prompt') {
        matchCharacterDepthPrompt = true;
      } else if (tag == 'scenario' || tag == 'match_scenario') {
        matchScenario = true;
      } else if (tag == 'creator_notes' || tag == 'match_creator_notes') {
        matchCreatorNotes = true;
      } else {
        known = false;
      }
      if (!known) break;
      rest = rest.substring(end + 1).trimLeft();
    }

    final divider = rest.indexOf('=>');
    final content =
        divider < 0 ? rest.trim() : rest.substring(divider + 2).trim();
    if (content.isEmpty) return null;
    final keywords = divider < 0
        ? const <String>[]
        : _splitList(rest.substring(0, divider), regex: regex);
    if (divider >= 0 && keywords.isEmpty) return null;
    return WorldBookEntry(
      id: id,
      keywords: keywords,
      content: content,
      enabled: enabled,
      priority: priority,
      regex: regex,
      caseSensitive: caseSensitive,
      wholeWords: wholeWords,
      secondaryKeywords: secondaryKeywords,
      excludeKeywords: excludeKeywords,
      position: position,
      depth: depth,
      probability: probability,
      probabilityEnabled: probabilityEnabled,
      excludeFromRecursion: excludeFromRecursion,
      group: group,
      groupWeight: groupWeight,
      groupOverride: groupOverride,
      useGroupScoring: useGroupScoring,
      selectiveLogic: selectiveLogic,
      sticky: sticky,
      cooldown: cooldown,
      delay: delay,
      characterFilterNames: characterFilterNames,
      characterFilterExclude: characterFilterExclude,
      matchPersonaDescription: matchPersonaDescription,
      matchCharacterDescription: matchCharacterDescription,
      matchCharacterPersonality: matchCharacterPersonality,
      matchCharacterDepthPrompt: matchCharacterDepthPrompt,
      matchScenario: matchScenario,
      matchCreatorNotes: matchCreatorNotes,
      preservedLine: line,
    );
  }

  String toLine({bool preserveSource = true}) {
    if (preserveSource && _preservedLine != null) return _preservedLine;
    final tags = <String>[
      if (!enabled) '[off]',
      if (regex) '[re]',
      if (caseSensitive) '[cs]',
      if (wholeWords) '[ww]',
      if (secondaryKeywords.isNotEmpty) '[sec=${secondaryKeywords.join('|')}]',
      if (priority != 0) '[p=$priority]',
      if (excludeKeywords.isNotEmpty) '[exclude=${excludeKeywords.join('|')}]',
      if (position.isNotEmpty) '[pos=$position]',
      if (depth != null) '[depth=$depth]',
      if (probability != null) '[prob=$probability]',
      if (!probabilityEnabled) '[prob_disabled]',
      if (excludeFromRecursion) '[norec]',
      if (group.isNotEmpty) '[group=$group]',
      if (groupWeight != 0) '[gw=$groupWeight]',
      if (groupOverride) '[group_override]',
      if (useGroupScoring) '[group_scoring]',
      if (selectiveLogic != WorldBookSelectiveLogic.andAny)
        '[logic=${selectiveLogic.index}]',
      if (sticky > 0) '[sticky=$sticky]',
      if (cooldown > 0) '[cooldown=$cooldown]',
      if (delay > 0) '[delay=$delay]',
      if (characterFilterNames.isNotEmpty)
        '[characters=${characterFilterNames.join('|')}]',
      if (characterFilterExclude) '[characters_exclude]',
      if (matchPersonaDescription) '[persona]',
      if (matchCharacterDescription) '[character_description]',
      if (matchCharacterPersonality) '[character_personality]',
      if (matchCharacterDepthPrompt) '[character_depth_prompt]',
      if (matchScenario) '[scenario]',
      if (matchCreatorNotes) '[creator_notes]',
    ];
    final keyText = regex ? keywords.join(' || ') : keywords.join(', ');
    final body = alwaysOn ? content.trim() : '$keyText => ${content.trim()}';
    return [...tags, body].join(' ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'keywords': keywords,
        'content': content,
        'enabled': enabled,
        'priority': priority,
        'regex': regex,
        'caseSensitive': caseSensitive,
        'wholeWords': wholeWords,
        'secondaryKeywords': secondaryKeywords,
        'excludeKeywords': excludeKeywords,
        'position': position,
        'depth': depth,
        'probability': probability,
        'probabilityEnabled': probabilityEnabled,
        'excludeFromRecursion': excludeFromRecursion,
        'group': group,
        'groupWeight': groupWeight,
        'groupOverride': groupOverride,
        'useGroupScoring': useGroupScoring,
        'selectiveLogic': selectiveLogic.index,
        'sticky': sticky,
        'cooldown': cooldown,
        'delay': delay,
        'characterFilterNames': characterFilterNames,
        'characterFilterExclude': characterFilterExclude,
        'matchPersonaDescription': matchPersonaDescription,
        'matchCharacterDescription': matchCharacterDescription,
        'matchCharacterPersonality': matchCharacterPersonality,
        'matchCharacterDepthPrompt': matchCharacterDepthPrompt,
        'matchScenario': matchScenario,
        'matchCreatorNotes': matchCreatorNotes,
      };

  factory WorldBookEntry.fromJson(Map<String, dynamic> json) => WorldBookEntry(
        id: _string(json['id']),
        keywords: _jsonStrings(json['keywords']),
        content: _string(json['content']),
        enabled: _bool(json['enabled'], true),
        priority: _intValue(json['priority'], 0),
        regex: _bool(json['regex']),
        caseSensitive: _bool(json['caseSensitive']),
        wholeWords: _bool(json['wholeWords']),
        secondaryKeywords: _jsonStrings(json['secondaryKeywords']),
        excludeKeywords: _jsonStrings(json['excludeKeywords']),
        position: _string(json['position']),
        depth: _nullableInt(json['depth']),
        probability: _nullableInt(json['probability']),
        probabilityEnabled: _bool(json['probabilityEnabled'], true),
        excludeFromRecursion: _bool(json['excludeFromRecursion']),
        group: _string(json['group']),
        groupWeight: _intValue(json['groupWeight'], 0),
        groupOverride: _bool(json['groupOverride']),
        useGroupScoring: _bool(json['useGroupScoring']),
        selectiveLogic: _logic(json['selectiveLogic']),
        sticky: _nonNegativeInt(json['sticky']),
        cooldown: _nonNegativeInt(json['cooldown']),
        delay: _nonNegativeInt(json['delay']),
        characterFilterNames: _jsonStrings(json['characterFilterNames']),
        characterFilterExclude: _bool(json['characterFilterExclude']),
        matchPersonaDescription: _bool(json['matchPersonaDescription']),
        matchCharacterDescription: _bool(json['matchCharacterDescription']),
        matchCharacterPersonality: _bool(json['matchCharacterPersonality']),
        matchCharacterDepthPrompt: _bool(json['matchCharacterDepthPrompt']),
        matchScenario: _bool(json['matchScenario']),
        matchCreatorNotes: _bool(json['matchCreatorNotes']),
      );
}

class WorldBookActivation {
  final String entryKey;
  final int activatedAtMessage;
  final int stickyUntilMessage;
  final int cooldownUntilMessage;

  const WorldBookActivation({
    required this.entryKey,
    required this.activatedAtMessage,
    required this.stickyUntilMessage,
    required this.cooldownUntilMessage,
  });

  Map<String, dynamic> toJson() => {
        'entryKey': entryKey,
        'activatedAtMessage': activatedAtMessage,
        'stickyUntilMessage': stickyUntilMessage,
        'cooldownUntilMessage': cooldownUntilMessage,
      };

  factory WorldBookActivation.fromJson(Map<String, dynamic> json) =>
      WorldBookActivation(
        entryKey: _string(json['entryKey']),
        activatedAtMessage: _intValue(json['activatedAtMessage'], 0),
        stickyUntilMessage: _intValue(json['stickyUntilMessage'], 0),
        cooldownUntilMessage: _intValue(json['cooldownUntilMessage'], 0),
      );
}

class WorldBookRuntimeState {
  final Map<String, WorldBookActivation> activations;

  WorldBookRuntimeState(Map<String, WorldBookActivation> activations)
      : activations = Map.unmodifiable(activations);

  factory WorldBookRuntimeState.empty() => WorldBookRuntimeState({});

  Map<String, dynamic> toJson() => {
        'activations': activations.values.map((item) => item.toJson()).toList(),
      };

  factory WorldBookRuntimeState.fromJson(Map<String, dynamic> json) {
    final values = json['activations'];
    final entries = values is List
        ? values.whereType<Map>().map((item) =>
            WorldBookActivation.fromJson(Map<String, dynamic>.from(item)))
        : const Iterable<WorldBookActivation>.empty();
    return WorldBookRuntimeState(
        {for (final item in entries) item.entryKey: item});
  }
}

class WorldBookMatchContext {
  final String input;
  final List<String> recentTexts;
  final String personaDescription;
  final String characterDescription;
  final String characterPersonality;
  final String characterDepthPrompt;
  final String scenario;
  final String creatorNotes;
  final String characterName;
  final int messageCount;
  final int generationSeed;
  final Map<String, WorldBookActivation> activations;

  WorldBookMatchContext({
    required this.input,
    this.recentTexts = const [],
    this.personaDescription = '',
    this.characterDescription = '',
    this.characterPersonality = '',
    this.characterDepthPrompt = '',
    this.scenario = '',
    this.creatorNotes = '',
    this.characterName = '',
    this.messageCount = 0,
    this.generationSeed = 0,
    Map<String, WorldBookActivation> activations = const {},
  }) : activations = Map.unmodifiable(activations);

  Map<String, dynamic> toJson() => {
        'input': input,
        'recentTexts': recentTexts,
        'personaDescription': personaDescription,
        'characterDescription': characterDescription,
        'characterPersonality': characterPersonality,
        'characterDepthPrompt': characterDepthPrompt,
        'scenario': scenario,
        'creatorNotes': creatorNotes,
        'characterName': characterName,
        'messageCount': messageCount,
        'generationSeed': generationSeed,
        'activations': activations.values.map((item) => item.toJson()).toList(),
      };

  factory WorldBookMatchContext.fromJson(Map<String, dynamic> json) {
    final state = WorldBookRuntimeState.fromJson(json);
    return WorldBookMatchContext(
      input: _string(json['input']),
      recentTexts: _jsonStrings(json['recentTexts']),
      personaDescription: _string(json['personaDescription']),
      characterDescription: _string(json['characterDescription']),
      characterPersonality: _string(json['characterPersonality']),
      characterDepthPrompt: _string(json['characterDepthPrompt']),
      scenario: _string(json['scenario']),
      creatorNotes: _string(json['creatorNotes']),
      characterName: _string(json['characterName']),
      messageCount: _intValue(json['messageCount'], 0),
      generationSeed: _intValue(json['generationSeed'], 0),
      activations: state.activations,
    );
  }
}

class WorldBookMatchResult {
  final List<WorldBookEntry> entries;
  final WorldBookRuntimeState state;

  const WorldBookMatchResult(this.entries, this.state);

  Map<String, WorldBookActivation> get activations => state.activations;

  Map<String, dynamic> toJson() => {
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'state': state.toJson(),
      };
}

class WorldBookMatcher {
  const WorldBookMatcher._();

  static const maxRegexPatternChars = 4096;
  static const maxRegexInputChars = 32000;
  static const maxScannedEntries = 512;
  static const maxKeywordsPerEntry = 64;
  static const maxRegexQueries = 256;
  static const regexStageTimeout = Duration(milliseconds: 800);

  /// 同步调用永不在当前 isolate 执行不受信任正则；regex entry 会 fail closed。
  /// 需要保留 regex 语义的运行路径应调用 [matchSafely]。
  static WorldBookMatchResult match(
    Iterable<WorldBookEntry> entries,
    WorldBookMatchContext context, {
    int maxEntries = 6,
  }) =>
      _match(entries, context, maxEntries: maxEntries, regexMatches: const {});

  /// 在共享的可杀 isolate 内预计算所有 regex `hasMatch`，再复用同步状态机。
  static Future<WorldBookMatchResult> matchSafely(
    Iterable<WorldBookEntry> entries,
    WorldBookMatchContext context, {
    int maxEntries = 6,
    Duration timeout = regexStageTimeout,
  }) async {
    final entryList = entries.take(maxScannedEntries).toList(growable: false);
    final matches = <_WorldBookRegexQuery, bool>{};
    final clock = Stopwatch()..start();
    var queryCount = 0;
    for (final entry in entryList.where((item) => item.enabled && item.regex)) {
      final scan = _scanText(entry, context);
      final boundedScan = scan.length <= maxRegexInputChars
          ? scan
          : scan.substring(0, maxRegexInputChars);
      for (final keywords in [
        entry.keywords,
        entry.secondaryKeywords,
        entry.excludeKeywords,
      ]) {
        for (final keyword in keywords.take(maxKeywordsPerEntry)) {
          if (keyword.isEmpty) continue;
          if (queryCount >= maxRegexQueries) break;
          final pattern = _boundedRegexPattern(entry, keyword);
          if (pattern == null) continue;
          final query = (
            pattern: pattern,
            scan: boundedScan,
            caseSensitive: entry.caseSensitive,
          );
          if (matches.containsKey(query)) continue;
          queryCount++;
          final remaining = timeout - clock.elapsed;
          if (remaining <= Duration.zero) break;
          final perMatch = remaining < const Duration(milliseconds: 100)
              ? remaining
              : const Duration(milliseconds: 100);
          final result = await StoryRegexExecutor.hasMatch(
            pattern: pattern,
            input: boundedScan,
            caseSensitive: entry.caseSensitive,
            timeout: perMatch,
          );
          matches[query] =
              !result.timedOut && result.error == null ? result.matched : false;
        }
        if (clock.elapsed >= timeout || queryCount >= maxRegexQueries) break;
      }
      if (clock.elapsed >= timeout || queryCount >= maxRegexQueries) break;
    }
    return _match(
      entryList,
      context,
      maxEntries: maxEntries,
      regexMatches: matches,
    );
  }

  static WorldBookMatchResult _match(
    Iterable<WorldBookEntry> entries,
    WorldBookMatchContext context, {
    required int maxEntries,
    required Map<_WorldBookRegexQuery, bool> regexMatches,
  }) {
    final next = Map<String, WorldBookActivation>.from(context.activations);
    final candidates = <_MatchCandidate>[];
    final seenContent = <String>{};
    var index = 0;
    for (final entry in entries) {
      if (index >= maxScannedEntries) break;
      final key =
          entry.id.isNotEmpty ? entry.id : '${entry.activationKey}|$index';
      index++;
      final storedActivation = context.activations[key];
      final previous = storedActivation != null &&
              context.messageCount > storedActivation.activatedAtMessage
          ? storedActivation
          : null;
      if (storedActivation != null && previous == null) next.remove(key);
      if (!entry.enabled || context.messageCount < entry.delay) continue;
      if (!_characterAllowed(entry, context.characterName)) continue;
      if (previous != null &&
          context.messageCount <= previous.stickyUntilMessage) {
        candidates.add(_MatchCandidate(entry, key, _stickyScore(entry), true));
        continue;
      }
      if (previous != null &&
          context.messageCount <= previous.cooldownUntilMessage) {
        continue;
      }
      if (previous != null) next.remove(key);
      final scanText = _scanText(entry, context);
      if (!_keywordsMatch(entry.keywords, scanText, entry, regexMatches)) {
        continue;
      }
      if (!_secondaryMatch(entry, scanText, regexMatches)) continue;
      if (entry.excludeKeywords.isNotEmpty &&
          _keywordsMatch(
              entry.excludeKeywords, scanText, entry, regexMatches)) {
        continue;
      }
      if (entry.probabilityEnabled &&
          entry.probability != null &&
          !_probabilityHit(entry, key, context)) {
        continue;
      }
      if (!seenContent.add(entry.content)) continue;
      candidates.add(_MatchCandidate(
          entry, key, _score(entry, scanText, regexMatches), false));
    }

    final selected = _resolveGroups(candidates, context)
      ..sort((a, b) {
        final priority = b.entry.priority.compareTo(a.entry.priority);
        if (priority != 0) return priority;
        return a.key.compareTo(b.key);
      });
    final limit = maxEntries < 0 ? 0 : maxEntries;
    final selectedEntries = selected.take(limit).toList();
    for (final candidate in selectedEntries) {
      if (!candidate.sticky) {
        final at = context.messageCount;
        next[candidate.key] = WorldBookActivation(
          entryKey: candidate.key,
          activatedAtMessage: at,
          stickyUntilMessage: at + candidate.entry.sticky,
          cooldownUntilMessage:
              at + candidate.entry.sticky + candidate.entry.cooldown,
        );
      }
    }
    return WorldBookMatchResult(
      selectedEntries.map((item) => item.entry).toList(growable: false),
      WorldBookRuntimeState(next),
    );
  }

  static List<_MatchCandidate> _resolveGroups(
    List<_MatchCandidate> candidates,
    WorldBookMatchContext context,
  ) {
    final ungrouped = <_MatchCandidate>[];
    final groups = <String, List<_MatchCandidate>>{};
    for (final candidate in candidates) {
      final names = candidate.entry.groups;
      if (names.isEmpty) {
        ungrouped.add(candidate);
      } else {
        for (final name in names) {
          groups.putIfAbsent(name, () => []).add(candidate);
        }
      }
    }
    final selected = <_MatchCandidate>[...ungrouped];
    final remaining = <String, _MatchCandidate>{
      for (final candidate in candidates)
        if (candidate.entry.groups.isNotEmpty) candidate.key: candidate,
    };
    for (final groupName in groups.keys.toList()..sort()) {
      var choices = groups[groupName]!
          .where((candidate) => remaining.containsKey(candidate.key))
          .toList();
      if (choices.isEmpty) continue;
      if (choices.any((item) => item.entry.useGroupScoring)) {
        final bestScore = choices.map((item) => item.score).reduce(_max);
        choices = choices.where((item) => item.score == bestScore).toList();
      }
      final override =
          choices.where((item) => item.entry.groupOverride).toList();
      if (override.isNotEmpty) {
        override.sort((a, b) {
          final priority = b.entry.priority.compareTo(a.entry.priority);
          return priority != 0 ? priority : a.key.compareTo(b.key);
        });
        final winner = override.first;
        selected.add(winner);
        _removeGroupConflicts(remaining, winner);
      } else {
        final winner = _weightedChoice(choices,
            '${context.generationSeed}|${context.messageCount}|$groupName');
        selected.add(winner);
        _removeGroupConflicts(remaining, winner);
      }
    }
    final unique = <String, _MatchCandidate>{};
    for (final candidate in selected) {
      unique.putIfAbsent(candidate.key, () => candidate);
    }
    return unique.values.toList();
  }

  static void _removeGroupConflicts(
    Map<String, _MatchCandidate> remaining,
    _MatchCandidate winner,
  ) {
    final winnerGroups = winner.entry.groups.toSet();
    remaining.removeWhere((key, candidate) =>
        key == winner.key || candidate.entry.groups.any(winnerGroups.contains));
  }

  static _MatchCandidate _weightedChoice(
      List<_MatchCandidate> choices, String seed) {
    final total = choices.fold<int>(0, (sum, item) => sum + _weight(item));
    var point = _stableHash(seed) % total;
    for (final choice in choices) {
      point -= _weight(choice);
      if (point < 0) return choice;
    }
    return choices.last;
  }

  static int _weight(_MatchCandidate item) =>
      item.entry.groupWeight > 0 ? item.entry.groupWeight : 1;

  static bool _characterAllowed(WorldBookEntry entry, String name) {
    if (entry.characterFilterNames.isEmpty) return true;
    final hit = entry.characterFilterNames
        .take(maxKeywordsPerEntry)
        .any((item) => item.toLowerCase() == name.trim().toLowerCase());
    return entry.characterFilterExclude ? !hit : hit;
  }

  static String _scanText(WorldBookEntry entry, WorldBookMatchContext context) {
    final recent = entry.depth == null
        ? context.recentTexts
        : entry.depth! <= 0
            ? const <String>[]
            : context.recentTexts.skip(context.recentTexts.length > entry.depth!
                ? context.recentTexts.length - entry.depth!
                : 0);
    final output = StringBuffer();
    void append(String value) {
      if (value.isEmpty || output.length >= maxRegexInputChars) return;
      if (output.isNotEmpty) output.write('\n');
      final remaining = maxRegexInputChars - output.length;
      if (remaining <= 0) return;
      output.write(
          value.length <= remaining ? value : value.substring(0, remaining));
    }

    append(context.input);
    for (final text in recent) {
      append(text);
      if (output.length >= maxRegexInputChars) break;
    }
    if (entry.matchPersonaDescription) append(context.personaDescription);
    if (entry.matchCharacterDescription) {
      append(context.characterDescription);
    }
    if (entry.matchCharacterPersonality) {
      append(context.characterPersonality);
    }
    if (entry.matchCharacterDepthPrompt) {
      append(context.characterDepthPrompt);
    }
    if (entry.matchScenario) append(context.scenario);
    if (entry.matchCreatorNotes) append(context.creatorNotes);
    return output.toString();
  }

  static bool _secondaryMatch(WorldBookEntry entry, String scan,
      Map<_WorldBookRegexQuery, bool> regexMatches) {
    final keys = entry.secondaryKeywords.take(maxKeywordsPerEntry).toList();
    if (keys.isEmpty) return true;
    final hits =
        keys.map((key) => _keywordHit(key, scan, entry, regexMatches)).toList();
    switch (entry.selectiveLogic) {
      case WorldBookSelectiveLogic.andAny:
        return hits.any((item) => item);
      case WorldBookSelectiveLogic.notAll:
        return !hits.every((item) => item);
      case WorldBookSelectiveLogic.notAny:
        return !hits.any((item) => item);
      case WorldBookSelectiveLogic.andAll:
        return hits.every((item) => item);
    }
  }

  static bool _keywordsMatch(List<String> keywords, String scan,
      WorldBookEntry entry, Map<_WorldBookRegexQuery, bool> regexMatches) {
    if (keywords.isEmpty) return true;
    return keywords
        .take(maxKeywordsPerEntry)
        .any((key) => _keywordHit(key, scan, entry, regexMatches));
  }

  static bool _keywordHit(String keyword, String scan, WorldBookEntry entry,
      Map<_WorldBookRegexQuery, bool> regexMatches) {
    if (keyword.isEmpty) return false;
    if (entry.regex) {
      final pattern = _boundedRegexPattern(entry, keyword);
      if (pattern == null) return false;
      final boundedScan = scan.length <= maxRegexInputChars
          ? scan
          : scan.substring(0, maxRegexInputChars);
      return regexMatches[(
            pattern: pattern,
            scan: boundedScan,
            caseSensitive: entry.caseSensitive,
          )] ??
          false;
    }
    final source = entry.caseSensitive ? scan : scan.toLowerCase();
    final needle = entry.caseSensitive ? keyword : keyword.toLowerCase();
    if (!entry.wholeWords) return source.contains(needle);
    return _literalWholeWordHit(source, needle);
  }

  static String? _boundedRegexPattern(
    WorldBookEntry entry,
    String keyword,
  ) {
    const prefix = '(^|[^A-Za-z0-9_])(?:';
    const suffix = r')([^A-Za-z0-9_]|$)';
    final overhead = entry.wholeWords ? prefix.length + suffix.length : 0;
    if (keyword.length > maxRegexPatternChars - overhead) return null;
    return entry.wholeWords ? '$prefix$keyword$suffix' : keyword;
  }

  static bool _probabilityHit(
      WorldBookEntry entry, String key, WorldBookMatchContext context) {
    final probability = entry.probability!.clamp(0, 100);
    if (probability == 100) return true;
    if (probability == 0) return false;
    return _stableHash(
                '${context.generationSeed}|${context.messageCount}|$key') %
            100 <
        probability;
  }

  static bool _literalWholeWordHit(String source, String needle) {
    if (needle.isEmpty || needle.length > source.length) return false;
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) return false;
      final end = index + needle.length;
      final beforeBoundary =
          index == 0 || !_isAsciiWord(source.codeUnitAt(index - 1));
      final afterBoundary =
          end == source.length || !_isAsciiWord(source.codeUnitAt(end));
      if (beforeBoundary && afterBoundary) return true;
      offset = index + 1;
    }
    return false;
  }

  static bool _isAsciiWord(int codeUnit) =>
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7a) ||
      codeUnit == 0x5f;

  static int _score(WorldBookEntry entry, String scan,
      Map<_WorldBookRegexQuery, bool> regexMatches) {
    var score = 0;
    for (final items in [entry.keywords, entry.secondaryKeywords]) {
      for (final item in items.take(maxKeywordsPerEntry)) {
        if (_keywordHit(item, scan, entry, regexMatches)) score++;
      }
    }
    return score;
  }

  static int _stickyScore(WorldBookEntry entry) => 100000 + entry.priority;

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final code in value.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static int stableSeed(String value) => _stableHash(value);
}

typedef _WorldBookRegexQuery = ({
  String pattern,
  String scan,
  bool caseSensitive,
});

class _MatchCandidate {
  final WorldBookEntry entry;
  final String key;
  final int score;
  final bool sticky;

  const _MatchCandidate(this.entry, this.key, this.score, this.sticky);
}

int _max(int a, int b) => a > b ? a : b;

String _tagValue(String tag) {
  final equals = tag.indexOf('=');
  return equals < 0 ? '' : tag.substring(equals + 1).trim();
}

List<String> _splitList(Object? raw, {bool regex = false}) {
  final text = _string(raw).trim();
  if (text.isEmpty) return const [];
  final splitter = regex ? RegExp(r'\s*\|\|\s*') : RegExp(r'[,，、|/]+');
  return text
      .split(splitter)
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

List<String> _jsonStrings(Object? raw) => raw is List
    ? raw.map(_string).where((item) => item.isNotEmpty).toList()
    : _splitList(raw);

String _string(Object? value) => value?.toString() ?? '';

int? _nullableInt(Object? value) => int.tryParse(_string(value).trim());

int _intValue(Object? value, int fallback) => _nullableInt(value) ?? fallback;

int _nonNegativeInt(Object? value) =>
    (_nullableInt(value) ?? 0).clamp(0, 1 << 30);

bool _bool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = _string(value).toLowerCase();
  if (text == 'true' || text == '1') return true;
  if (text == 'false' || text == '0') return false;
  return fallback;
}

WorldBookSelectiveLogic _logic(Object? value) {
  final index = _nullableInt(value);
  if (index != null &&
      index >= 0 &&
      index < WorldBookSelectiveLogic.values.length) {
    return WorldBookSelectiveLogic.values[index];
  }
  switch (_string(value).toLowerCase()) {
    case 'not_all':
      return WorldBookSelectiveLogic.notAll;
    case 'not_any':
      return WorldBookSelectiveLogic.notAny;
    case 'and_all':
      return WorldBookSelectiveLogic.andAll;
    default:
      return WorldBookSelectiveLogic.andAny;
  }
}
