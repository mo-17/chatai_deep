import 'dart:convert';

import 'package:chatgpt_app_core/model/story_room_model.dart';

class StorySpeakerScheduler {
  static List<StoryParticipantModel> tavernCandidates(
    List<StoryParticipantModel> participants,
  ) {
    final candidates = participants
        .where((item) =>
            item.enabled &&
            item.id != null &&
            item.role == StoryParticipantRole.assistant)
        .toList();
    candidates.sort(_compareParticipantOrder);
    return candidates;
  }

  /// 从用户输入中识别被点名的候选角色。
  ///
  /// 直接姓名、`@姓名` 与全角 `＠姓名` 都由同一段姓名匹配覆盖。较长姓名
  /// 先占用其命中范围，避免「艾莉」被「艾莉丝」的点名误命中。
  static List<StoryParticipantModel> mentionedCandidates({
    required String input,
    required List<StoryParticipantModel> candidates,
  }) {
    final text = input.trim();
    if (text.isEmpty) return const [];
    final ordered = tavernCandidates(candidates);
    final names = <String>{};
    final byLength = <StoryParticipantModel>[];
    for (final candidate in ordered) {
      final name = candidate.name.trim();
      if (name.isEmpty || !names.add(name)) continue;
      byLength.add(candidate);
    }
    byLength.sort((left, right) {
      final length =
          right.name.trim().length.compareTo(left.name.trim().length);
      return length != 0 ? length : _compareParticipantOrder(left, right);
    });

    final occupiedRanges = <_TextRange>[];
    final matches = <_MentionMatch>[];
    for (final candidate in byLength) {
      final name = candidate.name.trim();
      var start = 0;
      while (start < text.length) {
        final index = text.indexOf(name, start);
        if (index < 0) break;
        final range = _TextRange(index, index + name.length);
        if (!occupiedRanges.any(range.overlaps)) {
          occupiedRanges.add(range);
          matches.add(_MentionMatch(candidate, index));
          break;
        }
        start = index + 1;
      }
    }
    matches.sort((left, right) {
      final position = left.position.compareTo(right.position);
      return position != 0
          ? position
          : _compareParticipantOrder(left.candidate, right.candidate);
    });
    return [for (final match in matches) match.candidate];
  }

  /// 最近活动历史中最后一个仍在候选列表里的发言角色。
  ///
  /// 旧消息可能没有 `speakerId`，此时再用姓名回退识别。
  static StoryParticipantModel? lastActiveSpeaker({
    required List<StoryParticipantModel> candidates,
    required List<StoryMessageModel> recentMessages,
  }) {
    final available = tavernCandidates(candidates);
    final byId = <int, StoryParticipantModel>{
      for (final candidate in available) candidate.id!: candidate,
    };
    for (final message in recentMessages.reversed) {
      final bySpeakerId =
          message.speakerId == null ? null : byId[message.speakerId];
      if (bySpeakerId != null) return bySpeakerId;
      final speakerName = message.speakerName.trim();
      for (final candidate in available) {
        if (candidate.name.trim() == speakerName) return candidate;
      }
    }
    return null;
  }

  /// Smart 策略的纯候选排序：点名优先，且点名不受防重复规则排除。
  static List<StoryParticipantModel> smartCandidates({
    required String input,
    required List<StoryParticipantModel> candidates,
    required List<StoryMessageModel> recentMessages,
    bool avoidRepeatSpeaker = true,
    int maxCount = 1,
  }) {
    final available = tavernCandidates(candidates);
    final mentioned = mentionedCandidates(input: input, candidates: available);
    final result = <StoryParticipantModel>[...mentioned];
    final remaining = available
        .where((candidate) => !result.any((item) => item.id == candidate.id))
        .toList();
    final last = lastActiveSpeaker(
      candidates: available,
      recentMessages: recentMessages,
    );
    if (avoidRepeatSpeaker && last != null && remaining.length > 1) {
      final alternatives =
          remaining.where((candidate) => candidate.id != last.id).toList();
      if (alternatives.isNotEmpty) {
        remaining
          ..clear()
          ..addAll(alternatives);
      }
    }
    result.addAll(remaining);
    return _takeUnique(result, maxCount);
  }

