import 'dart:convert';

/// Stable identifiers for the values provided by the story runtime.
///
/// These strings are persisted in prompt modules, so do not rename an
/// existing value. New runtime values can use their own stable slot key.
class StoryPromptBuiltInSlot {
  const StoryPromptBuiltInSlot._();

  static const rules = 'rules';
  static const room = 'room';
  static const continuity = 'continuity';
  static const worldBookBefore = 'world_book_before';
  static const participants = 'participants';
  static const roleStates = 'role_states';
  static const speaker = 'speaker';
  static const worldBookAfter = 'world_book_after';
  static const history = 'history';
  static const input = 'input';

  /// The canonical built-in order for a newly created prompt configuration.
  static const defaultOrder = <String>[
    rules,
    room,
    continuity,
    worldBookBefore,
    participants,
    roleStates,
    speaker,
    worldBookAfter,
    history,
    input,
  ];
}

class StoryPromptRole {
  const StoryPromptRole._();

  static const system = 'system';
  static const user = 'user';
  static const assistant = 'assistant';

  static String normalize(Object? value) {
    switch (_text(value).toLowerCase()) {
      case user:
        return user;
      case assistant:
        return assistant;
      case system:
      default:
        return system;
    }
  }
}

class StoryPromptPlacement {
  const StoryPromptPlacement._();

  static const system = 'system';
  static const historyDepth = 'historyDepth';

  static String normalize(Object? value) {
    final normalized =
        _text(value).replaceAll(RegExp(r'[_\s-]+'), '').toLowerCase();
    switch (normalized) {
      case 'historydepth':
      case 'history':
      case 'depth':
        return historyDepth;
      case system:
      default:
        return system;
    }
  }
}

class StoryPromptLimits {
  const StoryPromptLimits._();

  static const maxModules = 32;
  static const maxContentLength = 12000;
  static const maxKeyLength = 96;
  static const maxBuiltInSlotLength = 96;
  static const maxDepth = 100;
}

/// A persisted, UI-independent prompt fragment.
///
/// [key] is the stable identity used for sorting and de-duplication. A module
/// may reference a runtime [builtInSlot], provide custom [content], or do both.
class StoryPromptModule {
  final String key;
  final String? builtInSlot;
  final String content;
  final bool enabled;
  final String role;
  final String placement;
  final int depth;
  final int sortOrder;

  const StoryPromptModule({
    required this.key,
    this.builtInSlot,
    this.content = '',
    this.enabled = true,
    this.role = StoryPromptRole.system,
    this.placement = StoryPromptPlacement.system,
    this.depth = 0,
    this.sortOrder = 0,
  });

  factory StoryPromptModule.fromJson(Map<String, dynamic> json) {
    final result = tryFromJson(json);
    if (result == null) {
      throw ArgumentError.value(json, 'json', 'Invalid prompt module');
    }
    return result;
  }

  static StoryPromptModule? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final key = _safeKey(json['key']);
    if (key == null) return null;

    final builtInSlot = _safeSlot(json['builtInSlot'] ?? json['slot']);
    final content =
        _limitContent(_text(json['content'] ?? json['customContent']));
    if (builtInSlot == null && content.isEmpty) return null;

    return StoryPromptModule(
      key: key,
      builtInSlot: builtInSlot,
      content: content,
      enabled: _boolValue(json['enabled'], fallback: true),
      role: StoryPromptRole.normalize(json['role']),
      placement: StoryPromptPlacement.normalize(json['placement']),
      depth: _boundedInt(json['depth'], max: StoryPromptLimits.maxDepth),
      sortOrder: _intValue(json['sortOrder'] ?? json['order']),
    );
  }

  StoryPromptModule copyWith({
    String? key,
    String? builtInSlot,
    bool clearBuiltInSlot = false,
    String? content,
    bool? enabled,
    String? role,
    String? placement,
    int? depth,
    int? sortOrder,
  }) =>
      StoryPromptModule(
        key: key ?? this.key,
        builtInSlot: clearBuiltInSlot ? null : builtInSlot ?? this.builtInSlot,
        content: content ?? this.content,
        enabled: enabled ?? this.enabled,
        role: role ?? this.role,
        placement: placement ?? this.placement,
        depth: depth ?? this.depth,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'builtInSlot': builtInSlot,
        'content': content,
        'enabled': enabled,
        'role': role,
        'placement': placement,
        'depth': depth,
        'sortOrder': sortOrder,
      };
}

class StoryPromptConfig {
  final List<StoryPromptModule> modules;

  const StoryPromptConfig({this.modules = const []});

  factory StoryPromptConfig.fromJson(Map<String, dynamic> json) =>
      StoryPromptConfigCodec.fromJson(json);

