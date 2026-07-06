import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';

class AssistantMemorySuggestionService {
  static String? suggestFromUserMessage(
    String text,
    List<AssistantMemoryModel> existingMemories,
  ) {
    final normalized = _normalize(text);
    if (normalized.length < 4 || normalized.length > 120) return null;
    if (AssistantMemoryDao.hasDuplicateContent(existingMemories, normalized)) {
      return null;
    }
    if (_looksLikeQuestion(normalized)) return null;

    final explicit = _stripPrefix(normalized, const [
      '请记住',
      '你要记住',
      '帮我记住',
      '以后记住',
      '以后请记住',
    ]);
    if (explicit != null) return explicit;

    if (_startsWithAny(normalized, const [
      '我喜欢',
      '我不喜欢',
      '我讨厌',
      '我希望',
      '我习惯',
      '我偏好',
      '我是',
      '我叫',
      '我的名字是',
      '我的职业是',
      '我的工作是',
      '我的目标是',
      '我的计划是',
      '我的生日是',
      '以后请',
      '以后你',
    ])) {
      return normalized;
    }

    return null;
  }

  static bool _startsWithAny(String value, List<String> prefixes) =>
      prefixes.any(value.startsWith);

  static String? _stripPrefix(String value, List<String> prefixes) {
    for (final prefix in prefixes) {
      if (!value.startsWith(prefix)) continue;
      final stripped = value.substring(prefix.length).trim();
      if (stripped.isEmpty) return null;
      return stripped.replaceFirst(RegExp(r'^[：:，,。.\s]+'), '').trim();
    }
    return null;
  }

  static bool _looksLikeQuestion(String value) =>
      value.endsWith('?') ||
      value.endsWith('？') ||
      value.startsWith('为什么') ||
      value.startsWith('怎么') ||
      value.startsWith('如何') ||
      value.startsWith('能不能') ||
      value.startsWith('可不可以');

  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
}
