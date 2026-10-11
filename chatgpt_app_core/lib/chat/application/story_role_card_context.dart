import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'assistant_role_card_service.dart';
import 'role_card_validation.dart';
import 'story_artifact_context_builder.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';

/// 保存原卡展示原文，独立保存受支持字段。hash 仅校验一致性，不能代替类型校验。
class StoryRoleCardContext {
  static const unavailableNotice = '旧角色卡上下文暂未加载，重新导入可恢复';
  static const maxBytes = 8 * 1024 * 1024;
  final bool isCardSource;
  final bool valid;
  final String publicText;
  final String artifactSuffix;
  final Map<String, StoryRoleCardBinding> roles;
  const StoryRoleCardContext._(
      this.isCardSource, this.valid, this.publicText, this.roles,
      [this.artifactSuffix = '']);
  bool get degraded => isCardSource && !valid;

  String get basePublicText =>
      publicText.substring(0, publicText.length - artifactSuffix.length);

  static String digest(String text) =>
      sha256.convert(utf8.encode(text)).toString();
  static String participantFingerprint(StoryParticipantModel p) =>
      digest(jsonEncode({
        'key': p.participantKey,
        'name': p.name,
        'role': p.role,
        'prompt': p.prompt,
        'enabled': p.enabled,
      }));

  static StoryRoleCardContext read(StoryRoomModel room,
      {List<StoryParticipantModel>? participants}) {
    final raw = room.roleCardContextJson;
    final cardSource = raw.trim().isNotEmpty ||
        room.publicContext.contains('【Tavern 原卡信息') ||
        room.publicContext.contains('【角色卡：') ||
        room.publicContext.contains('【角色卡说明】');
    if (!cardSource) {
      return StoryRoleCardContext._(
          false, true, withoutWorldBook(room.publicContext), const {});
    }
    try {
      final data = _decode(raw);
      if (data['publicContextHash'] != digest(room.publicContext)) {
        throw const FormatException('角色公共文本已变化');
      }
      final suffix = data['artifactSuffix'] as String;
      if (!room.publicContext.endsWith(suffix) ||
          !(data['publicText'] as String).endsWith(suffix)) {
        throw const FormatException('工作台资料后缀已变化');
      }
      final roles = <String, StoryRoleCardBinding>{};
      for (final item in (data['roles'] as List)) {
        final row = item as Map<String, dynamic>;
        final key = row['participantKey'] as String;
        if (roles.containsKey(key)) throw const FormatException('角色绑定重复');
        roles[key] = StoryRoleCardBinding(row);
      }
      if (participants == null ||
          participants.length != roles.length ||
          participants.map((p) => p.participantKey).toSet().length !=
              roles.length) {
        throw const FormatException('角色列表已变化');
      }
      for (final p in participants) {
        if (roles[p.participantKey]?.fingerprint != participantFingerprint(p)) {
          throw const FormatException('角色绑定已变化');
        }
      }
      return StoryRoleCardContext._(
          true, true, data['publicText'] as String, roles, suffix);
    } catch (_) {
      return const StoryRoleCardContext._(true, false, '', {});
    }
  }

  /// 导入时只读取已经验证的模型字段，不解析平文作者信息章节。
  static String create(
      {required StoryRoomModel room,
      required String publicText,
      required Map<StoryParticipantModel, AssistantModel> sources,
      Map<StoryParticipantModel, AssistantRoleCardTavernMeta?> meta =
          const {}}) {
    final data = <String, dynamic>{
      'version': 1,
      'publicContextHash': digest(room.publicContext),
      'publicText': publicText,
      'artifactSuffix': '',
      'roles': [
        for (final pair in sources.entries)
          _role(pair.key, pair.value, meta[pair.key])
      ]
    };
    final encoded = jsonEncode(data);
    _decode(encoded); // 同一预算适用于生成、外部备份及重新读取。
    return encoded;
  }