  /// Round-robin 按 `sortOrder/id` 从上次发言角色的下一位开始轮换。
  static List<StoryParticipantModel> roundRobinCandidates({
    required List<StoryParticipantModel> candidates,
    required List<StoryMessageModel> recentMessages,
    int maxCount = 1,
  }) {
    final available = tavernCandidates(candidates);
    if (available.isEmpty) return const [];
    final last = lastActiveSpeaker(
      candidates: available,
      recentMessages: recentMessages,
    );
    final lastIndex = last == null
        ? -1
        : available.indexWhere((candidate) => candidate.id == last.id);
    final result = <StoryParticipantModel>[];
    final count = _safeMaxCount(maxCount, available.length);
    for (var offset = 1; result.length < count; offset++) {
      result.add(available[(lastIndex + offset) % available.length]);
    }
    return result;
  }

  /// 只根据持久化房间配置计算候选角色；forced-next 仍由 UI 外层优先处理。
  static List<StoryParticipantModel> schedule({
    required StoryRoomModel room,
    required String input,
    required List<StoryParticipantModel> candidates,
    required List<StoryMessageModel> recentMessages,
    int maxCount = 1,
  }) {
    if (room.speakerStrategy == StorySpeakerStrategy.roundRobin) {
      return roundRobinCandidates(
        candidates: candidates,
        recentMessages: recentMessages,
        maxCount: maxCount,
      );
    }
    return smartCandidates(
      input: input,
      candidates: candidates,
      recentMessages: recentMessages,
      avoidRepeatSpeaker: room.avoidRepeatSpeaker,
      maxCount: maxCount,
    );
  }

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
    final strategy = StorySpeakerStrategy.normalize(room.speakerStrategy);
    final buffer = StringBuffer()
      ..writeln('你是酒馆模式的发言调度器。')
      ..writeln(
          '任务：根据用户最新输入、当前场景和角色人设，选择最自然应该回应的${limit == 1 ? '一个' : '1-$limit 个'}角色。')
      ..writeln('规则：')
      ..writeln('- 只从候选角色中选择。')
      ..writeln('- 优先识别用户以 @角色名、全角＠角色名或直接姓名进行的点名。')
      ..writeln('- 被点名的候选角色优先，不受防重复规则排除。')
      ..writeln('- 如果多个角色都适合，优先选择对当前输入反应最强的角色。');
    if (strategy == StorySpeakerStrategy.roundRobin) {
      buffer.writeln('- 调度策略：roundRobin，按候选角色顺序从上次发言者的下一位开始。');
    } else {
      buffer.writeln('- 调度策略：smart，综合点名、场景和角色动机选择。');
    }
    if (room.avoidRepeatSpeaker) {
      buffer.writeln('- 未点名且存在替代角色时，避免上一位角色连续发言。');
    } else {
      buffer.writeln('- 允许上一位角色连续发言。');
    }
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

  static String promptFor(
    String input, {
    int maxSpeakers = 1,
    StoryRoomModel? room,
  }) {
    final limit = maxSpeakers.clamp(1, 3);
    final strategy = StorySpeakerStrategy.normalize(room?.speakerStrategy);
    final avoidRepeat = room?.avoidRepeatSpeaker ?? true;
    return '用户最新输入：${_clip(input, 1200)}\n'
        '请先识别 @角色名、全角＠角色名或直接姓名的点名；被点名角色优先。\n'
        '调度策略：$strategy；${avoidRepeat ? '未点名且有替代角色时避免上一位连续发言。' : '允许上一位连续发言。'}\n'
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

  static int _compareParticipantOrder(
    StoryParticipantModel left,
    StoryParticipantModel right,
  ) {
    final sortOrder = left.sortOrder.compareTo(right.sortOrder);
    if (sortOrder != 0) return sortOrder;
    return left.id!.compareTo(right.id!);
  }

  static List<StoryParticipantModel> _takeUnique(
    Iterable<StoryParticipantModel> candidates,
    int maxCount,
  ) {
    final result = <StoryParticipantModel>[];
    final ids = <int>{};
    final count = maxCount < 1 ? 1 : maxCount;
    for (final candidate in candidates) {
      final id = candidate.id;
      if (id == null || !ids.add(id)) continue;
      result.add(candidate);
      if (result.length >= count) break;
    }
    return result;
  }

  static int _safeMaxCount(int maxCount, int availableCount) {
    if (availableCount == 0) return 0;
    return maxCount.clamp(1, availableCount);
  }
}

class _TextRange {
  final int start;
  final int end;

  const _TextRange(this.start, this.end);

  bool overlaps(_TextRange other) => start < other.end && other.start < end;
}

class _MentionMatch {
  final StoryParticipantModel candidate;
  final int position;

  const _MentionMatch(this.candidate, this.position);
}
