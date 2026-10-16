import 'dart:convert';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';

/// 仅作普通后端用量归属；不可反解析为请求选择或执行许可。
String backendUsageProviderId(BackendSelection pair) {
  if (!pair.isPair) throw const FormatException('后端用量缺少固定选择');
  return 'backend:${jsonEncode([pair.origin, pair.providerCode])}';
}

/// 统计展示/导出共用；旧 backend/null 和本地行不改写。
String usageProviderLabel(String? id) {
  if (id == null || id.isEmpty) return '未知';
  if (id == 'backend') return '后端（历史记录）';
  if (!id.startsWith('backend:')) return id;
  try {
    final value = jsonDecode(id.substring('backend:'.length));
    if (value is List &&
        value.length == 2 &&
        value[0] is String &&
        value[1] is String &&
        (value[1] as String).trim().isNotEmpty &&
        BackendSelection.canonicalOrigin(value[0]) == value[0]) {
      return '后端 ${value[1]}（${value[0]}）';
    }
  } catch (_) {}
  return '后端（来源无法识别）';
}