  factory StoryPromptConfig.defaults() => const StoryPromptConfig(
        modules: StoryPromptConfigCodec.defaultModules,
      );

  StoryPromptConfig copyWith({List<StoryPromptModule>? modules}) =>
      StoryPromptConfig(modules: modules ?? this.modules);

  Map<String, dynamic> toJson() => {
        'version': StoryPromptConfigCodec.currentVersion,
        'modules': modules.map((module) => module.toJson()).toList(),
      };
}

/// JSON boundary for prompt configuration. It intentionally accepts old blank
/// fields and loose database values without allowing malformed items through.
class StoryPromptConfigCodec {
  const StoryPromptConfigCodec._();

  static const currentVersion = 1;

  static const defaultModules = <StoryPromptModule>[
    StoryPromptModule(
        key: 'builtin.rules',
        builtInSlot: StoryPromptBuiltInSlot.rules,
        sortOrder: 10),
    StoryPromptModule(
        key: 'builtin.room',
        builtInSlot: StoryPromptBuiltInSlot.room,
        sortOrder: 20),
    StoryPromptModule(
        key: 'builtin.continuity',
        builtInSlot: StoryPromptBuiltInSlot.continuity,
        sortOrder: 30),
    StoryPromptModule(
        key: 'builtin.world-book-before',
        builtInSlot: StoryPromptBuiltInSlot.worldBookBefore,
        sortOrder: 40),
    StoryPromptModule(
        key: 'builtin.participants',
        builtInSlot: StoryPromptBuiltInSlot.participants,
        sortOrder: 50),
    StoryPromptModule(
        key: 'builtin.role-states',
        builtInSlot: StoryPromptBuiltInSlot.roleStates,
        sortOrder: 60),
    StoryPromptModule(
        key: 'builtin.speaker',
        builtInSlot: StoryPromptBuiltInSlot.speaker,
        sortOrder: 70),
    StoryPromptModule(
        key: 'builtin.world-book-after',
        builtInSlot: StoryPromptBuiltInSlot.worldBookAfter,
        sortOrder: 80),
    StoryPromptModule(
        key: 'builtin.history',
        builtInSlot: StoryPromptBuiltInSlot.history,
        placement: StoryPromptPlacement.historyDepth,
        role: StoryPromptRole.user,
        sortOrder: 90),
    StoryPromptModule(
        key: 'builtin.input',
        builtInSlot: StoryPromptBuiltInSlot.input,
        placement: StoryPromptPlacement.historyDepth,
        role: StoryPromptRole.user,
        sortOrder: 100),
  ];

