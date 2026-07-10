import 'dart:convert';

/// Quick Replies 的解析上限，避免外部 JSON 直接制造过大的内存结构。
class StoryQuickReplyLimits {
  const StoryQuickReplyLimits._();

  static const maxGroups = 32;
  static const maxItemsPerGroup = 64;
  static const maxItems = 256;
  static const maxKeyLength = 96;
  static const maxLabelLength = 80;
  static const maxContentLength = 4000;
}

/// 房间内可发送的一条快捷回复。
class StoryQuickReplyModel {
  String key;
  String label;
  String content;
  bool enabled;
  bool sendImmediately;
  int sortOrder;

  StoryQuickReplyModel({
    String? key,
    String label = '',
    String content = '',
    this.enabled = true,
    this.sendImmediately = false,
    this.sortOrder = 0,
  })  : label = _bounded(label, StoryQuickReplyLimits.maxLabelLength),
        content = _bounded(content, StoryQuickReplyLimits.maxContentLength),
        key = _bounded(
          _stableKey(key, label, content, fallback: 'reply'),
          StoryQuickReplyLimits.maxKeyLength,
        );

  factory StoryQuickReplyModel.fromJson(Map<String, dynamic> json) {
    final label = _stringOf(json['label']);
    final content = _stringOf(json['content']);
    return StoryQuickReplyModel(
      key: _stringOf(json['key']),
      label: label,
      content: content,
      enabled: _boolOf(json['enabled'], fallback: true),
      sendImmediately: _boolOf(json['sendImmediately']),
      sortOrder: _intOf(json['sortOrder']),
    );
  }

  /// 将当前条目的内容替换为本次发送所处的上下文。
  String resolveContent({
    String char = '',
    String user = '',
    String room = '',
    String input = '',
  }) {
    return replaceVariables(
      content,
      char: char,
      user: user,
      room: room,
      input: input,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'content': content,
        'enabled': enabled,
        'sendImmediately': sendImmediately,
        'sortOrder': sortOrder,
      };

  static String replaceVariables(
    String value, {
    String char = '',
    String user = '',
    String room = '',
    String input = '',
  }) {
    final replacements = <String, String>{
      'char': char,
      'user': user,
      'room': room,
      'input': input,
    };
    if (value.isEmpty) return value;

    final output = StringBuffer();
    var cursor = 0;
    while (cursor < value.length) {
      final start = value.indexOf('{{', cursor);
      if (start < 0) {
        output.write(value.substring(cursor));
        break;
      }
      output.write(value.substring(cursor, start));
      final end = value.indexOf('}}', start + 2);
      if (end < 0) {
        output.write(value.substring(start));
        break;
      }
      final name = value.substring(start + 2, end);
      final replacement = replacements[name];
      output.write(replacement ?? value.substring(start, end + 2));
      cursor = end + 2;
    }
    return output.toString();
  }

  static String _stableKey(
    String? key,
    String label,
    String content, {
    required String fallback,
  }) {
    final explicit = key?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final labelKey = label.trim();
    if (labelKey.isNotEmpty) return labelKey;
    final contentKey = content.trim();
    return contentKey.isNotEmpty ? contentKey : fallback;
  }
}

/// 房间级快捷回复分组。
class StoryQuickReplyGroupModel {
  int roomId;
  String key;
  String label;
  bool enabled;
  int sortOrder;
  List<StoryQuickReplyModel> items;

  StoryQuickReplyGroupModel({
    this.roomId = 0,
    String? key,
    String label = '',
    this.enabled = true,
    this.sortOrder = 0,
    List<StoryQuickReplyModel> items = const [],
  })  : label = _bounded(label, StoryQuickReplyLimits.maxLabelLength),
        key = _bounded(
          StoryQuickReplyModel._stableKey(key, label, '', fallback: 'group'),
          StoryQuickReplyLimits.maxKeyLength,
        ),
        items = List<StoryQuickReplyModel>.of(items);

