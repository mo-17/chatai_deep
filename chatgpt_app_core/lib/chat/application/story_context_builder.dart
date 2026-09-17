import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_context_window.dart';
import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';

class StoryContextBuildResult {
  final String prompt;
  final WorldBookRuntimeState worldBookState;
  final List<AssistantMemoryEntryPreview> worldBookHits;
  final List<Map<String, dynamic>> leadingMessages;
  final List<StoryPromptMessage> historyDepthMessages;
  final bool includeHistory;
  final String inputPrompt;

  const StoryContextBuildResult({
    required this.prompt,
    required this.worldBookState,
    required this.worldBookHits,
    this.leadingMessages = const [],
    this.historyDepthMessages = const [],
    this.includeHistory = true,
    this.inputPrompt = '',
  });

  List<Map<String, dynamic>> applyToHistory(
    List<Map<String, dynamic>> chatHistory,
  ) {
    final chat = <Map<String, dynamic>>[
      if (includeHistory) ...chatHistory,
    ];
    for (final message in historyDepthMessages) {
      final insertAt = (chat.length - message.depth).clamp(0, chat.length);
      chat.insert(insertAt, {
        'role': message.role,
        'content': message.content,
      });
    }
    return [...leadingMessages, ...chat];
  }
}

class StoryContextBuilder {
  static String systemPrompt({
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required StoryParticipantModel speaker,
    StoryPersonaModel? persona,
    String latestInput = '',
    List<StoryMessageModel> recentMessages = const [],
  }) =>
      buildSystemPrompt(
        room: room,
        participants: participants,
        speaker: speaker,
        persona: persona,
        latestInput: latestInput,
        recentMessages: recentMessages,
      ).prompt;

  /// 兼容同步调用；正则世界书只在异步入口参与匹配。
  static StoryContextBuildResult buildSystemPrompt({
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required StoryParticipantModel speaker,
    StoryPersonaModel? persona,
    String latestInput = '',
    List<StoryMessageModel> recentMessages = const [],
  }) =>
      _buildSystemPrompt(
        room: room,
        participants: participants,
        speaker: speaker,
        persona: persona,
        latestInput: latestInput,
        recentMessages: recentMessages,
        worldBookMatch: _worldBookScan(
          room,
          speaker,
          persona,
          latestInput,
          recentMessages,
        ).run(),
      );

  /// 实际生成路径：包括递归命中在内的正则都在可终止 isolate 中运行。
  static Future<StoryContextBuildResult> buildSystemPromptSafely({
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required StoryParticipantModel speaker,
    StoryPersonaModel? persona,
    String latestInput = '',
    List<StoryMessageModel> recentMessages = const [],
  }) async =>
      _buildSystemPrompt(
        room: room,
        participants: participants,
        speaker: speaker,
        persona: persona,
        latestInput: latestInput,
        recentMessages: recentMessages,
        worldBookMatch: await _worldBookScan(
          room,
          speaker,
          persona,
          latestInput,
          recentMessages,
        ).runSafely(),
      );

