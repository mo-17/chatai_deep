import 'dart:convert';
import 'dart:typed_data';

enum BackendSelectionKind { follow, pair, invalid }

/// 仅保存后端选择，不授予执行许可。形状合法和来源匹配仍需发送前核验。
/// null 由宿主表示 legacy；非法原值保留，不能伪装成 legacy/follow。
final class BackendSelection {
  final Object _raw;
  final Map<String, dynamic>? _value;
  final BackendSelectionKind kind;

  const BackendSelection._(this._raw, this._value, this.kind);

  static BackendSelection? fromStorage(Object? raw, {bool allowFollow = true}) {
    if (raw == null) return null;
    if (raw is Uint8List) {
      return BackendSelection._(
          Uint8List.fromList(raw), null, BackendSelectionKind.invalid);
    }
    Object? decoded = raw;
    Object stored = raw;
    try {
      if (raw is String) {
        decoded = jsonDecode(raw);
      } else {
        stored = _copy(raw)!;
        decoded = stored;
      }
      if (decoded is! Map<String, dynamic>) {
        return BackendSelection._(stored, null, BackendSelectionKind.invalid);
      }
      final value = _copy(decoded) as Map<String, dynamic>;
      if (value['version'] is! int || value['version'] != 1) {
        return BackendSelection._(stored, null, BackendSelectionKind.invalid);
      }
      if (allowFollow &&
          value['mode'] == 'follow' &&
          _keys(value, const {'version', 'mode'})) {
        return BackendSelection._(stored, value, BackendSelectionKind.follow);
      }
      final scope = value['scope'];
      if (value['mode'] == 'pair' &&
          _keys(value,
              const {'version', 'mode', 'providerCode', 'modelId', 'scope'}) &&
          _identifier(value['providerCode']) &&
          _identifier(value['modelId']) &&
          scope is Map<String, dynamic> &&
          _keys(scope, const {'accountHash', 'origin'}) &&
          _identifier(scope['accountHash']) &&
          canonicalOrigin(scope['origin']) != null) {
        return BackendSelection._(stored, value, BackendSelectionKind.pair);
      }
    } catch (_) {
      // 格式错不改成 NULL；原值不进入错误或日志。
    }
    return BackendSelection._(stored, null, BackendSelectionKind.invalid);
  }

  factory BackendSelection.follow() =>
      fromStorage(const {'version': 1, 'mode': 'follow'})!;

  factory BackendSelection.pair(
      {required String providerCode,
      required String modelId,
      required String accountHash,
      required String origin}) {
    final normalized = canonicalOrigin(origin);
    final selection = fromStorage({
      'version': 1,
      'mode': 'pair',
      'providerCode': providerCode,
      'modelId': modelId,
      'scope': {'accountHash': accountHash, 'origin': normalized ?? origin}
    })!;
    if (!selection.isPair) throw const FormatException('后端模型选择格式无效，请重新选择');
    return selection;
  }

  bool get isValid => kind != BackendSelectionKind.invalid;
  bool get isPair => kind == BackendSelectionKind.pair;
  bool get isFollow => kind == BackendSelectionKind.follow;
  String? get providerCode => isPair ? _value!['providerCode'] as String : null;
  String? get modelId => isPair ? _value!['modelId'] as String : null;
  String? get accountHash =>
      isPair ? (_value!['scope'] as Map)['accountHash'] as String : null;
  String? get origin =>
      isPair ? canonicalOrigin((_value!['scope'] as Map)['origin']) : null;

  /// 只判断来源，不代表模型有效/可执行，不读取目录或凭据。
  bool matchesScope({required String accountHash, required String origin}) =>
      isPair &&
      this.accountHash == accountHash &&
      this.origin == canonicalOrigin(origin);

  String? get pairKey =>
      isPair ? jsonEncode([accountHash, origin, providerCode, modelId]) : null;

  /// settings JSON/clone 保留原非敏感引用；非法字段由安全导出明确拒绝。
  Object toStorageJson() => _copy(isValid ? _value! : _raw)!;

  /// SQL TEXT 保留旧原文（包括非法/未知值），不把 Map 交给 sqflite。
  Object toSqlValue() {
    final raw = _raw;
    if (raw is Uint8List) return Uint8List.fromList(raw);
    return toSqlText();
  }

  String toSqlText() {
    if (_raw is Uint8List) throw const FormatException('后端模型选择格式无效，请重新选择');
    final raw = _raw;
    if (raw is String) return raw;
    try {
      return jsonEncode(_raw);
    } catch (_) {
      throw const FormatException('后端模型选择格式无效，请重新选择');
    }
  }

  Map<String, dynamic> toSafeJson() {
    if (!isValid) throw const FormatException('后端模型选择格式无效，请重新选择');
    return _copy(_value!) as Map<String, dynamic>;
  }

  /// NULL 是旧对象未声明选择，不是现代清空命令；显式 follow 才清除覆盖。
  static void preserveLegacyUpdate(Map<String, dynamic> row) {
    if (row['backendSelection'] == null) row.remove('backendSelection');
  }

  static String? canonicalOrigin(Object? raw) {
    if (raw is! String) return null;
    try {
      final uri = Uri.parse(raw);
      if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535) {
        return null;
      }
      return Uri(
              scheme: uri.scheme.toLowerCase(),
              host: uri.host.toLowerCase(),
              port: uri.port)
          .origin;
    } catch (_) {
      return null;
    }
  }

  static bool _identifier(Object? value) =>
      value is String && value.trim().isNotEmpty;
  static bool _keys(Map<String, dynamic> value, Set<String> allowed) =>
      value.length == allowed.length && allowed.containsAll(value.keys);
  static Object? _copy(Object? value) {
    try {
      return jsonDecode(jsonEncode(value));
    } catch (_) {
      throw const FormatException('后端模型选择格式无效，请重新选择');
    }
  }
}