  static StoryPromptConfig decode(Object? raw) {
    if (raw == null) return StoryPromptConfig.defaults();
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) return StoryPromptConfig.defaults();
      try {
        return fromDecoded(jsonDecode(text));
      } catch (_) {
        return StoryPromptConfig.defaults();
      }
    }
    return fromDecoded(raw);
  }

  static String encode(StoryPromptConfig config) => jsonEncode(config.toJson());

  static StoryPromptConfig fromJson(Map<String, dynamic> json) =>
      fromDecoded(json);

  static StoryPromptConfig fromDecoded(Object? raw) {
    final entries = raw is Map ? raw['modules'] : raw;
    if (entries is! List) return const StoryPromptConfig();

    final modules = <StoryPromptModule>[];
    final keys = <String>{};
    for (final entry in entries) {
      if (modules.length >= StoryPromptLimits.maxModules) break;
      final module = StoryPromptModule.tryFromJson(entry);
      if (module == null || !keys.add(module.key)) continue;
      modules.add(module);
    }
    return StoryPromptConfig(modules: List.unmodifiable(modules));
  }

  /// 读取常见 SillyTavern Prompt Manager / prompt_order 形状。
  /// 未识别字段不会执行，也不会阻断角色卡其它内容导入。
  static StoryPromptConfig fromTavernExtensions(Map<String, dynamic> source) {
    final manager = _stringMap(
          source['prompt_manager'] ?? source['promptManager'],
        ) ??
        const <String, dynamic>{};
    final rawPrompts = _firstList([
      manager['prompts'],
      manager['prompt_list'],
      source['prompts'],
    ]);
    final rawOrder = _firstOrder([
      manager['order'],
      manager['prompt_order'],
      source['prompt_order'],
      source['promptOrder'],
    ]);
    if (rawPrompts.isEmpty && rawOrder.isEmpty) {
      return StoryPromptConfig.defaults();
    }

    final defaults = [for (final item in defaultModules) item];
    final bySlot = {
      for (var index = 0; index < defaults.length; index++)
        if (defaults[index].builtInSlot != null)
          defaults[index].builtInSlot!: index,
    };
    final promptById = <String, Map<String, dynamic>>{};
    for (final raw in rawPrompts) {
      final prompt = _stringMap(raw);
      if (prompt == null) continue;
      final id = _promptIdentifier(prompt);
      if (id.isNotEmpty) promptById[id] = prompt;
    }
    final custom = <StoryPromptModule>[];
    final seenPromptIds = <String>{};
    for (var index = 0; index < rawOrder.length; index++) {
      final order = _stringMap(rawOrder[index]);
      final id =
          order == null ? _text(rawOrder[index]) : _promptIdentifier(order);
      if (id.isEmpty) continue;
      seenPromptIds.add(id);
      final prompt = promptById[id] ?? const <String, dynamic>{};
      final slot = _tavernBuiltInSlot(id);
      final enabled = _boolValue(
        order?['enabled'] ?? prompt['enabled'],
        fallback: true,
      );
      final sortOrder = (index + 1) * 10;
      if (slot != null && bySlot.containsKey(slot)) {
        final target = bySlot[slot]!;
        defaults[target] = defaults[target].copyWith(
          content: _promptContent(prompt),
          enabled: enabled,
          role: StoryPromptRole.normalize(prompt['role']),
          placement: _tavernPlacement(prompt['position']),
          depth: _boundedInt(prompt['depth'], max: StoryPromptLimits.maxDepth),
          sortOrder: sortOrder,
        );
        continue;
      }
      final content = _promptContent(prompt);
      if (content.isEmpty) continue;
      custom.add(StoryPromptModule(
        key: 'tavern.$id',
        content: content,
        enabled: enabled,
        role: StoryPromptRole.normalize(prompt['role']),
        placement: _tavernPlacement(prompt['position']),
        depth: _boundedInt(prompt['depth'], max: StoryPromptLimits.maxDepth),
        sortOrder: sortOrder,
      ));
    }
    var nextOrder = (rawOrder.length + 1) * 10;
    for (final entry in promptById.entries) {
      if (seenPromptIds.contains(entry.key)) continue;
      final slot = _tavernBuiltInSlot(entry.key);
      final content = _promptContent(entry.value);
      if (slot != null && bySlot.containsKey(slot)) {
        final target = bySlot[slot]!;
        defaults[target] = defaults[target].copyWith(content: content);
      } else if (content.isNotEmpty) {
        custom.add(StoryPromptModule(
          key: 'tavern.${entry.key}',
          content: content,
          enabled: _boolValue(entry.value['enabled'], fallback: true),
          role: StoryPromptRole.normalize(entry.value['role']),
          placement: _tavernPlacement(entry.value['position']),
          depth: _boundedInt(
            entry.value['depth'],
            max: StoryPromptLimits.maxDepth,
          ),
          sortOrder: nextOrder,
        ));
        nextOrder += 10;
      }
    }
    final modules = [...defaults, ...custom]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return StoryPromptConfig(
      modules: List.unmodifiable(modules.take(StoryPromptLimits.maxModules)),
    );
  }

  static List<dynamic> _firstList(List<Object?> candidates) {
    for (final value in candidates) {
      if (value is List) return value;
    }
    return const [];
  }

  static List<dynamic> _firstOrder(List<Object?> candidates) {
    for (final value in candidates) {
      if (value is List) return value;
      if (value is Map && value.isNotEmpty) {
        final entries = value.entries.toList()
          ..sort((a, b) => _intValue(a.value).compareTo(_intValue(b.value)));
        return [
          for (final entry in entries)
            {
              'identifier': '${entry.key}',
              'enabled': true,
              'order': _intValue(entry.value),
            },
        ];
      }
    }
    return const [];
  }

  static Map<String, dynamic>? _stringMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  static String _promptIdentifier(Map<String, dynamic> value) => _text(
        value['identifier'] ?? value['id'] ?? value['key'] ?? value['name'],
      );

  static String _promptContent(Map<String, dynamic> value) => _limitContent(
        _text(value['content'] ?? value['prompt'] ?? value['text']),
      );

  static String _tavernPlacement(Object? value) {
    final normalized = _text(value).toLowerCase();
    if (value == 1 ||
        normalized == '1' ||
        normalized == 'in_chat' ||
        normalized == 'in-chat' ||
        normalized == 'inchat') {
      return StoryPromptPlacement.historyDepth;
    }
    return StoryPromptPlacement.system;
  }

  static String? _tavernBuiltInSlot(String identifier) {
    final id = identifier.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    const slots = {
      'main': StoryPromptBuiltInSlot.rules,
      'mainprompt': StoryPromptBuiltInSlot.rules,
      'worldinfobefore': StoryPromptBuiltInSlot.worldBookBefore,
      'worldinfoafter': StoryPromptBuiltInSlot.worldBookAfter,
      'chatmemory': StoryPromptBuiltInSlot.continuity,
      'summary': StoryPromptBuiltInSlot.continuity,
      'chathistory': StoryPromptBuiltInSlot.history,
      'history': StoryPromptBuiltInSlot.history,
      'charactercard': StoryPromptBuiltInSlot.speaker,
      'characterdescription': StoryPromptBuiltInSlot.speaker,
      'scenario': StoryPromptBuiltInSlot.room,
      'posthistoryinstructions': StoryPromptBuiltInSlot.input,
      'jailbreak': StoryPromptBuiltInSlot.input,
    };
    return slots[id];
  }
}

