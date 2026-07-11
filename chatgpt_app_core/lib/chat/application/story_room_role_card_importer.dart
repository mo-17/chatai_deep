import 'dart:convert';

import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:chatgpt_app_core/model/story_quick_reply.dart';
import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';

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
    if (memoryEntries.length >= 2) return true;
    final text = [
      assistant.name,
      assistant.description,
      assistant.prompt,
      assistant.openingMessage,
    ].join('\n').toLowerCase();
    return _looksLikeMultiCharacterText(name: assistant.name, text: text);
  }

  static bool _looksLikeMultiCharacterText({
    required String name,
    required String text,
  }) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return false;
    const markers = [
      'multiple characters',
      'multi character',
      'multi-character',
      'two characters',
      'dual character',
      'dual-character',
      'twins',
      'twin sisters',
      'sisters',
      '多角色',
      '多名角色',
      '双角色',
      '双人',
      '两位角色',
      '群像',
      '多人',
    ];
    if (markers.any(compact.contains)) return true;
    final normalizedName = name.trim().toLowerCase();
    return RegExp(r'\b\w+\s*(?:&|\+|/)\s*\w+\b').hasMatch(normalizedName) ||
        RegExp(r'\b\w+\s+and\s+\w+\b').hasMatch(normalizedName) ||
        RegExp(r'[\u4e00-\u9fa5]{1,12}\s*(?:和|与|及)\s*[\u4e00-\u9fa5]{1,12}')
            .hasMatch(normalizedName);
  }

  static StoryRoomRoleCardImportPlan buildPlan(
    AssistantModel assistant, {
    required int roomId,
    required String title,
    AssistantRoleCardTavernMeta? tavernMeta,
  }) {
    final effectiveMeta = tavernMeta ??
        AssistantRoleCardService.tavernMetaFromAssistant(assistant);
    final participants = resolveParticipantsForAssistant(
      assistant,
      roomId: roomId,
    );
    final multiParticipant = participants.length >= 2;
    final room = StoryRoomModel(
      id: roomId == 0 ? null : roomId,
      title: title.trim().isEmpty ? assistant.name : title.trim(),
      mode: StoryRoomMode.tavern,
      replyMode: multiParticipant
          ? StoryReplyMode.autoMulti
          : StoryReplyMode.autoSingle,
      maxAutoReplies: multiParticipant ? 2 : 1,
      publicContext: buildPublicContext(assistant, tavernMeta: effectiveMeta),
      promptConfigJson: promptConfigJsonForAssistant(assistant),
      quickRepliesJson: quickRepliesJsonForAssistant(assistant),
      regexScriptsJson: regexScriptsJsonForAssistant(assistant),
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
    final effectiveMeta = tavernMeta ??
        AssistantRoleCardService.tavernMetaFromAssistant(assistant);
    final parts = <String>[
      if (effectiveMeta != null && !effectiveMeta.isEmpty)
        _section('Tavern 原卡信息', _tavernMetaText(effectiveMeta)),
      _section('角色卡说明', assistant.description),
      _section('公共设定', assistant.prompt),
      if (assistant.openingMessage.trim().isNotEmpty)
        _section('默认开场', assistant.openingMessage),
      if (effectiveMeta != null && effectiveMeta.alternateGreetings.isNotEmpty)
        _section(
          '备选开场',
          effectiveMeta.alternateGreetings
              .asMap()
              .entries
              .map((entry) => '${entry.key + 1}. ${entry.value}')
              .join('\n\n'),
        ),
      _section('示例对话', assistant.exampleDialogs),
      _section(
        '关键词记忆 / 世界书',
        AssistantRoleCardService.memoryBookForRuntime(assistant.memoryBook),
      ),
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
      promptConfigJson: _firstNonEmpty(
        results.map((item) => promptConfigJsonForAssistant(item.assistant)),
      ),
      quickRepliesJson: _firstNonEmpty(
        results.map((item) => quickRepliesJsonForAssistant(item.assistant)),
      ),
      regexScriptsJson: _firstNonEmpty(
        results.map((item) => regexScriptsJsonForAssistant(item.assistant)),
      ),
    );
    final participants = <StoryParticipantModel>[];
    var sortOrder = 0;
    for (final result in results) {
      final assistant = result.assistant;
      final resolved = resolveParticipantsForAssistant(
        assistant,
        roomId: roomId,
      );
      if (resolved.isNotEmpty) {
        for (final participant in resolved) {
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

  static int countTemplateParticipants(
    StoryRoomTemplatePayload payload, {
    String title = '',
  }) {
    if (payload.results.isEmpty) return 0;
    if (payload.results.length == 1) {
      final result = payload.results.single;
      return buildPlan(
        result.assistant,
        roomId: 0,
        title: title,
        tavernMeta: result.tavernMeta,
      ).participants.length;
    }
    return buildBatchPlan(
      payload.results,
      roomId: 0,
      title: title,
    ).participants.length;
  }

  static String promptConfigJsonForAssistant(AssistantModel assistant) {
    final extensions =
        AssistantRoleCardService.tavernDeclarativeExtensions(assistant);
    const keys = {
      'prompt_manager',
      'promptManager',
      'prompt_order',
      'promptOrder',
      'prompts',
    };
    if (!keys.any(extensions.containsKey)) return '';
    return StoryPromptConfigCodec.encode(
      StoryPromptConfigCodec.fromTavernExtensions(extensions),
    );
  }

  static String quickRepliesJsonForAssistant(AssistantModel assistant) {
    final extensions =
        AssistantRoleCardService.tavernDeclarativeExtensions(assistant);
    if (!extensions.containsKey('quick_replies') &&
        !extensions.containsKey('quickReplies')) {
      return '';
    }
    final collection =
        StoryQuickReplyCollectionModel.fromTavernExtensions(extensions);
    return collection.groups.isEmpty ? '' : collection.toJsonString();
  }

  static String regexScriptsJsonForAssistant(AssistantModel assistant) {
    final extensions =
        AssistantRoleCardService.tavernDeclarativeExtensions(assistant);
    if (!extensions.containsKey('regex_scripts') &&
        !extensions.containsKey('regexScripts')) {
      return '';
    }
    final scripts = StoryRegexScriptsCodec.fromTavernExtensions(extensions);
    return scripts.rules.isEmpty ? '' : StoryRegexScriptsCodec.encode(scripts);
  }

  static String _firstNonEmpty(Iterable<String> values) => values.firstWhere(
        (value) => value.trim().isNotEmpty,
        orElse: () => '',
      );

  static List<StoryParticipantModel> resolveParticipantsForAssistant(
    AssistantModel assistant, {
    required int roomId,
  }) {
    final parsedParticipants = parseMemoryBookParticipants(
      assistant.memoryBook,
      roomId: roomId,
      defaultAvatarType: assistant.avatarType,
      defaultAvatarValue: assistant.avatarValue,
    );
    final inferredParticipants = _inferMultiCharacterParticipants(
      assistant,
      roomId: roomId,
      sourceParticipant:
          parsedParticipants.length == 1 ? parsedParticipants.single : null,
    );
    if (parsedParticipants.isEmpty && inferredParticipants.isNotEmpty) {
      return inferredParticipants;
    }
    if (parsedParticipants.length == 1 && inferredParticipants.length >= 2) {
      return inferredParticipants;
    }
    return parsedParticipants;
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
      final meta = result.tavernMeta ??
          AssistantRoleCardService.tavernMetaFromAssistant(assistant);
      if (meta != null && !meta.isEmpty) {
        parts.add('【Tavern 原卡信息：$name】\n${_tavernMetaText(meta)}');
      }
      final memoryBook =
          AssistantRoleCardService.memoryBookForRuntime(assistant.memoryBook)
              .trim();
      if (memoryBook.isNotEmpty) {
        memorySections.add('# $name\n$memoryBook');
      }
    }
    if (memorySections.isNotEmpty) {
      parts.add('【关键词记忆 / 世界书】\n${memorySections.join('\n\n')}');
    }
    return parts.join('\n\n');
  }

  static String initialSceneMessage(
    AssistantModel assistant, {
    AssistantRoleCardTavernMeta? tavernMeta,
  }) {
    final opening = assistant.openingMessage.trim();
    if (opening.isNotEmpty) return opening;
    final effectiveMeta = tavernMeta ??
        AssistantRoleCardService.tavernMetaFromAssistant(assistant);
    if (effectiveMeta == null) return '';
    final alternate = effectiveMeta.alternateGreetings
        .map((item) => item.trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => '');
    if (alternate.isNotEmpty) return alternate;
    return effectiveMeta.groupOnlyGreetings
        .map((item) => item.trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => '');
  }

  static String initialBatchSceneMessage(
    List<AssistantRoleCardImportResult> results,
  ) {
    final lines = <String>[];
    for (final result in results) {
      final assistant = result.assistant;
      final opening = initialSceneMessage(
        assistant,
        tavernMeta: result.tavernMeta,
      );
      if (opening.isEmpty) continue;
      final name =
          assistant.name.trim().isEmpty ? '未命名角色' : assistant.name.trim();
      lines.add('【$name】\n$opening');
    }
    return lines.join('\n\n');
  }

  static List<StoryParticipantModel> parseMemoryBookParticipants(
    String memoryBook, {
    required int roomId,
    String? defaultAvatarType,
    String? defaultAvatarValue,
  }) {
    final participants = <StoryParticipantModel>[];
    var sortOrder = 0;
    for (final entry in _parseMemoryBookEntries(memoryBook)) {
      final content = entry.content.trim();
      if (content.isEmpty) continue;
      if (!_looksLikeParticipantEntry(content)) continue;
      final name = _participantName(entry);
      if (name.isEmpty) continue;
      participants.add(StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: name,
        prompt: content,
        avatarType: defaultAvatarType,
        avatarValue: defaultAvatarValue,
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
    final pendingComments = <String>[];
    for (final rawLine in memoryBook.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      final trimmedLeft = line.trimLeft();
      if (trimmedLeft.startsWith('#')) {
        final comment = trimmedLeft.substring(1).trim();
        if (comment.isNotEmpty) pendingComments.add(comment);
        continue;
      }
      final split = line.indexOf('=>');
      if (split >= 0) {
        if (current != null) entries.add(current);
        final left = line.substring(0, split).trim();
        final right = line.substring(split + 2).trimLeft();
        current = _MemoryBookEntry(
          keywords: _cleanKeywords(left),
          metaPrefix: _metaPrefix(left),
          contentLines: [right],
          comments: List<String>.from(pendingComments),
        );
        pendingComments.clear();
      } else if (current != null) {
        current.contentLines.add(line);
      } else if (line.trim().isNotEmpty) {
        current = _MemoryBookEntry(
          keywords: const [],
          contentLines: [line],
          comments: List<String>.from(pendingComments),
        );
        pendingComments.clear();
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
    for (final comment in entry.comments) {
      final name = _participantNameFromComment(comment);
      if (name.isNotEmpty) return name;
    }
    return entry.keywords.isEmpty ? '' : entry.keywords.first;
  }

  static String _participantNameFromComment(String comment) {
    final fieldMatch = RegExp(
      r'^\s*(?:Name|Character|角色|名称|姓名|名字)\s*[:：]\s*(.+?)\s*$',
      caseSensitive: false,
    ).firstMatch(comment);
    final value =
        fieldMatch == null ? comment.trim() : fieldMatch.group(1)!.trim();
    if (value.isEmpty || value.length > 40) return '';
    if (RegExp(r'[。！？.!?]').hasMatch(value)) return '';
    return value;
  }

  static bool _looksLikeParticipantEntry(String content) {
    final type = _fieldValue(content, 'Type');
    if (type.isNotEmpty) {
      final normalized = type.toLowerCase();
      return normalized.contains('character') ||
          normalized.contains('角色') ||
          normalized.contains('person') ||
          normalized.contains('npc') ||
          normalized.contains('assistant');
    }
    return _fieldValue(content, 'Name').isNotEmpty ||
        _fieldValue(content, 'Personality').isNotEmpty ||
        _fieldValue(content, 'Persona').isNotEmpty ||
        _fieldValue(content, 'Character').isNotEmpty ||
        _fieldValue(content, '角色').isNotEmpty ||
        _fieldValue(content, '性格').isNotEmpty;
  }

  static String _fieldValue(String content, String field) {
    final escaped = RegExp.escape(field);
    final match = RegExp('^\\s*$escaped\\s*[:：]\\s*(.+?)\\s*\$',
            multiLine: true, caseSensitive: false)
        .firstMatch(content);
    return match?.group(1)?.trim() ?? '';
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

  static List<StoryParticipantModel> _inferMultiCharacterParticipants(
    AssistantModel assistant, {
    required int roomId,
    StoryParticipantModel? sourceParticipant,
  }) {
    final names = _splitMultiCharacterNames(sourceParticipant?.name ?? '');
    final fallbackNames = names.isEmpty
        ? _splitMultiCharacterNames(assistant.name)
        : const <String>[];
    final inferredNames = names.isNotEmpty ? names : fallbackNames;
    if (inferredNames.length < 2) return const [];
    final sourcePrompt = sourceParticipant?.prompt ?? '';
    return inferredNames.asMap().entries.map((entry) {
      final name = entry.value;
      return StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: name,
        prompt: _participantPromptForInferredName(
          assistant,
          name,
          sourcePrompt: sourcePrompt,
        ),
        avatarType: sourceParticipant?.avatarType ?? assistant.avatarType,
        avatarValue: sourceParticipant?.avatarValue ?? assistant.avatarValue,
        sortOrder: entry.key,
      );
    }).toList();
  }

  static List<String> _splitMultiCharacterNames(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return const [];
    final splitters = RegExp(
      r'\s*(?:&|\+|/|\band\b|和|与|及)\s*',
      caseSensitive: false,
    );
    final names = name
        .split(splitters)
        .map((item) => item.trim())
        .where((item) => item.length >= 2 && item.length <= 40)
        .toList();
    return names.length >= 2 ? names : const [];
  }

  static String _participantPromptForInferredName(
    AssistantModel assistant,
    String name, {
    String sourcePrompt = '',
  }) {
    final base = sourcePrompt.trim().isNotEmpty
        ? sourcePrompt.trim()
        : _participantPrompt(assistant);
    final instruction = [
      '[多角色卡拆分]',
      '原卡名称：${assistant.name}',
      '当前你只扮演：$name',
      '保持原卡设定中属于该角色的语气、关系和行为边界；不要代替其他角色发言。',
    ].join('\n');
    return [base, instruction]
        .where((part) => part.trim().isNotEmpty)
        .join('\n\n');
  }

  static String _tavernMetaText(AssistantRoleCardTavernMeta meta) {
    final lines = <String>[
      if (meta.spec.isNotEmpty || meta.specVersion.isNotEmpty)
        '规范：${[
          meta.spec,
          meta.specVersion
        ].where((e) => e.isNotEmpty).join(' / ')}',
      if (meta.creator.isNotEmpty) '作者：${meta.creator}',
      if (meta.characterVersion.isNotEmpty) '角色版本：${meta.characterVersion}',
      if (meta.createDate.isNotEmpty) '创建时间：${meta.createDate}',
      if (meta.updateDate.isNotEmpty) '更新时间：${meta.updateDate}',
      if (meta.source.isNotEmpty) '来源：${meta.source}',
      if (meta.sources.length > 1) '来源列表：${meta.sources.join('、')}',
      if (meta.nickname.isNotEmpty) '角色别名：${meta.nickname}',
      if (meta.creationTimestamp != null) '创建时间戳：${meta.creationTimestamp}',
      if (meta.modificationTimestamp != null)
        '修改时间戳：${meta.modificationTimestamp}',
      if (meta.tags.isNotEmpty) '标签：${meta.tags.join('、')}',
      if (meta.creatorNotes.isNotEmpty) '作者备注：${meta.creatorNotes}',
      if (meta.systemPrompt.isNotEmpty) '系统提示：${meta.systemPrompt}',
      if (meta.postHistoryInstructions.isNotEmpty)
        '后续指令：${meta.postHistoryInstructions}',
      if (meta.extensionWorld.isNotEmpty) '扩展世界：${meta.extensionWorld}',
      if (meta.talkativeness != null) '群聊活跃度：${meta.talkativeness}',
      if (meta.characterDepthPrompt.isNotEmpty)
        '角色注释：${meta.characterDepthPrompt}',
      if (meta.characterDepthPromptDepth != null)
        '角色注释插入深度：${meta.characterDepthPromptDepth}',
      if (meta.characterDepthPromptRole.isNotEmpty)
        '角色注释角色：${meta.characterDepthPromptRole}',
      if (meta.groupOnlyGreetings.isNotEmpty)
        '群聊专属开场：${meta.groupOnlyGreetings.join(' / ')}',
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
  final List<String> comments;

  const _MemoryBookEntry({
    required this.keywords,
    this.metaPrefix = '',
    required this.contentLines,
    this.comments = const [],
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
    String? promptConfigJson,
    String? quickRepliesJson,
    String? regexScriptsJson,
  }) async {
    final plan = StoryRoomRoleCardImporter.buildPlan(
      assistant,
      roomId: 0,
      title: title,
      tavernMeta: tavernMeta,
    );
    if (promptConfigJson != null) {
      plan.room.promptConfigJson = promptConfigJson;
    }
    if (quickRepliesJson != null) {
      plan.room.quickRepliesJson = quickRepliesJson;
    }
    if (regexScriptsJson != null) {
      plan.room.regexScriptsJson = regexScriptsJson;
    }
    final roomId = await dao.saveRoom(plan.room);
    for (final participant in plan.participants) {
      participant.roomId = roomId;
      await dao.saveParticipant(participant);
    }
    final opening = initialOpening ??
        StoryRoomRoleCardImporter.initialSceneMessage(
          assistant,
          tavernMeta: tavernMeta,
        );
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
    String? promptConfigJson,
    String? quickRepliesJson,
    String? regexScriptsJson,
  }) async {
    final plan = StoryRoomRoleCardImporter.buildBatchPlan(
      results,
      roomId: 0,
      title: title,
    );
    if (promptConfigJson != null) {
      plan.room.promptConfigJson = promptConfigJson;
    }
    if (quickRepliesJson != null) {
      plan.room.quickRepliesJson = quickRepliesJson;
    }
    if (regexScriptsJson != null) {
      plan.room.regexScriptsJson = regexScriptsJson;
    }
    final roomId = await dao.saveRoom(plan.room);
    for (final participant in plan.participants) {
      participant.roomId = roomId;
      await dao.saveParticipant(participant);
    }
    final opening = initialOpening?.trim().isNotEmpty == true
        ? initialOpening!.trim()
        : StoryRoomRoleCardImporter.initialBatchSceneMessage(results);
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

  Future<int> createRoomFromTemplate(
    StoryTemplateModel template, {
    String? title,
  }) async {
    final data = StoryRoomTemplatePayload.fromTemplate(template);
    final roomTitle = title?.trim().isNotEmpty == true
        ? title!.trim()
        : template.title.trim();
    if (data.results.length == 1) {
      return importAsTavernRoom(
        data.results.single.assistant,
        title: roomTitle,
        tavernMeta: data.results.single.tavernMeta,
        initialOpening: data.initialOpening,
        promptConfigJson:
            data.promptConfigJson.trim().isEmpty ? null : data.promptConfigJson,
        quickRepliesJson:
            data.quickRepliesJson.trim().isEmpty ? null : data.quickRepliesJson,
        regexScriptsJson:
            data.regexScriptsJson.trim().isEmpty ? null : data.regexScriptsJson,
      );
    }
    return importBatchAsTavernRoom(
      data.results,
      title: roomTitle,
      initialOpening: data.initialOpening,
      promptConfigJson:
          data.promptConfigJson.trim().isEmpty ? null : data.promptConfigJson,
      quickRepliesJson:
          data.quickRepliesJson.trim().isEmpty ? null : data.quickRepliesJson,
      regexScriptsJson:
          data.regexScriptsJson.trim().isEmpty ? null : data.regexScriptsJson,
    );
  }
}

class StoryRoomTemplatePayload {
  static const formatVersion = 3;

  final List<AssistantRoleCardImportResult> results;
  final String initialOpening;
  final String promptConfigJson;
  final String quickRepliesJson;
  final String regexScriptsJson;

  const StoryRoomTemplatePayload({
    required this.results,
    this.initialOpening = '',
    this.promptConfigJson = '',
    this.quickRepliesJson = '',
    this.regexScriptsJson = '',
  });

  factory StoryRoomTemplatePayload.fromTemplate(StoryTemplateModel template) {
    final decoded = jsonDecode(template.payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('酒馆模板数据格式错误');
    }
    return StoryRoomTemplatePayload.fromJson(decoded);
  }

  factory StoryRoomTemplatePayload.fromJson(Map<String, dynamic> json) {
    final rawResults = json['results'];
    return StoryRoomTemplatePayload(
      results: rawResults is List
          ? [
              for (final item in rawResults)
                if (item is Map)
                  _resultFromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      initialOpening: json['initialOpening'] as String? ?? '',
      promptConfigJson: json['promptConfigJson'] as String? ?? '',
      quickRepliesJson: json['quickRepliesJson'] as String? ?? '',
      regexScriptsJson: json['regexScriptsJson'] as String? ?? '',
    );
  }

  StoryTemplateModel toTemplate({
    required String title,
    String sourceTitle = '',
    bool translated = false,
  }) {
    return StoryTemplateModel(
      title: title.trim().isEmpty ? '未命名酒馆模板' : title.trim(),
      sourceTitle: sourceTitle,
      translated: translated,
      payload: jsonEncode(toJson()),
    );
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'initialOpening': initialOpening,
        'promptConfigJson': promptConfigJson,
        'quickRepliesJson': quickRepliesJson,
        'regexScriptsJson': regexScriptsJson,
        'results': results.map(_resultToJson).toList(),
      };

  static Map<String, dynamic> _resultToJson(
    AssistantRoleCardImportResult result,
  ) =>
      {
        'assistant': result.assistant.toJson(),
        'sourceName': result.sourceName,
        'tavernMeta': result.tavernMeta?.toJson(),
      };

  static AssistantRoleCardImportResult _resultFromJson(
    Map<String, dynamic> json,
  ) {
    final assistantJson = json['assistant'];
    if (assistantJson is! Map) {
      throw const FormatException('酒馆模板缺少角色数据');
    }
    final tavernMetaJson = json['tavernMeta'];
    return AssistantRoleCardImportResult(
      assistant: AssistantModel.fromJson(
        Map<String, dynamic>.from(assistantJson),
      ),
      sourceName: json['sourceName'] as String?,
      tavernMeta: tavernMetaJson is Map
          ? AssistantRoleCardTavernMeta.fromJson(
              Map<String, dynamic>.from(tavernMetaJson),
            )
          : null,
    );
  }
}