  static Map<String, dynamic> _role(StoryParticipantModel p,
      AssistantModel source, AssistantRoleCardTavernMeta? givenMeta) {
    final meta =
        givenMeta ?? AssistantRoleCardService.tavernMetaFromAssistant(source);
    final entries = WorldBookCodec.decode(
        structuredJson: source.worldBookJson,
        legacyText:
            AssistantRoleCardService.memoryBookForRuntime(source.memoryBook));
    return {
      'participantKey': p.participantKey,
      'fingerprint': participantFingerprint(p),
      'sourceFingerprint': digest(jsonEncode({
        'prompt': source.prompt,
        'worldBookJson': source.worldBookJson,
        'memoryBook': source.memoryBook
      })),
      'creatorNotes': meta?.creatorNotes ?? '',
      'depthText': meta?.characterDepthPrompt ?? '',
      'depth': (meta?.characterDepthPromptDepth ?? 4).clamp(0, 100),
      'depthRole': _roleName(meta?.characterDepthPromptRole ?? ''),
      'scanDepth': (meta?.characterBookScanDepth ?? 6).clamp(0, 50),
      'tokenBudget': meta?.characterBookTokenBudget,
      'recursive': meta?.characterBookRecursiveScanning ?? false,
      'entries': [
        for (var index = 0; index < entries.length; index++)
          {
            ...entries[index].toJson(),
            'id':
                '${p.participantKey}:${digest(entries[index].id.isEmpty ? '$index' : entries[index].id)}'
          }
      ]
    };
  }

  static String _roleName(String raw) {
    final value = raw.trim().toLowerCase();
    if (value == 'user' || value == 'human') return 'user';
    if (value == 'assistant' || value == 'char' || value == 'character') {
      return 'assistant';
    }
    return 'system';
  }