class StoryPromptVariables {
  final String character;
  final String user;
  final String room;
  final String input;

  const StoryPromptVariables({
    this.character = '',
    this.user = '',
    this.room = '',
    this.input = '',
  });

  String replace(String value) => value
      .replaceAll('{{char}}', character)
      .replaceAll('{{user}}', user)
      .replaceAll('{{room}}', room)
      .replaceAll('{{input}}', input);
}

class StoryPromptMessage {
  final String key;
  final String role;
  final String placement;
  final int depth;
  final int sortOrder;
  final String content;

  const StoryPromptMessage({
    required this.key,
    required this.role,
    required this.placement,
    required this.depth,
    required this.sortOrder,
    required this.content,
  });
}

class StoryPromptComposition {
  final List<StoryPromptMessage> systemMessages;
  final List<StoryPromptMessage> historyDepthMessages;

  const StoryPromptComposition({
    required this.systemMessages,
    required this.historyDepthMessages,
  });

  List<StoryPromptMessage> get messages => [
        ...systemMessages,
        ...historyDepthMessages,
      ];
}

/// Resolves built-in slots and custom content without depending on a page or a
/// chat transport. Consumers insert [historyDepthMessages] at `length - depth`.
class StoryPromptComposer {
  const StoryPromptComposer._();

  static StoryPromptComposition compose(
    StoryPromptConfig config, {
    Map<String, String> builtInSlots = const {},
    StoryPromptVariables variables = const StoryPromptVariables(),
  }) {
    final system = <StoryPromptMessage>[];
    final historyDepth = <StoryPromptMessage>[];
    for (final module in config.modules) {
      if (!module.enabled) continue;
      final content = _resolveContent(module, builtInSlots, variables);
      if (content.isEmpty) continue;
      final message = StoryPromptMessage(
        key: module.key,
        role: module.role,
        placement: module.placement,
        depth: module.depth,
        sortOrder: module.sortOrder,
        content: content,
      );
      if (module.placement == StoryPromptPlacement.historyDepth) {
        historyDepth.add(message);
      } else {
        system.add(message);
      }
    }
    system.sort(_compareMessages);
    historyDepth.sort(_compareMessages);
    return StoryPromptComposition(
      systemMessages: List.unmodifiable(system),
      historyDepthMessages: List.unmodifiable(historyDepth),
    );
  }

  static String _resolveContent(
    StoryPromptModule module,
    Map<String, String> builtInSlots,
    StoryPromptVariables variables,
  ) {
    final parts = <String>[];
    final slot = module.builtInSlot;
    if (slot != null) {
      final builtIn = builtInSlots[slot]?.trim() ?? '';
      if (builtIn.isNotEmpty) parts.add(builtIn);
    }
    final custom = module.content.trim();
    if (custom.isNotEmpty) parts.add(custom);
    return variables.replace(parts.join('\n\n')).trim();
  }

  static int _compareMessages(StoryPromptMessage a, StoryPromptMessage b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    final byDepth = a.depth.compareTo(b.depth);
    if (byDepth != 0) return byDepth;
    return a.key.compareTo(b.key);
  }
}

String _text(Object? value) => value is String ? value.trim() : '';

String? _safeKey(Object? value) {
  final key = _text(value);
  if (key.isEmpty || key.length > StoryPromptLimits.maxKeyLength) return null;
  if (key.contains(RegExp(r'[\x00-\x1F\x7F]'))) return null;
  return key;
}

String? _safeSlot(Object? value) {
  final slot = _text(value);
  if (slot.isEmpty || slot.length > StoryPromptLimits.maxBuiltInSlotLength) {
    return null;
  }
  if (slot.contains(RegExp(r'[\x00-\x1F\x7F]'))) return null;
  return slot;
}

String _limitContent(String value) {
  if (value.length <= StoryPromptLimits.maxContentLength) return value;
  return value.substring(0, StoryPromptLimits.maxContentLength);
}

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

int _boundedInt(Object? value, {required int max}) =>
    _intValue(value).clamp(0, max).toInt();

int _intValue(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? 0;
}
