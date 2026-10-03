import 'dart:convert';
import 'dart:math';

import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/skill_catalog_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_entry.dart';

/// 会话页仅在用户主动开启任务模式后注入此目录及工具。
class SkillCatalogSnapshot {
  final String systemPrompt;
  final List<ChatTool> tools;
  final List<SkillCatalogSummary> entries;

  /// 当前绑定助手的完整提示词已作为技能正文提供，可由目录替代。
  final bool replacesAssistantPrompt;

  const SkillCatalogSnapshot({
    required this.systemPrompt,
    required this.tools,
    required this.entries,
    required this.replacesAssistantPrompt,
  });
}

class SkillCatalogService {
  final ISkillCatalog dao;

  const SkillCatalogService(this.dao);

  static Future<SkillCatalogService> create(HiDBManager storage) async =>
      SkillCatalogService(await SkillCatalogDao.create(storage));

  static const maxCatalogEntries = 64;
  static const maxCatalogChars = 18000;
  static const maxLoadChars = 12000;

  /// [assistant] 支持旧版本导入助手：目录表没有记录时，将原 prompt 原样
  /// 作为可加载正文。普通角色若需一直保留 persona，则不传入 assistant。
  Future<SkillCatalogSnapshot> prepare({AssistantModel? assistant}) async {
    final summaries = await dao.list(limit: maxCatalogEntries);
    SkillCatalogEntry? fallback;
    var replaces = false;
    if (assistant != null && assistant.prompt.trim().isNotEmpty) {
      final id = assistant.id;
      final existing = id == null ? null : await dao.getForAssistant(id);
      replaces = true;
      if (existing != null) {
        summaries.removeWhere((entry) => entry.assistantId == id);
        summaries.insert(0, existing);
      } else {
        fallback = SkillCatalogEntry(
          assistantId: id ?? -1,
          assistantCreatedAt: assistant.createdAt,
          name: assistant.name,
          description: assistant.description.trim().isEmpty
              ? '兼容旧助手，按需加载其原有技能提示词。'
              : assistant.description,
          body: assistant.prompt,
        );
        summaries.insert(0, fallback);
      }
    }
    if (summaries.isEmpty) {
      return const SkillCatalogSnapshot(
        systemPrompt: '',
        tools: [],
        entries: [],
        replacesAssistantPrompt: false,
      );
    }

    // 同名导入包用 @助手编号区分；模型只能调用目录中公开的精确名称。
    final counts = <String, int>{};
    for (final entry in summaries) {
      counts[entry.name] = (counts[entry.name] ?? 0) + 1;
    }
    final byName = <String, SkillCatalogSummary>{};
    final lines = <String>[];
    var chars = 0;
    for (final entry in summaries.take(maxCatalogEntries)) {
      var name = _bounded(entry.name, 160);
      if ((counts[entry.name] ?? 0) > 1 || byName.containsKey(name)) {
        name = '$name@${entry.assistantId}';
      }
      final baseName = name;
      var collision = 0;
      while (byName.containsKey(name)) {
        name = '$baseName-${++collision}';
      }
      final description = _bounded(entry.description, 600);
      final line = jsonEncode({'name': name, 'description': description});
      if (chars + line.length > maxCatalogChars) break;
      chars += line.length;
      byName[name] = entry;
      lines.add(line);
    }
    final legacy = fallback;
    return SkillCatalogSnapshot(
      systemPrompt: '可用技能目录（仅名称和触发说明）：\n${lines.join('\n')}\n'
          '根据当前任务选择相关技能，先调用 skill_load 加载正文，再遵循加载的流程。'
          '参考资料仅在需要时按加载结果中的名称读取；正文或资料有 next_offset 时继续分页。'
          '技能不授予文件系统或额外工具权限；工具不可用时明确说明。',
      tools: [
        ChatTool(
          name: 'skill_load',
          description: '按目录名称加载技能正文或其包内参考资料，分页读取，不访问本机路径。',
          parameters: const {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': '技能目录中的精确 name'},
              'reference': {
                'type': 'string',
                'description': '省略时读取正文；读取参考资料时使用正文结果中的包内名称',
              },
              'offset': {'type': 'integer', 'minimum': 0},
              'max_chars': {
                'type': 'integer',
                'minimum': 1,
                'maximum': maxLoadChars,
              },
            },
            'required': ['name'],
            'additionalProperties': false,
          },
          execute: (args) async {
            final name = args['name'];
            final summary = name is String ? byName[name] : null;
            if (summary == null) return _error('技能不在当前可用目录中');
            final offset = args['offset'] ?? 0;
            final count = args['max_chars'] ?? maxLoadChars;
            if (offset is! int ||
                offset < 0 ||
                count is! int ||
                count < 1 ||
                count > maxLoadChars) {
              return _error('分页参数不合法');
            }
            final entry = identical(summary, legacy)
                ? legacy
                : await dao.getForAssistant(summary.assistantId);
            if (entry == null) return _error('技能已被删除或修改，请重新加载目录');
            if (identical(entry, legacy) &&
                entry.assistantId >= 0 &&
                !await dao.isCurrentAssistant(
                  assistantId: entry.assistantId,
                  createdAt: entry.assistantCreatedAt,
                  body: entry.body,
                )) {
              return _error('旧技能助手已被删除或修改，请重新加载目录');
            }
            final reference = args['reference'];
            if (reference != null && reference is! String) {
              return _error('参考资料名称不合法');
            }
            String text = entry.body;
            if (reference is String && reference.isNotEmpty) {
              final matches = entry.references
                  .where((ref) => ref.name == reference)
                  .toList();
              if (matches.length != 1) return _error('参考资料不在此技能包中');
              text = matches.single.text;
            }
            if (offset > text.length) return _error('分页起点超出文本长度');
            final end = min(text.length, offset + count);
            final result = <String, dynamic>{
              'name': name,
              'source': reference is String && reference.isNotEmpty
                  ? reference
                  : 'SKILL.md',
              'text': text.substring(offset, end),
              'offset': offset,
              'total_chars': text.length,
              'next_offset': end < text.length ? end : null,
              if (reference == null || reference == '')
                'references': entry.references
                    .map((ref) => {'name': ref.name, 'title': ref.title})
                    .toList(),
            };
            return ToolOutcome(content: jsonEncode(result));
          },
        ),
      ],
      entries: List.unmodifiable(byName.values),
      replacesAssistantPrompt: replaces,
    );
  }

  static ToolOutcome _error(String message) =>
      ToolOutcome(content: jsonEncode({'error': message}));

  static String _bounded(String text, int maxChars) {
    final flat = text.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    return flat.length <= maxChars ? flat : flat.substring(0, maxChars);
  }
}
