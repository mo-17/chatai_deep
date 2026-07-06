import 'dart:convert';

import 'package:chatgpt_app_core/model/story_room_model.dart';

class StorySpeakerScheduler {
  static List<StoryParticipantModel> tavernCandidates(
    List<StoryParticipantModel> participants,
  ) =>
      participants
          .where((item) =>
              item.enabled &&
              item.id != null &&
              item.role == StoryParticipantRole.assistant)
          .toList();

  static StoryParticipantModel? fallbackSpeaker({
    required List<StoryParticipantModel> candidates,
    int? selectedParticipantId,
  }) {
    for (final item in candidates) {
      if (item.id == selectedParticipantId) return item;
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  static String systemPrompt({
    required StoryRoomModel room,
    required List<StoryParticipantModel> candidates,
    required List<StoryMessageModel> recentMessages,
    int maxSpeakers = 1,
  }) {
    final limit = maxSpeakers.clamp(1, 3);
    final buffer = StringBuffer()
      ..writeln('你是酒馆模式的发言调度器。')
      ..writeln(
          '任务：根据用户最新输入、当前场景和角色人设，选择最自然应该回应的${limit == 1 ? '一个' : '1-$limit 个'}角色。')
      ..writeln('规则：')
      ..writeln('- 只从候选角色中选择。')
      ..writeln('- 不要总是选择同一个角色，要看最近是谁被点名、谁最有动机回应。')
      ..writeln('- 如果多个角色都适合，优先选择对当前输入反应最强的角色。');
    if (limit == 1) {
      buffer.writeln('- 只输出 JSON：{"speakerId":数字}，不要解释。');
    } else {
      buffer
        ..writeln('- 按自然对话顺序排列角色，同一个角色不要重复。')
        ..writeln('- 只输出 JSON：{"speakerIds":[数字]}，最多 $limit 个，不要解释。');
    }
    buffer
      ..writeln()
      ..writeln('房间：${room.title}');

    final publicContext = room.publicContext.trim();
    if (publicContext.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【场景设定】')
        ..writeln(_clip(publicContext, 1200));
    }

    buffer
      ..writeln()
      ..writeln('【候选角色】');
    for (final item in candidates) {
      buffer.writeln(
          '- speakerId=${item.id}；姓名=${item.name}；人设=${_clip(item.prompt, 360)}');
    }

    final recent = recentMessages.length > 10
        ? recentMessages.sublist(recentMessages.length - 10)
        : recentMessages;
    if (recent.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【最近对话】');
      for (final message in recent) {
        buffer.writeln('${message.speakerName}：${_clip(message.content, 240)}');
      }
    }

    return buffer.toString().trim();
  }

  static String promptFor(String input, {int maxSpeakers = 1}) {
    final limit = maxSpeakers.clamp(1, 3);
    return '用户最新输入：${_clip(input, 1200)}\n'
        '请选择${limit == 1 ? '一个最应该回应的角色' : '1-$limit 个最应该接话的角色，并按发言顺序排列'}。';
  }

  static int? parseSpeakerId(String? response, Set<int> allowedIds) {
    final ids = parseSpeakerIds(response, allowedIds, maxCount: 1);
    return ids.isEmpty ? null : ids.first;
  }

  static List<int> parseSpeakerIds(
    String? response,
    Set<int> allowedIds, {
    int maxCount = 3,
  }) {
    final raw = response?.trim();
    if (raw == null || raw.isEmpty) return const [];
    final jsonText = _extractJsonObject(raw);
    if (jsonText == null) return const [];
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) return const [];
      final rawIds = [
        ..._listIds(decoded['speakerIds']),
        ..._listIds(decoded['speaker_ids']),
        if (_toInt(decoded['speakerId']) != null) _toInt(decoded['speakerId'])!,
        if (_toInt(decoded['speaker_id']) != null)
          _toInt(decoded['speaker_id'])!,
      ];
      final result = <int>[];
      for (final id in rawIds) {
        if (!allowedIds.contains(id) || result.contains(id)) continue;
        result.add(id);
        if (result.length >= maxCount.clamp(1, 3)) break;
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static List<int> _listIds(Object? value) {
    if (value is List) {
      return [
        for (final item in value)
          if (_toInt(item) != null) _toInt(item)!
      ];
    }
    return const [];
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _extractJsonObject(String raw) {
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(raw);
    final text = fenced?.group(1)?.trim() ?? raw;
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end < start) return null;
    return text.substring(start, end + 1);
  }

  static String _clip(String text, int maxLength) {
    final trimmed = text.trim();
    if (trimmed.length <= maxLength) return trimmed;
    return '${trimmed.substring(0, maxLength)}…';
  }
}
