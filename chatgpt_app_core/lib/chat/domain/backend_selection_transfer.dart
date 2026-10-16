import 'dart:convert';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';

/// 搬运只校验形状，不授执行权、不按目标账号或来源重签。
class BackendSelectionTransfer {
  static const entities = {
    'project',
    'conversation',
    'assistant',
    'story_room',
    'story_participant'
  };

  static String? sqlValue(Object? raw) {
    final selection = BackendSelection.fromStorage(raw);
    if (selection == null) return null;
    selection.toSafeJson(); // 未知/畸形值明确拒绝，不能伪造 NULL/legacy。
    return selection.toSqlText();
  }

  static Map<String, dynamic> row(Map<String, Object?> source) {
    final result = Map<String, dynamic>.from(source);
    if (result.containsKey('backendSelection')) {
      result['backendSelection'] = sqlValue(result['backendSelection']);
    }
    return result;
  }

  static List<Map<String, dynamic>> rows(
          Iterable<Map<String, Object?>> source) =>
      source.map(row).toList();

  static void validateRows(Iterable<Map<String, dynamic>> rows) {
    for (final row in rows) {
      if (row.containsKey('backendSelection')) {
        row['backendSelection'] = sqlValue(row['backendSelection']);
      }
    }
  }

  static void settings(Map<String, dynamic> json) {
    final selection = BackendSelection.fromStorage(json['backendSelection']);
    if (selection == null) return;
    if (!selection.isPair) throw const FormatException('顶层后端模型选择无效');
    json['backendSelection'] = selection.toSafeJson();
  }

  /// 合法旧 profile 保持原文字节/版本。导出只移除已知凭据附加项；其它
  /// 未知字段、版本或畸形选择拒绝。导入则严格接受公共 profile 合同。
  static Object? translationProfile(Object? raw, {bool export = false}) {
    if (raw == null) return null;
    if (raw is! String) throw const FormatException('翻译请求快照格式无效');
    if (raw.trim().isEmpty) return raw;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('翻译请求快照格式无效');
      }
      final value = Map<String, dynamic>.from(decoded);
      if (export) {
        for (final field in const {
          'apiKey',
          'apiHost',
          'baseUrl',
          'endpoint',
          'token',
          'password',
          'secret',
          'authorization',
          'headers',
          'requestHeaders'
        }) {
          value.remove(field);
        }
      }
      final profile = TranslationRequestProfile.fromJson(value);
      return value.length == decoded.length
          ? raw
          : jsonEncode(profile.toJson());
    } catch (_) {
      throw const FormatException('翻译请求快照格式无效');
    }
  }
}
