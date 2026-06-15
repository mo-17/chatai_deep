/// 文档切分（L4a 知识库）。把长文本切成适合检索/回填的小块：
/// 优先按段落（空行）聚合到 [maxChars] 上限；超长单段按字符硬切。
/// 纯函数、无依赖，便于单测。
class KnowledgeChunker {
  /// 单块字符上限。
  static const int defaultMaxChars = 600;

  static List<String> split(String text, {int maxChars = defaultMaxChars}) {
    final normalized = text.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) return const [];

    // 先按空行切成段落。
    final paragraphs = normalized
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final chunks = <String>[];
    final buf = StringBuffer();

    void flush() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) chunks.add(s);
      buf.clear();
    }

    for (final p in paragraphs) {
      // 超长段落：先冲掉缓冲，再按长度硬切。
      if (p.length > maxChars) {
        flush();
        for (var i = 0; i < p.length; i += maxChars) {
          final end = (i + maxChars < p.length) ? i + maxChars : p.length;
          chunks.add(p.substring(i, end).trim());
        }
        continue;
      }
      // 累加到缓冲；超出上限则先冲掉。
      if (buf.isNotEmpty && buf.length + 1 + p.length > maxChars) {
        flush();
      }
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(p);
    }
    flush();
    return chunks;
  }
}
