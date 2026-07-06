import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

class StoryContextBuilder {
  static String systemPrompt({
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required StoryParticipantModel speaker,
    String latestInput = '',
    List<StoryMessageModel> recentMessages = const [],
  }) {
    final isTavern = room.mode == StoryRoomMode.tavern;
    final buffer = StringBuffer()
      ..writeln(isTavern ? '你正在一个酒馆角色扮演房间中对话。' : '你正在一个小说创作房间中协作。')
      ..writeln('当前房间：${room.title}')
      ..writeln(isTavern ? '酒馆规则：' : '创作规则：')
      ..writeln('- 只以当前发言者身份输出，不要替其他角色做决定。')
      ..writeln('- 可以参考历史对话和公共设定，但不要混淆不同发言者的身份。')
      ..writeln('- 如果当前发言者是角色，只写该角色的台词、动作、心理或反应。');
    if (isTavern) {
      buffer
        ..writeln('- 不要以作者、旁白或系统解说身份输出，除非用户明确要求。')
        ..writeln('- 不要总结创作建议，优先保持沉浸式角色互动。');
    } else {
      buffer
        ..writeln('- 如果当前发言者是旁白，负责场景、动作、氛围和转场。')
        ..writeln('- 如果当前发言者是作者，负责续写、改写、剧情推进和创作建议。');
    }
    final worldBook = _worldBookSection(room.publicContext);
    final publicContext = _withoutWorldBookSection(room.publicContext).trim();
    if (publicContext.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(isTavern ? '【公共上下文 / 场景设定】' : '【公共上下文 / 世界设定】')
        ..writeln(publicContext);
    }
    final worldBookHits = worldBook.isEmpty
        ? const <AssistantMemoryEntryPreview>[]
        : AssistantRoleCardService.matchMemoryEntries(
            StoryRoomRoleCardImporter.normalizeMemoryBookForMatching(worldBook),
            latestInput,
            maxEntries: _worldBookHitLimit(room),
            recentTexts: _recentMatchTexts(recentMessages),
          );
    final beforeCharHits = worldBookHits
        .where((hit) => !_isAfterCharWorldBookPosition(hit.position))
        .toList();
    final afterCharHits = worldBookHits
        .where((hit) => _isAfterCharWorldBookPosition(hit.position))
        .toList();
    if (beforeCharHits.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【本轮命中世界书】')
        ..writeln(AssistantRoleCardService.memoryHitCopyText(beforeCharHits));
    }
    final roster = participants.where((item) => item.enabled).map((item) {
      final role = StoryParticipantRole.labelOf(item.role);
      return '- $role：${item.name}';
    }).join('\n');
    if (roster.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【房间参与者】')
        ..writeln(roster);
    }
    buffer
      ..writeln()
      ..writeln('【当前发言者】')
      ..writeln(
          '${StoryParticipantRole.labelOf(speaker.role)}：${speaker.name}');
    final prompt = _speakerPrompt(speaker).trim();
    if (prompt.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【当前发言者人设 / 写作职责】')
        ..writeln(prompt);
    }
    if (afterCharHits.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【本轮命中世界书 / 角色后置】')
        ..writeln(AssistantRoleCardService.memoryHitCopyText(afterCharHits));
    }
    return buffer.toString().trim();
  }

  static List<Map<String, dynamic>> history(List<StoryMessageModel> messages) {
    return [
      for (final message in messages)
        {
          'role': message.isUser ? 'user' : 'assistant',
          'content': message.isUser
              ? message.content
              : '${message.speakerName}：${message.content}',
        }
    ];
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

  static int _worldBookHitLimit(StoryRoomModel room) {
    final budget = RegExp(r'Token 预算：(\d+)').firstMatch(room.publicContext);
    final value = int.tryParse(budget?.group(1) ?? '');
    if (value == null) return 8;
    if (value >= 2000) return 10;
    if (value >= 1000) return 8;
    return 6;
  }

  static List<String> _recentMatchTexts(
      List<StoryMessageModel> recentMessages) {
    final recent = recentMessages.length > 6
        ? recentMessages.sublist(recentMessages.length - 6)
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
    final normalized = position.trim().toLowerCase();
    return normalized == 'after_char' ||
        normalized == 'afterchar' ||
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
    final match = RegExp(r'\n【[^】]+】').firstMatch(text.substring(start));
    if (match == null) return -1;
    return start + match.start + 1;
  }
}
