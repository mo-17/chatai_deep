import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

import 'assistant_role_card_service.dart';

class StoryRoomRoleCardImportPlan {
  final StoryRoomModel room;
  final List<StoryParticipantModel> participants;

  const StoryRoomRoleCardImportPlan({
    required this.room,
    required this.participants,
  });
}

class StoryRoomRoleCardImporter {
  static bool shouldSuggestTavernRoom(AssistantModel assistant) {
    final memoryEntries = parseMemoryBookParticipants(
      assistant.memoryBook,
      roomId: 0,
    );
    if (memoryEntries.length >= 3) return true;
    final text = [
      assistant.name,
      assistant.description,
      assistant.prompt,
      assistant.openingMessage,
    ].join('\n').toLowerCase();
    return text.contains('multiple characters') ||
        text.contains('scenario') ||
        text.contains('sandbox') ||
        text.contains('adventure') ||
        text.contains('world book') ||
        text.contains('lorebook');
  }

  static StoryRoomRoleCardImportPlan buildPlan(
    AssistantModel assistant, {
    required int roomId,
    required String title,
    AssistantRoleCardTavernMeta? tavernMeta,
  }) {
    final room = StoryRoomModel(
      id: roomId == 0 ? null : roomId,
      title: title.trim().isEmpty ? assistant.name : title.trim(),
      mode: StoryRoomMode.tavern,
      replyMode: StoryReplyMode.autoSingle,
      maxAutoReplies: 1,
      publicContext: buildPublicContext(assistant, tavernMeta: tavernMeta),
    );
    final participants = parseMemoryBookParticipants(
      assistant.memoryBook,
      roomId: roomId,
    );
    if (participants.isEmpty) {
      participants.add(StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: assistant.name.trim().isEmpty ? '角色' : assistant.name.trim(),
        prompt: assistant.prompt,
        avatarType: assistant.avatarType,
        avatarValue: assistant.avatarValue,
      ));
    }
    return StoryRoomRoleCardImportPlan(room: room, participants: participants);
  }

  static String buildPublicContext(
    AssistantModel assistant, {
    AssistantRoleCardTavernMeta? tavernMeta,
  }) {
    final parts = <String>[
      if (tavernMeta != null && !tavernMeta.isEmpty)
        _section('Tavern 原卡信息', _tavernMetaText(tavernMeta)),
      _section('角色卡说明', assistant.description),
      _section('公共设定', assistant.prompt),
      if (assistant.openingMessage.trim().isNotEmpty)
        _section('默认开场', assistant.openingMessage),
      if (tavernMeta != null && tavernMeta.alternateGreetings.isNotEmpty)
        _section(
          '备选开场',
          tavernMeta.alternateGreetings
              .asMap()
              .entries
              .map((entry) => '${entry.key + 1}. ${entry.value}')
              .join('\n\n'),
        ),
      _section('示例对话', assistant.exampleDialogs),
      _section('关键词记忆 / 世界书', assistant.memoryBook),
    ].where((part) => part.isNotEmpty).toList();
    return parts.join('\n\n');
  }

  static StoryRoomRoleCardImportPlan buildBatchPlan(
    List<AssistantRoleCardImportResult> results, {
    required int roomId,
    required String title,
  }) {
    final roomTitle = title.trim().isEmpty ? '酒馆房间' : title.trim();
    final room = StoryRoomModel(
      id: roomId == 0 ? null : roomId,
      title: roomTitle,
      mode: StoryRoomMode.tavern,
      replyMode: StoryReplyMode.autoMulti,
      maxAutoReplies: 2,
      publicContext: buildBatchPublicContext(results),
    );
    final participants = <StoryParticipantModel>[];
    var sortOrder = 0;
    for (final result in results) {
      final assistant = result.assistant;
      final parsed = parseMemoryBookParticipants(
        assistant.memoryBook,
        roomId: roomId,
      );
      if (parsed.length >= 2) {
        for (final participant in parsed) {
          participant.sortOrder = sortOrder++;
          participants.add(participant);
        }
        continue;
      }
      participants.add(StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: assistant.name.trim().isEmpty
            ? '角色${sortOrder + 1}'
            : assistant.name.trim(),
        prompt: _participantPrompt(assistant),
        avatarType: assistant.avatarType,
        avatarValue: assistant.avatarValue,
        sortOrder: sortOrder++,
      ));
    }
    return StoryRoomRoleCardImportPlan(room: room, participants: participants);
  }

  static String buildBatchPublicContext(
    List<AssistantRoleCardImportResult> results,
  ) {
    final parts = <String>[];
    final memorySections = <String>[];
    for (final result in results) {
      final assistant = result.assistant;
      final name =
          assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
      final sections = <String>[
        _section('角色简介', assistant.description),
        _section('角色人设', assistant.prompt),
        if (assistant.openingMessage.trim().isNotEmpty)
          _section('默认开场', assistant.openingMessage),
        _section('示例对话', assistant.exampleDialogs),
      ].where((part) => part.isNotEmpty).toList();
      if (sections.isNotEmpty) {
        parts.add('【角色卡：$name】\n${sections.join('\n\n')}');
      }
      final meta = result.tavernMeta;
      if (meta != null && !meta.isEmpty) {
        parts.add('【Tavern 原卡信息：$name】\n${_tavernMetaText(meta)}');
      }
      final memoryBook = assistant.memoryBook.trim();
      if (memoryBook.isNotEmpty) {
        memorySections.add('# $name\n$memoryBook');
      }
    }
    if (memorySections.isNotEmpty) {
      parts.add('【关键词记忆 / 世界书】\n${memorySections.join('\n\n')}');
    }
    return parts.join('\n\n');
  }

  static String initialSceneMessage(AssistantModel assistant) {
    return assistant.openingMessage.trim();
  }

  static List<StoryParticipantModel> parseMemoryBookParticipants(
    String memoryBook, {
    required int roomId,
  }) {
    final participants = <StoryParticipantModel>[];
    var sortOrder = 0;
    for (final entry in _parseMemoryBookEntries(memoryBook)) {
      final content = entry.content.trim();
      if (content.isEmpty) continue;
      final name = _participantName(entry);
      if (name.isEmpty) continue;
      participants.add(StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: name,
        prompt: content,
        sortOrder: sortOrder++,
      ));
    }
    return participants;
  }

  static String normalizeMemoryBookForMatching(String memoryBook) {
    final lines = <String>[];
    for (final entry in _parseMemoryBookEntries(memoryBook)) {
      final content = entry.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (content.isEmpty) continue;
      final prefix = entry.metaPrefix.isEmpty ? '' : '${entry.metaPrefix} ';
      if (entry.keywords.isEmpty) {
        lines.add('$prefix$content');
      } else {
        lines.add('$prefix${entry.keywords.join(',')} => $content');
      }
    }
    return lines.join('\n');
  }

  static List<_MemoryBookEntry> _parseMemoryBookEntries(String memoryBook) {
    final entries = <_MemoryBookEntry>[];
    _MemoryBookEntry? current;
    for (final rawLine in memoryBook.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      if (line.trimLeft().startsWith('#')) continue;
      final split = line.indexOf('=>');
      if (split >= 0) {
        if (current != null) entries.add(current);
        final left = line.substring(0, split).trim();
        final right = line.substring(split + 2).trimLeft();
        current = _MemoryBookEntry(
          keywords: _cleanKeywords(left),
          metaPrefix: _metaPrefix(left),
          contentLines: [right],
        );
      } else if (current != null) {
        current.contentLines.add(line);
      } else if (line.trim().isNotEmpty) {
        current = _MemoryBookEntry(
          keywords: const [],
          contentLines: [line],
        );
      }
    }
    if (current != null) entries.add(current);
    return entries;
  }

  static List<String> _cleanKeywords(String raw) {
    final text = raw.replaceAll(RegExp(r'^\s*(\[[^\]]+\]\s*)+'), '');
    return text
        .split(RegExp(r'[,，、|/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static String _metaPrefix(String raw) {
    final match = RegExp(r'^\s*((?:\[[^\]]+\]\s*)+)').firstMatch(raw);
    return match?.group(1)?.trim() ?? '';
  }

  static String _participantName(_MemoryBookEntry entry) {
    final nameMatch = RegExp(r'^\s*Name\s*:\s*(.+?)\s*$',
            multiLine: true, caseSensitive: false)
        .firstMatch(entry.content);
    if (nameMatch != null) {
      final name = nameMatch.group(1)?.trim() ?? '';
      if (name.isNotEmpty) return name;
    }
    return entry.keywords.isEmpty ? '' : entry.keywords.first;
  }

  static String _section(String title, String value) {
    final text = value.trim();
    return text.isEmpty ? '' : '【$title】\n$text';
  }

  static String _participantPrompt(AssistantModel assistant) {
    final parts = <String>[
      if (assistant.description.trim().isNotEmpty)
        '[角色简介]\n${assistant.description.trim()}',
      if (assistant.prompt.trim().isNotEmpty) assistant.prompt.trim(),
      if (assistant.exampleDialogs.trim().isNotEmpty)
        '[示例对话]\n${assistant.exampleDialogs.trim()}',
    ];
    return parts.join('\n\n');
  }

  static String _tavernMetaText(AssistantRoleCardTavernMeta meta) {
    final lines = <String>[
      if (meta.spec.isNotEmpty || meta.specVersion.isNotEmpty)
        '规范：${[
          meta.spec,
          meta.specVersion
        ].where((e) => e.isNotEmpty).join(' / ')}',
      if (meta.tags.isNotEmpty) '标签：${meta.tags.join('、')}',
      if (meta.characterBookName.isNotEmpty) '世界书：${meta.characterBookName}',
      if (meta.characterBookEntryCount > 0)
        '世界书条目：${meta.characterBookEntryCount}',
      if (meta.characterBookScanDepth != null)
        '扫描深度：${meta.characterBookScanDepth}',
      if (meta.characterBookTokenBudget != null)
        'Token 预算：${meta.characterBookTokenBudget}',
      if (meta.characterBookRecursiveScanning != null)
        '递归扫描：${meta.characterBookRecursiveScanning! ? '开启' : '关闭'}',
    ];
    return lines.join('\n');
  }
}

