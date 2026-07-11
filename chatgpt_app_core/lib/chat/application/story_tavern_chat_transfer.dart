import 'dart:convert';

import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

/// SillyTavern JSONL 的受限解析、导入计划和活动路径导出。
class StoryTavernChatTransfer {
  static const maxSourceBytes = 5 * 1024 * 1024;
  static const maxLines = 10000;
  static const maxLineBytes = 128 * 1024;
  static const maxMessageChars = 64 * 1024;
  static const maxJsonDepth = 32;
  static const maxJsonStringChars = 64 * 1024;

  const StoryTavernChatTransfer._();

  static StoryTavernChatPreview previewJsonl(String source) {
    final warnings = <String>[];
    if (utf8.encode(source).length > maxSourceBytes) {
      return StoryTavernChatPreview.rejected(
          '文件超过 ${maxSourceBytes ~/ 1024}KB 限制。');
    }
    final normalizedSource =
        source.startsWith('\uFEFF') ? source.substring(1) : source;
    final lines = const LineSplitter().convert(normalizedSource);
    if (lines.length > maxLines) {
      return StoryTavernChatPreview.rejected('文件超过 $maxLines 行限制。');
    }
    final headerIndex = lines.indexWhere((line) => line.trim().isNotEmpty);
    if (headerIndex < 0) {
      return StoryTavernChatPreview.rejected('JSONL 缺少 SillyTavern header。');
    }
    if (headerIndex > 0) warnings.add('文件开头的 $headerIndex 个空行已跳过。');

    final header = _decodeLine(lines[headerIndex], headerIndex + 1);
    if (header is! Map<String, dynamic> ||
        !(header['chat_metadata'] is Map ||
            header.containsKey('user_name') ||
            header.containsKey('character_name'))) {
      return StoryTavernChatPreview.rejected('首行不是 SillyTavern 聊天 header。');
    }
    final headerJson = _boundedJson(header, 'header');
    if (headerJson == null) {
      return StoryTavernChatPreview.rejected('header 的 JSON 深度或字段长度超过限制。');
    }

    var userName = _usableHeaderName(header['user_name']);
    var characterName = _usableHeaderName(header['character_name']);
    final headerCharacterName = characterName;
    final parsed = <_ParsedRecord>[];
    final participantNames = <String>[];
    String? activeParentNodeKey;
    var acceptedMessageOrdinal = 0;

    for (var index = headerIndex + 1; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty) {
        warnings.add('第 ${index + 1} 行为空，已跳过。');
        continue;
      }
      if (utf8.encode(line).length > maxLineBytes) {
        return StoryTavernChatPreview.rejected(
            '第 ${index + 1} 行超过单行大小限制。', warnings);
      }
      final raw = _decodeLine(line, index + 1);
      if (raw is! Map<String, dynamic>) {
        return StoryTavernChatPreview.rejected(
            '第 ${index + 1} 行不是 JSON 对象。', warnings);
      }
      if (_boundedJson(raw, 'message') == null) {
        return StoryTavernChatPreview.rejected(
            '第 ${index + 1} 行 JSON 深度或字段长度超过限制。', warnings);
      }
      if (raw['is_system'] == true) {
        warnings.add('第 ${index + 1} 行 is_system 消息已跳过，未映射为 OpenAI system。');
        continue;
      }
      final content = _string(raw['mes']);
      if (content.length > maxMessageChars) {
        return StoryTavernChatPreview.rejected(
            '第 ${index + 1} 行 mes 超过单消息长度限制。', warnings);
      }
      final name = _string(raw['name']).trim();
      final isUser = raw['is_user'] == true;
      if (isUser && userName.isEmpty && name.isNotEmpty) userName = name;
      if (!isUser && characterName.isEmpty && name.isNotEmpty) {
        characterName = name;
      }
      if (content.isEmpty && !_hasUsableSwipes(raw['swipes'])) {
        warnings.add('第 ${index + 1} 行没有 mes 或 swipes，已跳过。');
        continue;
      }
      if (!isUser && name.isEmpty) {
        warnings.add('第 ${index + 1} 行缺少角色 name，已跳过。');
        continue;
      }
      if (!isUser && !participantNames.contains(name)) {
        participantNames.add(name);
      }

      final groupKey =
          'tavern-group-${acceptedMessageOrdinal + 1}-${StoryMessageModel.newNodeKey()}';
      final choices = _swipeChoices(raw, content, index + 1, warnings);
      final selectedIndex = _selectedSwipeIndex(
          raw['swipe_id'], choices, content, index + 1, warnings);
      // SillyTavern 以 mes 作为当前活动回复；部分旧导出的
      // swipes[swipe_id] 可能没有同步更新，以可见文本为准。
      if (content.isNotEmpty) choices[selectedIndex] = content;
      final extraJson = _boundedJson(raw['extra'], 'extra') ?? '';
      final swipeInfoJson = _boundedJson(raw['swipe_info'], 'swipe_info') ?? '';
      final createdAt = _parseSendDate(raw['send_date']);
      final candidates = <StoryMessageModel>[];
      for (var swipeIndex = 0; swipeIndex < choices.length; swipeIndex++) {
        candidates.add(StoryMessageModel(
          roomId: 0,
          speakerRole: isUser ? 'user' : StoryParticipantRole.assistant,
          speakerName: isUser ? (name.isEmpty ? userName : name) : name,
          content: choices[swipeIndex],
          nodeKey:
              'tavern-node-${acceptedMessageOrdinal + 1}-$swipeIndex-${StoryMessageModel.newNodeKey()}',
          parentNodeKey: activeParentNodeKey,
          candidateGroupKey: groupKey,
          tavernExtraJson: extraJson,
          tavernSwipeInfoJson: swipeInfoJson,
          createdAt: createdAt,
          updatedAt: createdAt,
        ));
      }
      final active = candidates[selectedIndex];
      activeParentNodeKey = active.nodeKey;
      parsed.add(_ParsedRecord(candidates));
      acceptedMessageOrdinal++;
    }

