import 'package:chatgpt_app_core/model/story_room_model.dart';

/// 将房间历史压缩为可预测的发送窗口，不触发额外模型调用。
class StoryContextWindow {
  static const defaultRecentMessageLimit = 12;
  static const defaultSummaryCharacterLimit = 1600;

  final List<StoryMessageModel> recentMessages;
  final List<StoryMessageModel> olderMessages;
  final StoryMessageModel? openingMessage;

  const StoryContextWindow._({
    required this.recentMessages,
    required this.olderMessages,
    required this.openingMessage,
  });

  factory StoryContextWindow.fromMessages(
    List<StoryMessageModel> messages, {
    int recentMessageLimit = defaultRecentMessageLimit,
  }) {
    final limit = recentMessageLimit.clamp(1, 100).toInt();
    final opening = _openingOf(messages);
    final splitAt = messages.length > limit ? messages.length - limit : 0;
    final recent = messages.sublist(splitAt);
    final older = <StoryMessageModel>[
      for (final message in messages.take(splitAt))
        if (!identical(message, opening)) message,
    ];
    return StoryContextWindow._(
      recentMessages: List.unmodifiable(recent),
      olderMessages: List.unmodifiable(older),
      openingMessage: opening,
    );
  }

  bool get hasSummary => openingMessage != null || olderMessages.isNotEmpty;

  String summary({int maxCharacters = defaultSummaryCharacterLimit}) {
    if (!hasSummary) return '';
    final limit = maxCharacters.clamp(0, 10000).toInt();
    if (limit == 0) return '';
    final buffer = StringBuffer();
    _writeSection(
      buffer,
      '【系统开场】',
      openingMessage == null ? '' : _messageLine(openingMessage!),
      limit,
    );
    _writeSection(
      buffer,
      '【连续状态】',
      _continuityLines().join('\n'),
      limit,
    );
    _writeSection(
      buffer,
      '【旧剧情摘要】',
      _olderPlotBody(limit),
      limit,
    );
    return buffer.toString().trim();
  }

  List<String> _continuityLines() {
    final latestBySpeaker = <String, StoryMessageModel>{};
    for (final message in olderMessages) {
      final name = message.speakerName.trim();
      if (name.isEmpty) continue;
      latestBySpeaker[name] = message;
    }
    final states = latestBySpeaker.values.toList();
    if (states.length > 6) {
      return states.sublist(states.length - 6).map(_messageLine).toList();
    }
    return states.map(_messageLine).toList();
  }

  String _olderPlotBody(int maxCharacters) {
    final buffer = StringBuffer();
    for (final message in olderMessages) {
      final line = _messageLine(message);
      final separator = buffer.isEmpty ? 0 : 1;
      final available = maxCharacters - buffer.length - separator;
      if (available <= 0) break;
      if (separator > 0) buffer.write('\n');
      buffer.write(_clip(line, available));
      if (line.length > available) break;
    }
    return buffer.toString();
  }

  static StoryMessageModel? _openingOf(List<StoryMessageModel> messages) {
    for (final message in messages) {
      if (message.speakerName.trim() == '开场') return message;
    }
    return null;
  }

  static String _messageLine(StoryMessageModel message) {
    final name = message.speakerName.trim().isEmpty
        ? '未命名发言者'
        : message.speakerName.trim();
    return '$name：${_clip(message.content.trim(), 220)}';
  }

  static String _clip(String text, int maxCharacters) {
    if (text.length <= maxCharacters) return text;
    if (maxCharacters <= 3) return text.substring(0, maxCharacters);
    return '${text.substring(0, maxCharacters - 3).trimRight()}...';
  }

  static void _writeSection(
    StringBuffer buffer,
    String title,
    String body,
    int limit,
  ) {
    if (body.isEmpty || buffer.length >= limit) return;
    final prefix = buffer.isEmpty ? '' : '\n';
    final available = limit - buffer.length - prefix.length - title.length - 1;
    if (available <= 0) return;
    buffer
      ..write(prefix)
      ..write(title)
      ..write('\n')
      ..write(_clip(body, available));
  }
}
