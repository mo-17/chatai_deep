class AssistantExampleDialogs {
  static String promptText(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) return '';
    final kept = <String>[];
    var skippingAlternateGreetings = false;
    for (final line in normalized.split('\n')) {
      final text = line.trim();
      if (_alternateGreetingHeaderRest(text) != null) {
        skippingAlternateGreetings = true;
        continue;
      }
      if (skippingAlternateGreetings) {
        if (isSectionHeader(text)) {
          skippingAlternateGreetings = false;
          kept.add(line);
        }
        continue;
      }
      kept.add(line);
    }
    return kept.join('\n').trim();
  }

  static List<String> alternateGreetings(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) return const [];
    final greetings = <String>[];
    var collecting = false;
    for (final line in normalized.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      final headerRest = _alternateGreetingHeaderRest(text);
      if (headerRest != null) {
        collecting = true;
        if (headerRest.isNotEmpty) {
          greetings.add(normalizeDialogLine(headerRest));
        }
        continue;
      }
      if (collecting && isSectionHeader(text)) break;
      if (collecting) greetings.add(normalizeDialogLine(text));
    }
    final seen = <String>{};
    return [
      for (final greeting in greetings)
        if (greeting.isNotEmpty &&
            seen.add(greeting.replaceAll(RegExp(r'\s+'), '')))
          greeting,
    ];
  }

  static String normalizeDialogLine(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static bool isAlternateGreetingHeader(String line) {
    return _alternateGreetingHeaderRest(line) != null;
  }

  static String? _alternateGreetingHeaderRest(String line) {
    final normalized = line.replaceAll(' ', '').toLowerCase();
    for (final header in const [
      '[备选开场白]',
      '[alternategreetings]',
      '[alternate_greetings]',
    ]) {
      if (normalized == header) return '';
      if (normalized.startsWith(header)) {
        return line.substring(header.length).trim();
      }
    }
    return null;
  }

  static bool isSectionHeader(String line) {
    return line.length >= 2 && line.startsWith('[') && line.endsWith(']');
  }
}