    final messages = [for (final record in parsed) ...record.candidates];
    if (messages.isEmpty) {
      return StoryTavernChatPreview.rejected('没有可导入的非 system 有效消息。', warnings);
    }
    if (participantNames.isEmpty) {
      warnings.add('未发现角色消息；将导入为单角色酒馆房间。');
    }
    final participants = <StoryParticipantModel>[
      for (var index = 0; index < participantNames.length; index++)
        StoryParticipantModel(
          roomId: 0,
          role: StoryParticipantRole.assistant,
          name: participantNames[index],
          sortOrder: index,
        ),
    ];
    final title = headerCharacterName.isNotEmpty
        ? headerCharacterName
        : (participantNames.isNotEmpty ? participantNames.join('、') : '导入酒馆聊天');
    final plan = StoryTavernChatImportPlan(
      room: StoryRoomModel(
        title: title,
        mode: StoryRoomMode.tavern,
        replyMode: participantNames.length > 1
            ? StoryReplyMode.autoMulti
            : StoryReplyMode.autoSingle,
        maxAutoReplies: participantNames.length > 1
            ? participantNames.length.clamp(1, 3)
            : 1,
        activeMessageKey: activeParentNodeKey,
        tavernChatMetadataJson: headerJson,
      ),
      participants: participants,
      messages: messages,
      userName: userName,
      characterName: characterName,
      personaSnapshot:
          userName.isEmpty ? null : StoryTavernPersonaSnapshot(name: userName),
      warnings: warnings,
    );
    return StoryTavernChatPreview.accepted(plan);
  }

  /// 由调用方决定何时执行，DAO 保证房间、角色和消息不会半导入。
  static Future<int> persistPlan(
    StoryRoomDao dao,
    StoryTavernChatImportPlan plan,
  ) async {
    StoryPersonaModel? persona;
    final snapshot = plan.personaSnapshot;
    if (snapshot != null && snapshot.name.trim().isNotEmpty) {
      await StoryPersonaDao.create(dao.storage);
      persona = StoryPersonaModel(
        name: snapshot.name.trim(),
        description: '从 SillyTavern 聊天记录导入的 Persona 快照。',
      );
      plan.room.personaKey = persona.personaKey;
      for (final message in plan.messages.where((item) => item.isUser)) {
        message
          ..speakerName = persona.name
          ..speakerPersonaKey = persona.personaKey
          ..speakerAvatarType = persona.avatarType
          ..speakerAvatarValue = persona.avatarValue;
      }
    }
    return dao.saveTavernImport(
      room: plan.room,
      participants: plan.participants,
      messages: plan.messages,
      persona: persona,
    );
  }

  static Future<String> exportJsonl(StoryRoomDao dao, int roomId) async {
    final room = await dao.getRoom(roomId);
    if (room == null) throw ArgumentError('找不到 StoryRoom: $roomId');
    final header =
        _decodeStoredJson(room.tavernChatMetadataJson) ?? <String, dynamic>{};
    final activePath = await dao.getActiveMessages(roomId);
    String? inferredUserName;
    String? inferredCharacterName;
    for (final message in activePath) {
      final name = message.speakerName.trim();
      if (name.isEmpty) continue;
      if (message.isUser) {
        inferredUserName ??= name;
      } else {
        inferredCharacterName ??= name;
      }
    }
    final userName = _usableHeaderName(header['user_name']).isNotEmpty
        ? _usableHeaderName(header['user_name'])
        : inferredUserName ?? '';
    final characterName = _usableHeaderName(header['character_name']).isNotEmpty
        ? _usableHeaderName(header['character_name'])
        : inferredCharacterName ?? room.title;
    final allMessages = await dao.getMessages(roomId);
    final byGroup = <String, List<StoryMessageModel>>{};
    for (final message in allMessages) {
      final key = message.candidateGroupKey ?? message.nodeKey;
      (byGroup[key] ??= []).add(message);
    }
    final output = <String>[];
    output.add(jsonEncode({
      ...header,
      'chat_metadata': header['chat_metadata'] is Map
          ? header['chat_metadata']
          : <String, dynamic>{},
      'user_name': userName,
      'character_name': characterName,
    }));
    for (final active in activePath) {
      final variants = List<StoryMessageModel>.from(
        byGroup[active.candidateGroupKey ?? active.nodeKey] ?? [active],
      )..sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      final swipeId =
          variants.indexWhere((variant) => variant.nodeKey == active.nodeKey);
      output.add(jsonEncode({
        'name': active.speakerName,
        'is_user': active.isUser,
        'is_system': false,
        'send_date': active.createdAt,
        'mes': active.content,
        if (variants.length > 1)
          'swipes': variants.map((variant) => variant.content).toList(),
        if (variants.length > 1) 'swipe_id': swipeId < 0 ? 0 : swipeId,
        if (variants.length > 1 &&
            _decodeStoredJson(active.tavernSwipeInfoJson) != null)
          'swipe_info': _decodeStoredJson(active.tavernSwipeInfoJson),
        if (_decodeStoredJson(active.tavernExtraJson) != null)
          'extra': _decodeStoredJson(active.tavernExtraJson),
      }));
    }
    return output.join('\n');
  }

  static dynamic _decodeLine(String line, int lineNumber) {
    try {
      return jsonDecode(line);
    } catch (_) {
      return null;
    }
  }

  static String _string(Object? value) => value is String ? value : '';

  static String _usableHeaderName(Object? value) {
    final name = _string(value).trim();
    return name.toLowerCase() == 'unused' ? '' : name;
  }

  static bool _hasUsableSwipes(Object? raw) =>
      raw is List && raw.any((item) => item is String && item.isNotEmpty);

  static List<String> _swipeChoices(
    Map<String, dynamic> raw,
    String content,
    int lineNumber,
    List<String> warnings,
  ) {
    final swipes = raw['swipes'];
    if (swipes is! List) return [content];
    final choices = <String>[];
    for (final swipe in swipes) {
      if (swipe is String && swipe.length <= maxMessageChars) {
        choices.add(swipe);
      } else {
        warnings.add('第 $lineNumber 行存在无效或过长 swipe，已跳过。');
      }
    }
    if (choices.isEmpty) return [content];
    return choices;
  }

  static int _selectedSwipeIndex(
    Object? raw,
    List<String> choices,
    String content,
    int lineNumber,
    List<String> warnings,
  ) {
    final value = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (value == null || value < 0 || value >= choices.length) {
      final visibleIndex = content.isEmpty ? -1 : choices.indexOf(content);
      final fallback = visibleIndex < 0 ? 0 : visibleIndex;
      if (raw != null) {
        warnings.add('第 $lineNumber 行 swipe_id 无效，已根据 mes 恢复当前候选。');
      }
      return fallback;
    }
    return value;
  }

  static int _parseSendDate(Object? value) {
    if (value is num) return _normalizeEpoch(value.toInt());
    final number = int.tryParse('$value');
    if (number != null) return _normalizeEpoch(number);
    return DateTime.tryParse('$value')?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
  }

  static int _normalizeEpoch(int value) {
    final magnitude = value.abs();
    if (magnitude >= 1000000000 && magnitude < 100000000000) {
      return value * 1000;
    }
    return value;
  }

  static String? _boundedJson(Object? value, String label) {
    if (value == null) return '';
    if (!_isBoundedJson(value, 0)) return null;
    final encoded = jsonEncode(value);
    return encoded.length <= maxLineBytes ? encoded : null;
  }

  static bool _isBoundedJson(Object? value, int depth) {
    if (depth > maxJsonDepth) return false;
    if (value is String) return value.length <= maxJsonStringChars;
    if (value is num || value is bool || value == null) return true;
    if (value is List) {
      return value.every((item) => _isBoundedJson(item, depth + 1));
    }
    if (value is Map) {
      return value.entries.every((entry) =>
          entry.key is String &&
          (entry.key as String).length <= maxJsonStringChars &&
          _isBoundedJson(entry.value, depth + 1));
    }
    return false;
  }

  static Map<String, dynamic>? _decodeStoredJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