  static StoryContextBuildResult _buildSystemPrompt({
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required StoryParticipantModel speaker,
    StoryPersonaModel? persona,
    String latestInput = '',
    List<StoryMessageModel> recentMessages = const [],
    required _WorldBookMatchBundle worldBookMatch,
  }) {
    final isTavern = room.mode == StoryRoomMode.tavern;
    final contextWindow = StoryContextWindow.fromMessages(recentMessages);
    final decoded = StoryPromptConfigCodec.decode(room.promptConfigJson);
    final modules = _withRequiredPromptRules(decoded.modules);
    final rules = StringBuffer()
      ..writeln(isTavern ? '你正在一个酒馆角色扮演房间中对话。' : '你正在一个小说创作房间中协作。')
      ..writeln(isTavern ? '酒馆规则：' : '创作规则：')
      ..writeln('- 只以当前发言者身份输出，不要替其他角色做决定。')
      ..writeln('- 可以参考历史对话和公共设定，但不要混淆不同发言者的身份。')
      ..writeln('- 如果当前发言者是角色，只写该角色的台词、动作、心理或反应。');
    if (isTavern) {
      rules
        ..writeln('- 不要以作者、旁白或系统解说身份输出，除非用户明确要求。')
        ..writeln('- 不要总结创作建议，优先保持沉浸式角色互动。');
    } else {
      rules
        ..writeln('- 如果当前发言者是旁白，负责场景、动作、氛围和转场。')
        ..writeln('- 如果当前发言者是作者，负责续写、改写、剧情推进和创作建议。');
    }
    final publicContext = _withoutWorldBookSection(room.publicContext).trim();
    final roomSection = StringBuffer()..writeln('当前房间：${room.title}');
    if (publicContext.isNotEmpty) {
      roomSection
        ..writeln()
        ..writeln(isTavern ? '【公共上下文 / 场景设定】' : '【公共上下文 / 世界设定】')
        ..writeln(publicContext);
    }
    if (persona != null) {
      roomSection
        ..writeln()
        ..writeln('【当前用户 Persona】')
        ..writeln('名称：${persona.name}');
      if (persona.description.trim().isNotEmpty) {
        roomSection.writeln(persona.description.trim());
      }
    }
    final continuitySummary = contextWindow.summary();
    final continuitySection =
        continuitySummary.isEmpty ? '' : '【长期剧情记忆】\n$continuitySummary';
    final worldBookHits = worldBookMatch.hits;
    final budgetedWorldBookHits = _budgetWorldBookHits(
      worldBookHits,
      maxChars: _worldBookTokenBudget(room),
    );
    final beforeCharHits = budgetedWorldBookHits
        .where((hit) => !_isAfterCharWorldBookPosition(hit.position))
        .toList();
    final afterCharHits = budgetedWorldBookHits
        .where((hit) => _isAfterCharWorldBookPosition(hit.position))
        .toList();
    final worldBookBeforeSection = beforeCharHits.isEmpty
        ? ''
        : '【本轮命中世界书】\n'
            '${AssistantRoleCardService.memoryHitCopyText(beforeCharHits)}';
    final roster = participants.where((item) => item.enabled).map((item) {
      final role = StoryParticipantRole.labelOf(item.role);
      return '- $role：${item.name}';
    }).join('\n');
    final participantsSection = roster.isEmpty ? '' : '【房间参与者】\n$roster';
    final roleStates = _roleStateSection(participants);
    final roleStatesSection = roleStates.isEmpty
        ? ''
        : '【当前分支角色长期状态】\n'
            '这些状态只属于当前故事分支；延续关系、情绪、身体状态和未完成动作。\n'
            '$roleStates';
    final speakerSection = StringBuffer()
      ..writeln('【当前发言者】')
      ..writeln(
          '${StoryParticipantRole.labelOf(speaker.role)}：${speaker.name}');
    final speakerPrompt = _speakerPrompt(speaker).trim();
    if (speakerPrompt.isNotEmpty) {
      speakerSection
        ..writeln()
        ..writeln('【当前发言者人设 / 写作职责】')
        ..writeln(speakerPrompt);
    }
    final worldBookAfterSection = afterCharHits.isEmpty
        ? ''
        : '【本轮命中世界书 / 角色后置】\n'
            '${AssistantRoleCardService.memoryHitCopyText(afterCharHits)}';
    final variables = StoryPromptVariables(
      character: speaker.name,
      user: persona?.name ?? '我',
      room: room.title,
      input: latestInput,
    );
    final relativeModules = modules
        .where((module) =>
            module.builtInSlot != StoryPromptBuiltInSlot.history &&
            module.builtInSlot != StoryPromptBuiltInSlot.input)
        .toList(growable: false);
    final composition = StoryPromptComposer.compose(
      StoryPromptConfig(modules: relativeModules),
      builtInSlots: {
        StoryPromptBuiltInSlot.rules: rules.toString().trim(),
        StoryPromptBuiltInSlot.room: roomSection.toString().trim(),
        StoryPromptBuiltInSlot.continuity: continuitySection,
        StoryPromptBuiltInSlot.worldBookBefore: worldBookBeforeSection,
        StoryPromptBuiltInSlot.participants: participantsSection,
        StoryPromptBuiltInSlot.roleStates: roleStatesSection,
        StoryPromptBuiltInSlot.speaker: speakerSection.toString().trim(),
        StoryPromptBuiltInSlot.worldBookAfter: worldBookAfterSection,
      },
      variables: variables,
    );
    final inputModules = modules
        .where((module) =>
            module.enabled &&
            module.builtInSlot == StoryPromptBuiltInSlot.input)
        .toList(growable: false);
    final inputComposition = StoryPromptComposer.compose(
      StoryPromptConfig(modules: inputModules),
      builtInSlots: {
        StoryPromptBuiltInSlot.input:
            promptFor(input: latestInput, speaker: speaker),
      },
      variables: variables,
    );
    final inputPrompt = inputComposition.messages.isEmpty
        ? latestInput
        : inputComposition.messages.map((item) => item.content).join('\n\n');
    final includeHistory = modules.any((module) =>
        module.enabled && module.builtInSlot == StoryPromptBuiltInSlot.history);
    final leadingMessages = [
      for (final message in composition.systemMessages)
        {'role': message.role, 'content': message.content},
    ];
    final mergedPrompt =
        composition.systemMessages.map((item) => item.content).join('\n\n');
    return StoryContextBuildResult(
      prompt: mergedPrompt,
      worldBookState: worldBookMatch.state,
      worldBookHits: budgetedWorldBookHits,
      leadingMessages: leadingMessages,
      historyDepthMessages: composition.historyDepthMessages,
      includeHistory: includeHistory,
      inputPrompt: inputPrompt,
    );
  }