  factory StoryQuickReplyGroupModel.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] is List
        ? json['items'] as List
        : json['replies'] is List
            ? json['replies'] as List
            : const [];
    final items = <StoryQuickReplyModel>[];
    final itemKeys = <String>{};
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      if (items.length >= StoryQuickReplyLimits.maxItemsPerGroup) break;
      final json = _mapOf(raw);
      if (json != null) {
        final item = StoryQuickReplyModel.fromJson(json);
        if (itemKeys.add(item.key)) items.add(item);
      }
    }
    return StoryQuickReplyGroupModel(
      roomId: _intOf(json['roomId']),
      key: _stringOf(json['key']),
      label: _bounded(
        _stringOf(json['label']),
        StoryQuickReplyLimits.maxLabelLength,
      ),
      enabled: _boolOf(json['enabled'], fallback: true),
      sortOrder: _intOf(json['sortOrder']),
      items: items,
    );
  }

  List<StoryQuickReplyModel> sortedItems({bool enabledOnly = false}) {
    final result = items
        .where((item) => !enabledOnly || item.enabled)
        .toList(growable: false);
    final sorted = List<StoryQuickReplyModel>.of(result);
    sorted.sort(_compareItems);
    return sorted;
  }

  Map<String, dynamic> toJson() => {
        'roomId': roomId,
        'key': key,
        'label': label,
        'enabled': enabled,
        'sortOrder': sortOrder,
        'items': [for (final item in items) item.toJson()],
      };

  static int _compareItems(
    StoryQuickReplyModel left,
    StoryQuickReplyModel right,
  ) {
    final order = left.sortOrder.compareTo(right.sortOrder);
    return order != 0 ? order : left.key.compareTo(right.key);
  }
}

/// 一个房间的全部快捷回复分组。
class StoryQuickReplyCollectionModel {
  int roomId;
  List<StoryQuickReplyGroupModel> groups;

  StoryQuickReplyCollectionModel({
    this.roomId = 0,
    List<StoryQuickReplyGroupModel> groups = const [],
  }) : groups = List<StoryQuickReplyGroupModel>.of(groups);

  factory StoryQuickReplyCollectionModel.fromJson(Map<String, dynamic> json) {
    final roomId = _intOf(json['roomId']);
    final rawGroups = json['groups'];
    final parsedGroups = <StoryQuickReplyGroupModel>[];
    final groupKeys = <String>{};
    if (rawGroups is List) {
      for (final raw in rawGroups) {
        if (raw is! Map) continue;
        if (parsedGroups.length >= StoryQuickReplyLimits.maxGroups) break;
        final json = _mapOf(raw);
        if (json == null) continue;
        final group = StoryQuickReplyGroupModel.fromJson(json);
        if (!groupKeys.add(group.key)) continue;
        if (group.roomId == 0 && roomId != 0) group.roomId = roomId;
        parsedGroups.add(group);
      }
    }
    _trimItems(parsedGroups);
    return StoryQuickReplyCollectionModel(roomId: roomId, groups: parsedGroups);
  }

  /// 解析任意外部 JSON，类型错误、非法 JSON 都会回落为空集合。
  static StoryQuickReplyCollectionModel tryParse(Object? raw) {
    if (raw is Map) {
      final json = _mapOf(raw);
      return json == null
          ? StoryQuickReplyCollectionModel()
          : StoryQuickReplyCollectionModel.fromJson(json);
    }
    if (raw is! String || raw.trim().isEmpty) {
      return StoryQuickReplyCollectionModel();
    }
    try {
      final decoded = jsonDecode(raw);
      return tryParse(decoded);
    } catch (_) {
      return StoryQuickReplyCollectionModel();
    }
  }

  static StoryQuickReplyCollectionModel fromJsonString(String raw) =>
      tryParse(raw);

