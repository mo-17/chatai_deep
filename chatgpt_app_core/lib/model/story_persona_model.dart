import 'dart:math';

/// Persona 持久化字段的边界，避免外部 JSON 或同步数据制造过大记录。
class StoryPersonaLimits {
  const StoryPersonaLimits._();

  static const maxPersonaKeyLength = 120;
  static const maxNameLength = 160;
  static const maxDescriptionLength = 12000;
  static const maxAvatarTypeLength = 32;
  static const maxAvatarValueLength = 2048;
}

/// 可跨设备同步的用户 Persona。
///
/// [id] 仅是本地 SQLite 主键；[personaKey] 才是持久化及同步时的稳定身份。
class StoryPersonaModel {
  int? id;
  String personaKey;
  String name;
  String description;
  String avatarType;
  String avatarValue;
  int createdAt;
  int updatedAt;

  StoryPersonaModel({
    this.id,
    String? personaKey,
    String name = '',
    String description = '',
    String avatarType = 'emoji',
    String avatarValue = '🙂',
    int? createdAt,
    int? updatedAt,
  })  : personaKey = _normalizeKey(personaKey) ?? newPersonaKey(),
        name = _boundedName(name),
        description = _boundedDescription(description),
        avatarType = _boundedAvatarType(avatarType),
        avatarValue = _boundedAvatarValue(avatarValue),
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  /// 兼容早期草稿中的 `key`、`title`、`content` 与 `avatar` 字段。
  factory StoryPersonaModel.fromJson(Map<String, dynamic> json) {
    final avatar = json['avatar'];
    final legacyAvatar = avatar is Map
        ? Map<String, dynamic>.from(avatar)
        : const <String, dynamic>{};
    final name = _stringOf(json['name'] ?? json['title']);
    final description = _stringOf(json['description'] ??
        json['content'] ??
        json['persona'] ??
        json['prompt']);
    final avatarValue = _stringOf(
      json['avatarValue'] ??
          legacyAvatar['value'] ??
          (avatar is String ? avatar : null),
    );
    return StoryPersonaModel(
      id: _intOf(json['id']),
      personaKey: _stringOf(json['personaKey'] ?? json['key']).isEmpty
          ? legacyPersonaKey(
              name: name,
              description: description,
              avatarType: _stringOf(json['avatarType'] ?? legacyAvatar['type']),
              avatarValue: avatarValue,
            )
          : _stringOf(json['personaKey'] ?? json['key']),
      name: name,
      description: description,
      avatarType: _stringOf(json['avatarType'] ?? legacyAvatar['type']),
      avatarValue: avatarValue,
      createdAt: _intOf(json['createdAt'] ?? json['created_at']),
      updatedAt: _intOf(json['updatedAt'] ?? json['updated_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'personaKey': personaKey,
        'name': name,
        'description': description,
        'avatarType': avatarType,
        'avatarValue': avatarValue,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  /// 在 DAO 写入前再次归一化，防止调用方直接修改可变字段后绕开边界。
  void normalize() {
    personaKey = _normalizeKey(personaKey) ?? newPersonaKey();
    name = _boundedName(name);
    description = _boundedDescription(description);
    avatarType = _boundedAvatarType(avatarType);
    avatarValue = _boundedAvatarValue(avatarValue);
  }

  static String newPersonaKey() {
    final random = Random.secure();
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final entropy =
        List.generate(3, (_) => random.nextInt(0x100000000).toRadixString(36))
            .join();
    return 'persona-$timestamp-$entropy';
  }

  /// 缺少 key 的旧 JSON 没有可同步身份；以内容生成确定性回退值，保证重复读取不漂移。
  static String legacyPersonaKey({
    required String name,
    required String description,
    required String avatarType,
    required String avatarValue,
  }) {
    var hash = 0x811c9dc5;
    for (final unit
        in '$name\u0000$description\u0000$avatarType\u0000$avatarValue'
            .codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'legacy-persona-${hash.toRadixString(36)}';
  }

  static String? _normalizeKey(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty ||
        value.length > StoryPersonaLimits.maxPersonaKeyLength ||
        _hasUnsafeControl(value)) {
      return null;
    }
    return value;
  }

  static String _boundedName(String raw) {
    final sanitized = _stripControls(raw, replaceWithSpace: true).trim();
    final value = sanitized.substring(
        0, min(sanitized.length, StoryPersonaLimits.maxNameLength));
    return value.isEmpty ? '未命名人设' : value;
  }

  static String _boundedDescription(String raw) {
    final sanitized = _stripControls(raw);
    return sanitized.substring(
        0, min(sanitized.length, StoryPersonaLimits.maxDescriptionLength));
  }

  static String _boundedAvatarType(String raw) {
    final sanitized = _stripControls(raw, replaceWithSpace: true).trim();
    final value = sanitized.substring(
        0, min(sanitized.length, StoryPersonaLimits.maxAvatarTypeLength));
    return value.isEmpty ? 'emoji' : value;
  }

  static String _boundedAvatarValue(String raw) {
    final sanitized = _stripControls(raw);
    return sanitized.substring(
        0, min(sanitized.length, StoryPersonaLimits.maxAvatarValueLength));
  }

  static String _stripControls(String raw, {bool replaceWithSpace = false}) =>
      raw.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
          replaceWithSpace ? ' ' : '');

  static bool _hasUnsafeControl(String value) =>
      value.contains(RegExp(r'[\x00-\x1F\x7F]'));

  static String _stringOf(Object? raw) => raw is String ? raw : '';

  static int? _intOf(Object? raw) =>
      raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
}

class StoryPersonaVariables {
  const StoryPersonaVariables._();

  static String resolve(String value, {required String userName}) {
    final name = userName.trim().isEmpty ? '我' : userName.trim();
    return value
        .replaceAll(
          RegExp(r'\{\{\s*user\s*\}\}', caseSensitive: false),
          name,
        )
        .replaceAll(RegExp(r'<USER>', caseSensitive: false), name);
  }
}