  static List<StoryPromptModule> _withRequiredPromptRules(
    List<StoryPromptModule> modules,
  ) {
    final result = List<StoryPromptModule>.from(modules);
    final index = result.indexWhere(
      (module) => module.builtInSlot == StoryPromptBuiltInSlot.rules,
    );
    if (index < 0) {
      result.insert(0, StoryPromptConfigCodec.defaultModules.first);
    } else if (!result[index].enabled ||
        result[index].role != StoryPromptRole.system ||
        result[index].placement != StoryPromptPlacement.system) {
      result[index] = result[index].copyWith(
        enabled: true,
        role: StoryPromptRole.system,
        placement: StoryPromptPlacement.system,
      );
    }
    return result;
  }

  static List<Map<String, dynamic>> history(
    List<StoryMessageModel> messages, {
    StoryRoomModel? room,
    StoryParticipantModel? speaker,
    StoryPersonaModel? persona,
  }) {
    final result = <Map<String, dynamic>>[
      for (final message
          in StoryContextWindow.fromMessages(messages).recentMessages)
        {
          'role': message.isUser ? 'user' : 'assistant',
          'content': message.isUser
              ? StoryRoomAttachmentPolicy.historyContent(message)
              : '${message.speakerName}：${StoryPersonaVariables.resolve(
                  message.content,
                  userName: persona?.name ?? '我',
                )}',
        }
    ];
    if (room == null || room.mode != StoryRoomMode.tavern) return result;
    final depthPrompt = _tavernDepthPrompt(
      room.publicContext,
      speakerName: speaker?.name ?? '',
    );
    if (depthPrompt == null) return result;
    final insertAt =
        (result.length - depthPrompt.depth).clamp(0, result.length);
    result.insert(insertAt, {
      'role': depthPrompt.role,
      'content': depthPrompt.content,
    });
    return result;
  }

  static String promptFor({
    required String input,
    required StoryParticipantModel speaker,
  }) {
    final label = StoryParticipantRole.labelOf(speaker.role);
    return '请以「${speaker.name}」这个$label身份回应下面的输入。'
        '只输出该发言者会说/会写的内容，不要解释规则。\n\n$input';
  }

  static String _speakerPrompt(StoryParticipantModel speaker) {
    final custom = speaker.prompt.trim();
    if (custom.isNotEmpty) return custom;
    switch (speaker.role) {
      case StoryParticipantRole.author:
        return '你是作者助手，负责续写正文、调整文风、推进剧情，并保持章节连贯。';
      case StoryParticipantRole.narrator:
        return '你是旁白，负责描写场景、动作、氛围、节奏和转场，不抢角色台词。';
      default:
        return '';
    }
  }

  static String _roleStateSection(
    List<StoryParticipantModel> participants, {
    int maxChars = 1800,
  }) {
    final buffer = StringBuffer();
    for (final participant in participants) {
      final state = participant.stateSummary.trim();
      if (state.isEmpty) continue;
      final line =
          '- ${participant.name}：${state.replaceAll(RegExp(r'\s+'), ' ')}';
      final remaining = maxChars - buffer.length;
      if (remaining <= 0) break;
      if (line.length <= remaining) {
        buffer.writeln(line);
      } else {
        buffer.writeln(line.substring(0, remaining));
        break;
      }
    }
    return buffer.toString().trim();
  }

  static _TavernDepthPrompt? _tavernDepthPrompt(
    String publicContext, {
    required String speakerName,
  }) {
    final sections = _tavernMetaSections(publicContext);
    if (sections.isEmpty) return null;
    final exactTitle = 'Tavern 原卡信息：${speakerName.trim()}';
    final section = sections.cast<_TavernMetaSection?>().firstWhere(
          (item) => item?.title == exactTitle,
          orElse: () => sections.firstWhere(
            (item) => item.title == 'Tavern 原卡信息',
            orElse: () => sections.first,
          ),
        );
    if (section == null) return null;
    final lines = section.lines;
    final noteIndex = lines.indexWhere((line) => line.startsWith('角色注释：'));
    if (noteIndex < 0) return null;
    final note = <String>[lines[noteIndex].substring('角色注释：'.length)];
    var depth = 4;
    var role = 'system';
    for (var index = noteIndex + 1; index < lines.length; index++) {
      final line = lines[index];
      if (line.startsWith('角色注释插入深度：')) {
        depth =
            int.tryParse(line.substring('角色注释插入深度：'.length).trim()) ?? depth;
        continue;
      }
      if (line.startsWith('角色注释角色：')) {
        role = _normalizeDepthPromptRole(
          line.substring('角色注释角色：'.length),
        );
        continue;
      }
      if (_isTavernMetaField(line)) break;
      note.add(line);
    }
    final content = note.join('\n').trim();
    if (content.isEmpty) return null;
    return _TavernDepthPrompt(
      content: content,
      depth: depth.clamp(0, 100),
      role: role,
    );
  }

  static List<_TavernMetaSection> _tavernMetaSections(String text) {
    final sections = <_TavernMetaSection>[];
    _TavernMetaSection? current;
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trimRight();
      if (line.startsWith('【') && line.endsWith('】')) {
        if (current != null) sections.add(current);
        final title = line.substring(1, line.length - 1);
        current =
            title.startsWith('Tavern 原卡信息') ? _TavernMetaSection(title) : null;
        continue;
      }
      current?.lines.add(line);
    }
    if (current != null) sections.add(current);
    return sections;
  }

  static bool _isTavernMetaField(String line) {
    const labels = [
      '规范：',
      '作者：',
      '角色版本：',
      '创建时间：',
      '更新时间：',
      '来源：',
      '来源列表：',
      '角色别名：',
      '创建时间戳：',
      '修改时间戳：',
      '标签：',
      '作者备注：',
      '系统提示：',
      '后续指令：',
      '扩展世界：',
      '群聊活跃度：',
      '群聊专属开场：',
      '世界书：',
      '世界书条目：',
      '扫描深度：',
      'Token 预算：',
      '递归扫描：',
    ];
    return labels.any(line.startsWith);
  }

  static String _normalizeDepthPromptRole(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'user' || normalized == 'human') return 'user';
    if (normalized == 'assistant' ||
        normalized == 'char' ||
        normalized == 'character') {
      return 'assistant';
    }
    return 'system';
  }

  static int _worldBookHitLimit(StoryRoomModel room) {
    // ignore: deprecated_member_use
    final budget = RegExp(r'Token 预算：(\d+)').firstMatch(room.publicContext);
    final value = int.tryParse(budget?.group(1) ?? '');
    if (value == null) return 8;
    if (value >= 2000) return 10;
    if (value >= 1000) return 8;
    return 6;
  }

  static int? _worldBookTokenBudget(StoryRoomModel room) {
    // ignore: deprecated_member_use
    final budget = RegExp(r'Token 预算：(\d+)').firstMatch(room.publicContext);
    return int.tryParse(budget?.group(1) ?? '');
  }

  static int _worldBookScanDepth(StoryRoomModel room) {
    // ignore: deprecated_member_use
    final depth = RegExp(r'扫描深度：(\d+)').firstMatch(room.publicContext);
    final value = int.tryParse(depth?.group(1) ?? '');
    return (value ?? 6).clamp(0, 50);
  }

  static bool _worldBookRecursiveScanning(StoryRoomModel room) {
    // ignore: deprecated_member_use
    final match = RegExp(r'递归扫描：([^\n]+)').firstMatch(room.publicContext);
    final value = match?.group(1)?.trim().toLowerCase() ?? '';
    return value == '开启' || value == 'true' || value == 'yes' || value == '1';
  }

  static _StoryWorldBookScan _worldBookScan(
    StoryRoomModel room,
    StoryParticipantModel speaker,
    StoryPersonaModel? persona,
    String latestInput,
    List<StoryMessageModel> recentMessages,
  ) {
    final modules = _withRequiredPromptRules(
      StoryPromptConfigCodec.decode(room.promptConfigJson).modules,
    );
    final enabled = modules.any((module) =>
        module.enabled &&
        (module.builtInSlot == StoryPromptBuiltInSlot.worldBookBefore ||
            module.builtInSlot == StoryPromptBuiltInSlot.worldBookAfter));
    final worldBook = _worldBookSection(room.publicContext);
    final normalized =
        StoryRoomRoleCardImporter.normalizeMemoryBookForMatching(worldBook);
    final recentTexts = _recentMatchTexts(
      StoryContextWindow.fromMessages(recentMessages).recentMessages,
      maxDepth: _worldBookScanDepth(room),
    );
    final previousState = _decodeWorldBookState(room.worldBookState);
    final messageCount = recentMessages.length + 1;
    final depthPrompt = _tavernDepthPrompt(
      room.publicContext,
      speakerName: speaker.name,
    );
    return _StoryWorldBookScan(
      enabled: enabled && worldBook.isNotEmpty,
      entries: enabled ? WorldBookCodec.decode(legacyText: normalized) : [],
      latestInput: latestInput,
      recentTexts: recentTexts,
      maxEntries: _worldBookHitLimit(room),
      recursive: _worldBookRecursiveScanning(room),
      previousState: previousState,
      contextFor: (input) => WorldBookMatchContext(
        input: input,
        recentTexts: recentTexts,
        characterName: speaker.name,
        personaDescription: persona?.description ?? '',
        characterDescription:
            _promptSection(speaker.prompt, '角色设定', fallback: speaker.prompt),
        characterPersonality: _promptSection(speaker.prompt, '性格'),
        characterDepthPrompt: depthPrompt?.content ?? '',
        scenario: _promptSection(speaker.prompt, '场景'),
        creatorNotes: _tavernMetaValue(
          room.publicContext,
          speakerName: speaker.name,
          label: '作者备注：',
        ),
        messageCount: messageCount,
        generationSeed: WorldBookMatcher.stableSeed(
          '${room.id}|${speaker.id}|$messageCount|$input',
        ),
        activations: previousState.activations,
      ),
    );
  }

  static String _promptSection(
    String prompt,
    String title, {
    String fallback = '',
  }) {
    final marker = '[$title]';
    final start = prompt.indexOf(marker);
    if (start < 0) return fallback;
    final bodyStart = start + marker.length;
    final next = RegExp(r'\n\[(系统提示|角色设定|性格|场景|后续指令)\]')
        .firstMatch(prompt.substring(bodyStart));
    final end = next == null ? prompt.length : bodyStart + next.start;
    return prompt.substring(bodyStart, end).trim();
  }

  static String _tavernMetaValue(
    String publicContext, {
    required String speakerName,
    required String label,
  }) {
    final sections = _tavernMetaSections(publicContext);
    final exactTitle = 'Tavern 原卡信息：${speakerName.trim()}';
    final section = sections.cast<_TavernMetaSection?>().firstWhere(
          (item) => item?.title == exactTitle,
          orElse: () => null,
        );
    if (section == null) return '';
    final line = section.lines.firstWhere(
      (item) => item.startsWith(label),
      orElse: () => '',
    );
    return line.isEmpty ? '' : line.substring(label.length).trim();
  }

  static WorldBookRuntimeState _decodeWorldBookState(String raw) {
    if (raw.trim().isEmpty) return WorldBookRuntimeState.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return WorldBookRuntimeState.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {
      // 损坏的运行时状态只影响 timed effects，世界书正文仍继续工作。
    }
    return WorldBookRuntimeState.empty();
  }

  static List<AssistantMemoryEntryPreview> _budgetWorldBookHits(
    List<AssistantMemoryEntryPreview> hits, {
    required int? maxChars,
  }) {
    if (maxChars == null) return hits;
    final limit = maxChars.clamp(0, 20000).toInt();
    if (limit <= 0) return const [];
    final budgeted = <AssistantMemoryEntryPreview>[];
    var used = 0;
    for (final hit in hits) {
      final linePrefix = '${hit.label}：';
      final separator = budgeted.isEmpty ? 0 : 1;
      final remaining = limit - used - separator - linePrefix.length;
      if (remaining <= 0) break;
      final content = hit.content.length > remaining
          ? _truncateWorldBookContent(hit.content, remaining)
          : hit.content;
      if (content.isEmpty) break;
      budgeted.add(_copyWorldBookHit(hit, content: content));
      used += separator + linePrefix.length + content.length;
      if (content.length >= remaining) break;
    }
    return budgeted;
  }

  static AssistantMemoryEntryPreview _copyWorldBookHit(
    AssistantMemoryEntryPreview hit, {
    required String content,
  }) {
    return AssistantMemoryEntryPreview(
      id: hit.id,
      keywords: hit.keywords,
      content: content,
      alwaysOn: hit.alwaysOn,
      enabled: hit.enabled,
      priority: hit.priority,
      regex: hit.regex,
      secondaryKeywords: hit.secondaryKeywords,
      excludeKeywords: hit.excludeKeywords,
      caseSensitive: hit.caseSensitive,
      wholeWords: hit.wholeWords,
      position: hit.position,
      depth: hit.depth,
      probability: hit.probability,
      probabilityEnabled: hit.probabilityEnabled,
      excludeFromRecursion: hit.excludeFromRecursion,
      group: hit.group,
      groupWeight: hit.groupWeight,
      groupOverride: hit.groupOverride,
      useGroupScoring: hit.useGroupScoring,
      selectiveLogic: hit.selectiveLogic,
      sticky: hit.sticky,
      cooldown: hit.cooldown,
      delay: hit.delay,
      characterFilterNames: hit.characterFilterNames,
      characterFilterExclude: hit.characterFilterExclude,
      matchPersonaDescription: hit.matchPersonaDescription,
      matchCharacterDescription: hit.matchCharacterDescription,
      matchCharacterPersonality: hit.matchCharacterPersonality,
      matchCharacterDepthPrompt: hit.matchCharacterDepthPrompt,
      matchScenario: hit.matchScenario,
      matchCreatorNotes: hit.matchCreatorNotes,
    );
  }

  static String _truncateWorldBookContent(String content, int maxChars) {
    if (maxChars <= 0) return '';
    if (content.length <= maxChars) return content;
    if (maxChars <= 3) return content.substring(0, maxChars);
    return '${content.substring(0, maxChars - 3).trimRight()}...';
  }

  static List<String> _recentMatchTexts(
    List<StoryMessageModel> recentMessages, {
    required int maxDepth,
  }) {
    if (maxDepth <= 0) return const [];
    final recent = recentMessages.length > maxDepth
        ? recentMessages.sublist(recentMessages.length - maxDepth)
        : recentMessages;
    return [
      for (final message in recent) '${message.speakerName}：${message.content}',
    ];
  }

  static String _worldBookSection(String publicContext) {
    return _sectionBody(publicContext, '关键词记忆 / 世界书');
  }

  static String _withoutWorldBookSection(String publicContext) {
    return _removeSection(publicContext, '关键词记忆 / 世界书');
  }

  static bool _isAfterCharWorldBookPosition(String position) {
    // ignore: deprecated_member_use
    final separatorPattern = RegExp(r'[\s-]+');
    final normalized =
        position.trim().toLowerCase().replaceAll(separatorPattern, '_');
    return normalized == 'after_char' ||
        normalized == 'afterchar' ||
        normalized == 'after_character' ||
        normalized == 'after_character_definition' ||
        normalized == 'after' ||
        normalized == '1';
  }

  static String _sectionBody(String text, String title) {
    final marker = '【$title】';
    final start = text.indexOf(marker);
    if (start < 0) return '';
    final bodyStart = start + marker.length;
    final next = _nextSectionStart(text, bodyStart);
    final end = next < 0 ? text.length : next;
    return text.substring(bodyStart, end).trim();
  }

  static String _removeSection(String text, String title) {
    final marker = '【$title】';
    final start = text.indexOf(marker);
    if (start < 0) return text;
    final next = _nextSectionStart(text, start + marker.length);
    final end = next < 0 ? text.length : next;
    return (text.substring(0, start) + text.substring(end)).trim();
  }

  static int _nextSectionStart(String text, int start) {
    // ignore: deprecated_member_use
    final match = RegExp(r'\n【[^】]+】').firstMatch(text.substring(start));
    if (match == null) return -1;
    return start + match.start + 1;
  }
}