  static StoryQuickReplyCollectionModel fromTavernExtensions(
    Map<String, dynamic> extensions, {
    int roomId = 0,
  }) {
    final raw = extensions['quick_replies'] ?? extensions['quickReplies'];
    if (raw == null) return StoryQuickReplyCollectionModel(roomId: roomId);
    final groups = <StoryQuickReplyGroupModel>[];
    final groupKeys = <String>{};
    final rawGroups = raw is List
        ? raw
        : raw is Map
            ? (raw['sets'] is List
                ? raw['sets'] as List
                : raw['groups'] is List
                    ? raw['groups'] as List
                    : [raw])
            : const [];
    for (var groupIndex = 0;
        groupIndex < rawGroups.length &&
            groups.length < StoryQuickReplyLimits.maxGroups;
        groupIndex++) {
      final groupMap = _mapOf(rawGroups[groupIndex]);
      final rawItems = groupMap == null
          ? const []
          : groupMap['items'] is List
              ? groupMap['items'] as List
              : groupMap['quickReplies'] is List
                  ? groupMap['quickReplies'] as List
                  : groupMap['replies'] is List
                      ? groupMap['replies'] as List
                      : const [];
      final items = <StoryQuickReplyModel>[];
      final itemKeys = <String>{};
      for (var itemIndex = 0;
          itemIndex < rawItems.length &&
              itemIndex < StoryQuickReplyLimits.maxItemsPerGroup;
          itemIndex++) {
        final item = _mapOf(rawItems[itemIndex]);
        if (item == null) continue;
        final content = _stringOf(
          item['content'] ?? item['message'] ?? item['text'] ?? item['command'],
        ).trim();
        if (content.isEmpty || _looksExecutable(content)) continue;
        final label = _stringOf(item['label'] ?? item['name'] ?? item['title']);
        final parsed = StoryQuickReplyModel(
          key: _stringOf(item['key'] ?? item['id']),
          label: label.trim().isEmpty ? content : label.trim(),
          content: content,
          enabled: _boolOf(item['enabled'], fallback: true),
          sendImmediately: _boolOf(
            item['sendImmediately'] ??
                item['autoExecute'] ??
                item['executeOnClick'],
          ),
          sortOrder: _intOf(item['sortOrder'] ?? item['order'] ?? itemIndex),
        );
        if (itemKeys.add(parsed.key)) items.add(parsed);
      }
      if (items.isEmpty) continue;
      final label = _stringOf(
        groupMap?['label'] ?? groupMap?['name'] ?? groupMap?['title'],
      );
      final parsedGroup = StoryQuickReplyGroupModel(
        roomId: roomId,
        key: _stringOf(groupMap?['key'] ?? groupMap?['id']),
        label: label.trim().isEmpty ? '快捷回复 ${groupIndex + 1}' : label,
        enabled: _boolOf(groupMap?['enabled'], fallback: true),
        sortOrder: _intOf(groupMap?['sortOrder'] ?? groupIndex),
        items: items,
      );
      if (groupKeys.add(parsedGroup.key)) groups.add(parsedGroup);
    }
    _trimItems(groups);
    return StoryQuickReplyCollectionModel(roomId: roomId, groups: groups);
  }

  List<StoryQuickReplyGroupModel> sortedGroups({
    bool enabledOnly = false,
    int? forRoomId,
  }) {
    final result = groups
        .where((group) =>
            (!enabledOnly || group.enabled) &&
            (forRoomId == null || group.roomId == forRoomId))
        .toList(growable: false);
    final sorted = List<StoryQuickReplyGroupModel>.of(result);
    sorted.sort(_compareGroups);
    return sorted;
  }

  List<StoryQuickReplyModel> itemsForGroup(
    String groupKey, {
    bool enabledOnly = false,
  }) {
    for (final group in groups) {
      if (group.key == groupKey) {
        return group.sortedItems(enabledOnly: enabledOnly);
      }
    }
    return const [];
  }

  List<StoryQuickReplyModel> filterItems({
    String? groupKey,
    bool enabledOnly = true,
  }) {
    final result = <StoryQuickReplyModel>[];
    for (final group in sortedGroups(enabledOnly: enabledOnly)) {
      if (groupKey != null && group.key != groupKey) continue;
      result.addAll(group.sortedItems(enabledOnly: enabledOnly));
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'roomId': roomId,
        'groups': [for (final group in groups) group.toJson()],
      };

  String toJsonString() => jsonEncode(toJson());

  static int _compareGroups(
    StoryQuickReplyGroupModel left,
    StoryQuickReplyGroupModel right,
  ) {
    final order = left.sortOrder.compareTo(right.sortOrder);
    return order != 0 ? order : left.key.compareTo(right.key);
  }

  static void _trimItems(List<StoryQuickReplyGroupModel> groups) {
    var total = 0;
    for (final group in groups) {
      if (group.items.length > StoryQuickReplyLimits.maxItemsPerGroup) {
        group.items =
            group.items.take(StoryQuickReplyLimits.maxItemsPerGroup).toList();
      }
      final remaining = StoryQuickReplyLimits.maxItems - total;
      if (remaining <= 0) {
        group.items = [];
      } else if (group.items.length > remaining) {
        group.items = group.items.take(remaining).toList();
      }
      total += group.items.length;
    }
  }
}

bool _looksExecutable(String content) {
  final value = content.trimLeft();
  return value.startsWith('/') ||
      value.contains('<script') ||
      value.contains('```javascript') ||
      value.contains('```js');
}

String _bounded(String value, int maxLength) {
  final trimmed = value.trim();
  return trimmed.length <= maxLength
      ? trimmed
      : trimmed.substring(0, maxLength);
}

typedef StoryQuickReplyItem = StoryQuickReplyModel;
typedef StoryQuickReplyGroup = StoryQuickReplyGroupModel;
typedef StoryQuickReplyCatalog = StoryQuickReplyCollectionModel;

String _stringOf(Object? value) => value is String ? value : '';

Map<String, dynamic>? _mapOf(Object? value) {
  if (value is! Map) return null;
  try {
    return Map<String, dynamic>.from(value);
  } catch (_) {
    return null;
  }
}

int _intOf(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

bool _boolOf(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return fallback;
}
