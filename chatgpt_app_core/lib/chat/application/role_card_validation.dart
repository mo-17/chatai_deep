import 'dart:convert';

/// 本地卡的所有 JSON 入口共用预算；先扫描深度，再调用 JSON 解码器。
/// 未知扩展可以保存，但不能借巨型文本/数组消耗无界内存。
class RoleCardValidation {
  static const maxJsonBytes = 32 * 1024 * 1024;
  static const maxDepth = 24;
  static const maxNodes = 50000;
  // 派生工作副本包含已映射字段、源条目和字段快照；预算独立且仍有界。
  static const maxDerivedNodes = 200000;
  static const maxCarrierNodes = 100000;
  static const maxDerivedDepth = maxDepth + 4;
  static const maxListItems = 4096;
  static const maxTextBytes = 24 * 1024 * 1024;
  static const maxStringBytes = 16 * 1024 * 1024;
  static const maxWorldBookEntries = 1024;

  const RoleCardValidation._();

  static String decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
    } on FormatException {
      throw const FormatException('角色卡必须使用有效 UTF-8 编码');
    }
  }

  static Map<String, dynamic> decode(String source,
      {int depthLimit = maxDepth,
      int nodeLimit = maxNodes,
      bool validateKnownFields = true}) {
    if (utf8.encode(source).length > maxJsonBytes) {
      throw const FormatException('角色卡 JSON 过大（最多 32 MiB）');
    }
    final text = source.replaceFirst(RegExp(r'^\uFEFF'), '');
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (final code in text.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == 92) {
          escaped = true;
        } else if (code == 34) {
          inString = false;
        }
      } else if (code == 34) {
        inString = true;
      } else if (code == 123 || code == 91) {
        if (++depth > depthLimit) {
          throw FormatException('角色卡 JSON 嵌套超过 $depthLimit 层');
        }
      } else if (code == 125 || code == 93) {
        depth--;
      }
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('角色卡 JSON 格式无效');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('角色卡 JSON 必须是对象');
    }
    var nodes = 0;
    var textBytes = 0;
    void visit(Object? value) {
      if (++nodes > nodeLimit) {
        throw FormatException('角色卡 JSON 节点超过 $nodeLimit 个');
      }
      if (value is String) {
        final size = utf8.encode(value).length;
        textBytes += size;
        if (size > maxStringBytes || textBytes > maxTextBytes) {
          throw const FormatException('角色卡正文超过文本预算（单段 16 MiB / 总计 24 MiB）');
        }
      } else if (value is List) {
        if (value.length > maxListItems) {
          throw const FormatException('角色卡数组超过 4096 项');
        }
        value.forEach(visit);
      } else if (value is Map) {
        for (final entry in value.entries) {
          visit(entry.key);
          visit(entry.value);
        }
      }
    }

    visit(decoded);
    if (validateKnownFields) validateFields(decoded);
    return decoded;
  }

  static void validateFields(Map<String, dynamic> card) {
    if (card.containsKey('spec')) {
      final spec = card['spec'];
      if (spec != 'chara_card_v2' && spec != 'chara_card_v3') {
        throw FormatException('不支持的角色卡协议：$spec');
      }
      final expected = spec == 'chara_card_v3' ? '3.0' : '2.0';
      final version = card['spec_version'];
      if (version != null && version != expected) {
        throw FormatException('不支持的角色卡版本：$version（支持 $expected）');
      }
      if (card['data'] is! Map<String, dynamic>) {
        throw const FormatException('角色卡 data 必须是对象');
      }
    }
    final wrapped = card['assistant'];
    if (card.containsKey('assistant') && wrapped is! Map<String, dynamic>) {
      throw const FormatException('角色卡 assistant 必须是对象');
    }
    if (wrapped is Map && card.containsKey('version') && card['version'] != 1) {
      throw FormatException('不支持的本应用角色卡版本：${card['version']}');
    }
    final data = card['data'] is Map<String, dynamic>
        ? card['data'] as Map<String, dynamic>
        : wrapped is Map<String, dynamic>
            ? wrapped
            : card;
    for (final key in const [
      'name',
      'creator',
      'character_version',
      'prompt',
      'openingMessage',
      'exampleDialogs',
      'memoryBook',
      'worldBookJson',
      'roleCardAssets',
      'model',
      'providerId',
      'emoji',
      'defaultVoiceStyle'
    ]) {
      if (data.containsKey(key) && data[key] is! String) {
        throw FormatException('角色卡 $key 必须是文本');
      }
    }
    for (final key in const [
      'description',
      'personality',
      'scenario',
      'first_mes',
      'mes_example',
      'creator_notes',
      'system_prompt',
      'post_history_instructions'
    ]) {
      if (!data.containsKey(key)) continue;
      final value = data[key];
      // 保留项目已有的本地化文本兼容，数字/布尔等不修补成文本。
      if (value is! String &&
          !(value is Map &&
              value.keys.every((key) => key is String) &&
              value.values.every((item) => item is String))) {
        throw FormatException('角色卡 $key 必须是文本或本地化文本对象');
      }
    }
    for (final key in const ['extensions', 'character_book', 'characterBook']) {
      if (data.containsKey(key) && data[key] is! Map) {
        throw FormatException('角色卡 $key 必须是对象');
      }
    }
    for (final key in [
      'tags',
      'group_only_greetings',
      if (card['spec'] == 'chara_card_v3') 'source'
    ]) {
      if (key == 'tags' &&
          data[key] is String &&
          card['spec_version'] == null) {
        continue;
      }
      if (data.containsKey(key) &&
          !(data[key] is List &&
              (data[key] as List).every((item) => item is String))) {
        throw FormatException('角色卡 $key 必须是文本数组');
      }
    }
    final greetings = data['alternate_greetings'];
    if (greetings != null &&
        !(greetings is String ||
            greetings is List &&
                greetings.every((item) => item is String || item is Map) ||
            greetings is Map &&
                greetings.values
                    .every((item) => item is String || item is List))) {
      throw const FormatException('角色卡 alternate_greetings 必须是文本数组或旧版本地化文本');
    }
    if (data.containsKey('useTools') &&
        !(data['useTools'] is bool ||
            data['useTools'] == 0 ||
            data['useTools'] == 1)) {
      throw const FormatException('角色卡 useTools 必须是布尔值或 0/1');
    }
    final toolIds = data['toolIds'];
    if (toolIds != null &&
        !(toolIds is List && toolIds.every((item) => item is String))) {
      throw const FormatException('角色卡 toolIds 必须是文本数组');
    }
    for (final key in const ['worldBookJson', 'roleCardAssets']) {
      final source = data[key];
      if (source is! String || source.trim().isEmpty) continue;
      final nested = decode('{"embedded":$source}',
          depthLimit: key == 'worldBookJson' ? maxDerivedDepth + 1 : maxDepth,
          nodeLimit: key == 'worldBookJson' ? maxDerivedNodes : maxNodes,
          validateKnownFields: false)['embedded'];
      if (key == 'worldBookJson') {
        final entries = nested is Map ? nested['entries'] : nested;
        final unmapped = nested is Map ? nested['tavernUnmappedEntries'] : null;
        if (entries != null &&
            (entries is! List ||
                (unmapped != null && unmapped is! List) ||
                entries.length + (unmapped is List ? unmapped.length : 0) >
                    maxWorldBookEntries)) {
          throw const FormatException('结构化世界书 entries 必须是最多 1024 条的数组');
        }
      } else if (nested is! List || nested.length > 256) {
        throw const FormatException('本地资源清单必须是最多 256 项的数组');
      }
    }
    final assets = data['assets'];
    if (assets != null) {
      if (assets is! List || assets.length > 256) {
        throw const FormatException('角色卡资源必须是数组且不超过 256 项');
      }
      for (final asset in assets) {
        if (asset is! Map ||
            const ['type', 'uri', 'name', 'ext']
                .any((key) => asset[key] is! String)) {
          throw const FormatException('角色卡资源 type/uri/name/ext 必须是文本');
        }
      }
    }
    final book = data['character_book'] ?? data['characterBook'];
    if (book is Map && book.containsKey('entries')) {
      final entries = book['entries'];
      if (entries is! List && entries is! Map) {
        throw const FormatException('世界书 entries 必须是数组或旧版条目对象');
      }
      final values = entries is List ? entries : (entries as Map).values;
      if (values.length > maxWorldBookEntries) {
        throw const FormatException('世界书最多 1024 条');
      }
      for (final entry in values) {
        if (entry is! Map ||
            (entry.containsKey('content') && entry['content'] is! String)) {
          throw const FormatException('世界书条目必须是对象且 content 必须是文本');
        }
        if (entry.containsKey('extensions') && entry['extensions'] is! Map) {
          throw const FormatException('世界书条目 extensions 必须是对象');
        }
      }
    }
  }
}