class _TavernMetaSection {
  final String title;
  final List<String> lines = [];

  _TavernMetaSection(this.title);
}

class _TavernDepthPrompt {
  final String content;
  final int depth;
  final String role;

  const _TavernDepthPrompt({
    required this.content,
    required this.depth,
    required this.role,
  });
}

class _WorldBookMatchBundle {
  final List<AssistantMemoryEntryPreview> hits;
  final WorldBookRuntimeState state;

  const _WorldBookMatchBundle(this.hits, this.state);
}

/// 同步兼容入口和异步生成入口共享递归选择、去重与 timed effects 状态。
class _StoryWorldBookScan {
  final bool enabled;
  final List<WorldBookEntry> entries;
  final String latestInput;
  final List<String> recentTexts;
  final int maxEntries;
  final bool recursive;
  final WorldBookRuntimeState previousState;
  final WorldBookMatchContext Function(String) contextFor;
  final List<AssistantMemoryEntryPreview> _hits = [];
  final Set<String> _seen = {};
  WorldBookRuntimeState? _firstState;

  _StoryWorldBookScan({
    required this.enabled,
    required this.entries,
    required this.latestInput,
    required this.recentTexts,
    required this.maxEntries,
    required this.recursive,
    required this.previousState,
    required this.contextFor,
  });

