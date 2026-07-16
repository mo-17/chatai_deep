import 'package:chatgpt_app_core/diagnostics/diagnostics_event.dart';

final class DiagnosticsSanitizer {
  static const _maxFrames = 40;
  static const _maxExceptionTypeLength = 120;

  static final _safeStackLocation = RegExp(
    r'^(?:package:[a-z][a-z0-9_]*/[A-Za-z0-9_./+\-]+\.dart|dart:[a-z][a-z0-9_]*(?:/[A-Za-z0-9_./+\-]+\.dart)?)(?::\d+(?::\d+)?)?',
  );
  static final _unsafeExceptionTypeCharacter = RegExp(r'[^A-Za-z0-9_.$<>?, ]');
  static final _safeAppVersion = RegExp(r'^[A-Za-z0-9._+\-]{1,64}$');
  static final _safePlatform = RegExp(r'^[A-Za-z0-9._\-]{1,32}$');

  const DiagnosticsSanitizer();

  DiagnosticsEvent fromError({
    required DiagnosticsSource source,
    required Object error,
    StackTrace? stackTrace,
    String? appVersion,
    String? platform,
    int? httpStatusCode,
    int? durationMs,
    int? count,
  }) {
    return DiagnosticsEvent(
      source: source,
      exceptionType: _normalizeExceptionType(error),
      stackFrames: _normalizeStack(stackTrace),
      appVersion: _safeString(appVersion, _safeAppVersion),
      platform: _safeString(platform, _safePlatform),
      httpStatusCode: httpStatusCode != null &&
              httpStatusCode >= 100 &&
              httpStatusCode <= 599
          ? httpStatusCode
          : null,
      durationMs: durationMs != null && durationMs >= 0 ? durationMs : null,
      count: count != null && count > 0 ? count : null,
    );
  }

  static String _normalizeExceptionType(Object error) {
    final raw = error.runtimeType.toString();
    final normalized = raw.replaceAll(_unsafeExceptionTypeCharacter, '_');
    if (normalized.isEmpty) return 'Object';
    return normalized.length <= _maxExceptionTypeLength
        ? normalized
        : normalized.substring(0, _maxExceptionTypeLength);
  }

  static List<String> _normalizeStack(StackTrace? stackTrace) {
    if (stackTrace == null) return const <String>[];
    final frames = <String>[];
    for (final rawLine in stackTrace.toString().split('\n')) {
      final line = rawLine.trim();
      final prefixIndex = _stackPrefixIndex(line);
      if (prefixIndex < 0) continue;

      final candidate = line.substring(prefixIndex);
      final safeLocation = _safeStackLocation.firstMatch(candidate)?.group(0);
      if (safeLocation == null || safeLocation.isEmpty) continue;
      // 长度上限与防御性复验统一由 DiagnosticsEvent 执行，避免先截断掉
      // `.dart` 后缀后又被事件层判为非法栈帧。
      frames.add(safeLocation);
      if (frames.length == _maxFrames) break;
    }
    return frames;
  }

  static int _stackPrefixIndex(String line) {
    var best = -1;
    for (final prefix in const ['package:', 'dart:']) {
      var offset = 0;
      while (offset < line.length) {
        final index = line.indexOf(prefix, offset);
        if (index < 0) break;
        if (index == 0 || _isStackBoundary(line.codeUnitAt(index - 1))) {
          if (best < 0 || index < best) best = index;
          break;
        }
        offset = index + prefix.length;
      }
    }
    return best;
  }

  static bool _isStackBoundary(int codeUnit) {
    return codeUnit == 0x20 || // space
        codeUnit == 0x09 || // tab
        codeUnit == 0x28 || // (
        codeUnit == 0x5b; // [
  }

  static String? _safeString(String? value, RegExp allowlist) {
    final normalized = value?.trim();
    if (normalized == null || !allowlist.hasMatch(normalized)) return null;
    return normalized;
  }
}