  static Map<String, dynamic> _decode(String raw) {
    if (raw.isEmpty || utf8.encode(raw).length > maxBytes) {
      throw const FormatException('角色运行时上下文过大或为空');
    }
    final data = RoleCardValidation.decode(raw,
        depthLimit: 8, nodeLimit: 100000, validateKnownFields: false);
    _keys(data, {
      'version',
      'publicContextHash',
      'publicText',
      'roles',
      'artifactSuffix'
    });
    if (data['version'] is! int || data['version'] != 1) {
      throw const FormatException('角色上下文版本无效');
    }
    _hash(data['publicContextHash']);
    _text(data['publicText']);
    _text(data['artifactSuffix'], max: 120 * 1024);
    final suffix = data['artifactSuffix'] as String;
    if (suffix.isNotEmpty &&
        !suffix.startsWith('\n\n${StoryArtifactContextBuilder.marker}')) {
      throw const FormatException('工作台资料后缀格式无效');
    }
    final roles = data['roles'];
    if (roles is! List || roles.isEmpty || roles.length > 64) {
      throw const FormatException('角色上下文绑定数量无效');
    }
    var entriesCount = 0;
    final ids = <String>{};
    final roleKeys = <String>{};
    final schema = const WorldBookEntry(content: '').toJson();
    for (final role in roles) {
      if (role is! Map<String, dynamic>) {
        throw const FormatException('角色绑定格式无效');
      }
      _keys(role, {
        'participantKey',
        'fingerprint',
        'sourceFingerprint',
        'creatorNotes',
        'depthText',
        'depth',
        'depthRole',
        'scanDepth',
        'tokenBudget',
        'recursive',
        'entries'
      });
      _text(role['participantKey'], max: 256);
      if (!roleKeys.add(role['participantKey'] as String)) {
        throw const FormatException('角色绑定重复');
      }
      if ((role['participantKey'] as String).trim().isEmpty) {
        throw const FormatException('角色键为空');
      }
      _hash(role['fingerprint']);
      _hash(role['sourceFingerprint']);
      _text(role['creatorNotes']);
      _text(role['depthText']);
      _integer(role['depth'], 0, 100);
      _integer(role['scanDepth'], 0, 50);
      if (!const ['system', 'user', 'assistant'].contains(role['depthRole']) ||
          role['recursive'] is! bool) {
        throw const FormatException('角色参数无效');
      }
      if (role['tokenBudget'] != null) {
        _integer(role['tokenBudget'], 0, 1000000);
      }
      final entries = role['entries'];
      if (entries is! List || (entriesCount += entries.length) > 1024) {
        throw const FormatException('角色世界书超过1024条');
      }
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('世界书规则格式无效');
        }
        _keys(entry, schema.keys.toSet());
        for (final field in schema.entries) {
          final value = entry[field.key];
          final kind = field.value;
          if (kind is String) {
            _text(value);
          } else if (kind is bool) {
            if (value is! bool) {
              throw const FormatException('世界书布尔值无效');
            }
          } else if (kind is int) {
            _integer(value, -1000000, 1000000);
          } else if (kind is List) {
            if (value is! List || value.length > 256) {
              throw const FormatException('世界书关键词过多');
            }
            for (final text in value) {
              _text(text, max: 4096);
            }
          } else if (value != null) {
            _integer(value, 0, 1000000);
          }
        }
        if (!(entry['id'] as String).startsWith('${role['participantKey']}:') ||
            !ids.add(entry['id'] as String)) {
          throw const FormatException('世界书身份无效或重复');
        }
        _integer(entry['selectiveLogic'], 0, 3);
      }
    }
    return data;
  }

  static void _keys(Map<String, dynamic> row, Set<String> keys) {
    if (row.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(row.keys.toSet()).isNotEmpty) {
      throw const FormatException('角色上下文字段无效');
    }
  }

  static void _hash(Object? value) {
    if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('角色上下文指纹无效');
    }
  }

  static void _text(Object? value, {int max = 2 * 1024 * 1024}) {
    if (value is! String || utf8.encode(value).length > max) {
      throw const FormatException('角色上下文正文无效');
    }
  }

  static void _integer(Object? value, int min, int max) {
    if (value is! int || value < min || value > max) {
      throw const FormatException('角色上下文整数无效');
    }
  }

  static String withoutWorldBook(String source) {
    final start = source.indexOf('【关键词记忆 / 世界书】');
    if (start < 0) return source;
    final next = RegExp(r'\n【[^\n]+】')
        .firstMatch(source.substring(start + '【关键词记忆 / 世界书】'.length));
    final end = next == null
        ? source.length
        : start + '【关键词记忆 / 世界书】'.length + next.start;
    return (source.substring(0, start) + source.substring(end)).trim();
  }

  /// 工作台可信资料更新只续接已有效的投影；失配数据不重签 hash。
  static StoryRoomModel withArtifacts(
      StoryRoomModel source,
      List<StoryParticipantModel> participants,
      List<StoryArtifactModel> artifacts) {
    final next = StoryRoomModel.fromJson(source.toJson());
    final projection = read(source, participants: participants);
    if (!projection.isCardSource) {
      next.publicContext = StoryArtifactContextBuilder.mergeIntoPublicContext(
          source.publicContext, artifacts);
    } else if (projection.valid) {
      final data = _decode(source.roleCardContextJson);
      final generated = StoryArtifactContextBuilder.build(artifacts);
      final suffix = generated.isEmpty ? '' : '\n\n$generated';
      // 不 trim，不搜索正文中的 marker；只移除已记录且双正文确切匹配的尾部。
      next.publicContext = source.publicContext.substring(0,
              source.publicContext.length - projection.artifactSuffix.length) +
          suffix;
      data['publicText'] = projection.basePublicText + suffix;
      data['artifactSuffix'] = suffix;
      data['publicContextHash'] = digest(next.publicContext);
      final encoded = jsonEncode(data);
      _decode(encoded);
      next.roleCardContextJson = encoded;
    }
    // 旧卡/损坏/失配的原文保持原样，工作台仍可独立传入 artifacts。
    return next;
  }
}

class StoryRoleCardBinding {
  final Map<String, dynamic> row;
  const StoryRoleCardBinding(this.row);
  String get fingerprint => row['fingerprint'] as String;
  String get creatorNotes => row['creatorNotes'] as String;
  String get depthText => row['depthText'] as String;
  int get depth => row['depth'] as int;
  String get depthRole => row['depthRole'] as String;
  int get scanDepth => row['scanDepth'] as int;
  int? get tokenBudget => row['tokenBudget'] as int?;
  bool get recursive => row['recursive'] as bool;
  List<WorldBookEntry> get entries => [
        for (final item in row['entries'] as List)
          WorldBookEntry.fromJson(item as Map<String, dynamic>)
      ];
}