  _WorldBookMatchBundle run() {
    if (!enabled) return _WorldBookMatchBundle([], previousState);
    for (var round = 0; round < 3; round++) {
      if (!_accept(WorldBookMatcher.match(
        entries,
        contextFor(_input),
        maxEntries: maxEntries,
      ))) {
        break;
      }
    }
    return _result;
  }

  Future<_WorldBookMatchBundle> runSafely() async {
    if (!enabled) return _WorldBookMatchBundle([], previousState);
    for (var round = 0; round < 3; round++) {
      if (!_accept(await WorldBookMatcher.matchSafely(
        entries,
        contextFor(_input),
        maxEntries: maxEntries,
      ))) {
        break;
      }
    }
    return _result;
  }

  String get _input => _firstState == null
      ? latestInput
      : [
          latestInput,
          ...recentTexts,
          for (final hit in _hits)
            if (!hit.excludeFromRecursion) hit.content,
        ].join('\n');

  bool _accept(WorldBookMatchResult match) {
    final first = _firstState == null;
    _firstState ??= match.state;
    final next = match.entries
        .map(AssistantMemoryEntryPreview.fromWorldBook)
        .where((hit) => first || _seen.add(hit.content))
        .toList();
    _seen.addAll(next.map((hit) => hit.content));
    _hits.addAll(next);
    return recursive && next.isNotEmpty && _hits.length < maxEntries;
  }

  _WorldBookMatchBundle get _result {
    final selected = _hits.take(maxEntries).toList();
    final activations = Map<String, WorldBookActivation>.from(
      _firstState!.activations,
    );
    final messageCount = contextFor(latestInput).messageCount;
    for (final hit in selected) {
      final key = hit.id;
      if (key.isEmpty || activations.containsKey(key)) continue;
      activations[key] = WorldBookActivation(
        entryKey: key,
        activatedAtMessage: messageCount,
        stickyUntilMessage: messageCount + hit.sticky,
        cooldownUntilMessage: messageCount + hit.sticky + hit.cooldown,
      );
    }
    return _WorldBookMatchBundle(selected, WorldBookRuntimeState(activations));
  }
}
