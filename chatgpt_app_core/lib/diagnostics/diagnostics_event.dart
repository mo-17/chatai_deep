enum DiagnosticsSource {
  flutter,
  platform,
  zone,
}

/// 只包含允许离开设备的诊断字段。
///
/// 这里不保存原始异常、异常消息或 [StackTrace]，避免后续 sink 绕过净化器
/// 读取 prompt、路径、URL、凭据等用户数据。
final class DiagnosticsEvent {
  static const _maxFrames = 40;
  static const _maxFrameLength = 240;
  static final _exceptionType = RegExp(
    r'^[A-Za-z_$][A-Za-z0-9_.$]*(?:<[A-Za-z0-9_.$<>, ?]+>)?$',
  );
  static final _stackLocation = RegExp(
    r'^(?:package:[a-z][a-z0-9_]*/[A-Za-z0-9_./+\-]+\.dart|dart:[a-z][a-z0-9_]*(?:/[A-Za-z0-9_./+\-]+\.dart)?)(?::\d+(?::\d+)?)?',
  );
  static final _appVersion = RegExp(r'^[A-Za-z0-9._+\-]{1,64}$');
  static final _platform = RegExp(r'^[A-Za-z0-9._\-]{1,32}$');

  final DiagnosticsSource source;
  final String exceptionType;
  final List<String> stackFrames;
  final String? appVersion;
  final String? platform;
  final int? httpStatusCode;
  final int? durationMs;
  final int? count;

  DiagnosticsEvent({
    required this.source,
    required String exceptionType,
    required List<String> stackFrames,
    String? appVersion,
    String? platform,
    int? httpStatusCode,
    int? durationMs,
    int? count,
  })  : exceptionType = _safeExceptionType(exceptionType),
        stackFrames = List<String>.unmodifiable(_safeFrames(stackFrames)),
        appVersion = _safeString(appVersion, _appVersion),
        platform = _safeString(platform, _platform),
        httpStatusCode = httpStatusCode != null &&
                httpStatusCode >= 100 &&
                httpStatusCode <= 599
            ? httpStatusCode
            : null,
        durationMs = durationMs != null && durationMs >= 0 ? durationMs : null,
        count = count != null && count > 0 ? count : null;

  /// 每次都从声明过的安全字段新建 Map，不暴露对象内部集合。
  Map<String, Object> toJson() => <String, Object>{
        'source': source.name,
        'exceptionType': exceptionType,
        'stackFrames': List<String>.of(stackFrames),
        if (appVersion != null) 'appVersion': appVersion!,
        if (platform != null) 'platform': platform!,
        if (httpStatusCode != null) 'httpStatusCode': httpStatusCode!,
        if (durationMs != null) 'durationMs': durationMs!,
        if (count != null) 'count': count!,
      };

  static String _safeExceptionType(String value) {
    final normalized = value.trim();
    return _exceptionType.hasMatch(normalized) ? normalized : 'Object';
  }

  static List<String> _safeFrames(List<String> values) {
    final frames = <String>[];
    for (final value in values) {
      final line = value.trim();
      final prefixIndex = _stackPrefixIndex(line);
      if (prefixIndex < 0) continue;
      final match = _stackLocation.firstMatch(line.substring(prefixIndex));
      final location = match?.group(0);
      if (location == null || location.isEmpty) continue;
      final limited = _limitStackLocation(location);
      if (limited == null) continue;
      frames.add(limited);
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

  static String? _limitStackLocation(String location) {
    if (location.length <= _maxFrameLength) return location;
    final suffixIndex = location.lastIndexOf('.dart');
    if (suffixIndex <= 0) return null;
    final suffix = location.substring(suffixIndex);
    final prefixLength = _maxFrameLength - suffix.length;
    if (prefixLength <= 0) return null;
    return '${location.substring(0, prefixLength)}$suffix';
  }

  static String? _safeString(String? value, RegExp allowlist) {
    final normalized = value?.trim();
    if (normalized == null || !allowlist.hasMatch(normalized)) return null;
    return normalized;
  }
}
