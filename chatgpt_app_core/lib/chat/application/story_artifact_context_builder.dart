import 'package:chatgpt_app_core/model/story_artifact_model.dart';

class StoryArtifactContextBuilder {
  static const marker = '【创作工作台资料】';
  static const defaultMaxCharacters = 6000;

  const StoryArtifactContextBuilder._();

  static String build(
    List<StoryArtifactModel> artifacts, {
    int maxCharacters = defaultMaxCharacters,
  }) {
    final limit = maxCharacters.clamp(0, 30000).toInt();
    if (limit == 0 || artifacts.isEmpty) return '';
    final buffer = StringBuffer(marker);
    for (final type in StoryArtifactType.values) {
      final items = artifacts.where((item) => item.type == type);
      var wroteType = false;
      for (final item in items) {
        final status =
            item.status.trim().isEmpty ? '' : '（${item.status.trim()}）';
        final content = item.content.trim();
        final line = '- ${item.title.trim()}$status：$content';
        final heading = '\n${StoryArtifactType.labelOf(type)}：';
        final addition = '${wroteType ? '' : heading}\n$line';
        final remaining = limit - buffer.length;
        if (remaining <= 0) return buffer.toString();
        if (addition.length <= remaining) {
          buffer.write(addition);
        } else {
          buffer.write(_clip(addition, remaining));
          return buffer.toString();
        }
        wroteType = true;
      }
    }
    return buffer.toString();
  }

  static String mergeIntoPublicContext(
    String publicContext,
    List<StoryArtifactModel> artifacts, {
    int maxCharacters = defaultMaxCharacters,
  }) {
    final markerIndex = publicContext.indexOf(marker);
    final base = (markerIndex < 0
            ? publicContext
            : publicContext.substring(0, markerIndex))
        .trim();
    final generated = build(artifacts, maxCharacters: maxCharacters);
    if (generated.isEmpty) return base;
    return base.isEmpty ? generated : '$base\n\n$generated';
  }

  static String _clip(String text, int maxCharacters) {
    if (text.length <= maxCharacters) return text;
    if (maxCharacters <= 3) return text.substring(0, maxCharacters);
    return '${text.substring(0, maxCharacters - 3).trimRight()}...';
  }
}