class StoryTavernChatPreview {
  final StoryTavernChatImportPlan? plan;
  final String? error;
  final List<String> warnings;

  const StoryTavernChatPreview._(
      {this.plan, this.error, this.warnings = const []});

  bool get isAccepted => plan != null;

  factory StoryTavernChatPreview.accepted(StoryTavernChatImportPlan plan) =>
      StoryTavernChatPreview._(plan: plan, warnings: plan.warnings);

  factory StoryTavernChatPreview.rejected(String error,
          [List<String> warnings = const []]) =>
      StoryTavernChatPreview._(
          error: error, warnings: List.unmodifiable(warnings));
}

class StoryTavernChatImportPlan {
  final StoryRoomModel room;
  final List<StoryParticipantModel> participants;
  final List<StoryMessageModel> messages;
  final String userName;
  final String characterName;
  final StoryTavernPersonaSnapshot? personaSnapshot;
  final List<String> warnings;

  StoryTavernChatImportPlan({
    required this.room,
    required List<StoryParticipantModel> participants,
    required List<StoryMessageModel> messages,
    required this.userName,
    required this.characterName,
    required this.personaSnapshot,
    required List<String> warnings,
  })  : participants = List.unmodifiable(participants),
        messages = List.unmodifiable(messages),
        warnings = List.unmodifiable(warnings);
}

class StoryTavernPersonaSnapshot {
  final String name;

  const StoryTavernPersonaSnapshot({required this.name});
}

class _ParsedRecord {
  final List<StoryMessageModel> candidates;

  const _ParsedRecord(this.candidates);
}
