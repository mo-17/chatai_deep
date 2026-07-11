import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';

/// `chatai_deep_tavern_template` 的稳定文件边界。模板内部 payload 继续沿用
/// [StoryRoomTemplatePayload]，因此旧库中已经存在的模板无需迁移。
class StoryTemplateTransfer {
  static const format = 'chatai_deep_tavern_template';
  static const formatVersion = 1;

  const StoryTemplateTransfer._();

  static String exportJson(StoryTemplateModel template) {
    final payload = _decodePayload(template.payload);
    final safePayload = StoryRoomTemplatePayload.fromJson(payload);
    payload
      ..['tavernPresetJson'] = safePayload.tavernPresetJson
      ..['temperature'] = safePayload.temperature
      ..['topP'] = safePayload.topP
      ..['maxOutputTokens'] = safePayload.maxOutputTokens;
    return const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'formatVersion': formatVersion,
      'template': {
        'title': template.title,
        'sourceTitle': template.sourceTitle,
        'kind': template.kind,
        'translated': template.translated,
        'createdAt': template.createdAt,
        'updatedAt': template.updatedAt,
        'payload': payload,
      },
    });
  }

  static StoryTemplateModel importJson(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('不是有效的 JSON 模板文件');
    }
    if (decoded is! Map) {
      throw const FormatException('模板文件根节点必须是对象');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (root['format'] != format) {
      throw const FormatException('不是本 App 导出的酒馆模板文件');
    }
    final version = _int(root['formatVersion']);
    if (version == null) {
      throw const FormatException('模板文件缺少格式版本');
    }
    if (version > formatVersion) {
      throw FormatException('模板格式版本 $version 较新，请升级 App 后再导入');
    }
    if (version != formatVersion) {
      throw FormatException('暂不支持模板格式版本 $version');
    }
    final rawTemplate = root['template'];
    if (rawTemplate is! Map) {
      throw const FormatException('模板文件缺少 template 对象');
    }
    final data = Map<String, dynamic>.from(rawTemplate);
    if ((data['kind'] as String? ?? StoryTemplateKind.tavernRoom) !=
        StoryTemplateKind.tavernRoom) {
      throw const FormatException('只支持导入酒馆模板');
    }
    final rawPayload = data['payload'];
    if (rawPayload is! Map) {
      throw const FormatException('模板文件缺少角色数据');
    }
    final payloadMap = Map<String, dynamic>.from(rawPayload);
    final payload = StoryRoomTemplatePayload.fromJson(payloadMap);
    if (payload.results.isEmpty) {
      throw const FormatException('酒馆模板至少需要一个角色');
    }
    if (payload.results.any((item) => item.assistant.name.trim().isEmpty)) {
      throw const FormatException('酒馆模板存在未命名角色');
    }
    final title = (data['title'] as String? ?? '').trim();
    if (title.isEmpty) {
      throw const FormatException('模板文件缺少名称');
    }
    payloadMap
      ..['tavernPresetJson'] = payload.tavernPresetJson
      ..['temperature'] = payload.temperature
      ..['topP'] = payload.topP
      ..['maxOutputTokens'] = payload.maxOutputTokens;
    return StoryTemplateModel(
      title: title,
      sourceTitle: data['sourceTitle'] as String? ?? '',
      kind: StoryTemplateKind.tavernRoom,
      translated: _bool(data['translated']),
      // 保留原始 payload，兼容已发布版本里尚未被当前编辑器理解的字段。
      payload: jsonEncode(payloadMap),
      createdAt: _int(data['createdAt']),
      updatedAt: _int(data['updatedAt']),
    );
  }

  static String uniqueTitle(String base, Iterable<String> existing) {
    final cleanBase = base.trim().isEmpty ? '未命名酒馆模板' : base.trim();
    final taken = existing.map((item) => item.trim()).toSet();
    if (!taken.contains(cleanBase)) return cleanBase;
    var index = 2;
    while (taken.contains('$cleanBase ($index)')) {
      index++;
    }
    return '$cleanBase ($index)';
  }

  static Map<String, dynamic> _decodePayload(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('酒馆模板数据格式错误');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static bool _bool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return value.toString().toLowerCase() == 'true';
  }
}