class _MemoryBookEntry {
  final List<String> keywords;
  final String metaPrefix;
  final List<String> contentLines;

  const _MemoryBookEntry({
    required this.keywords,
    this.metaPrefix = '',
    required this.contentLines,
  });

  String get content => contentLines.join('\n').trim();
}

class StoryRoomRoleCardImportService {
  final StoryRoomDao dao;

  const StoryRoomRoleCardImportService(this.dao);

  Future<int> importAsTavernRoom(
    AssistantModel assistant, {
    required String title,
    AssistantRoleCardTavernMeta? tavernMeta,
    String? initialOpening,
  }) async {
    final plan = StoryRoomRoleCardImporter.buildPlan(
      assistant,
      roomId: 0,
      title: title,
      tavernMeta: tavernMeta,
    );
    final roomId = await dao.saveRoom(plan.room);
    for (final participant in plan.participants) {
      participant.roomId = roomId;
      await dao.saveParticipant(participant);
    }
    final opening = initialOpening ??
        StoryRoomRoleCardImporter.initialSceneMessage(assistant);
    if (opening.isNotEmpty) {
      await dao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerRole: 'system',
        speakerName: '开场',
        content: opening,
      ));
    }
    return roomId;
  }

  Future<int> importBatchAsTavernRoom(
    List<AssistantRoleCardImportResult> results, {
    required String title,
    String? initialOpening,
  }) async {
    final plan = StoryRoomRoleCardImporter.buildBatchPlan(
      results,
      roomId: 0,
      title: title,
    );
    final roomId = await dao.saveRoom(plan.room);
    for (final participant in plan.participants) {
      participant.roomId = roomId;
      await dao.saveParticipant(participant);
    }
    final opening = initialOpening?.trim() ?? '';
    if (opening.isNotEmpty) {
      await dao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerRole: 'system',
        speakerName: '开场',
        content: opening,
      ));
    }
    return roomId;
  }
}
