import 'dart:convert';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';

class WorkflowTemplateStore {
  static const _key = 'custom_workflow_templates_v1';

  const WorkflowTemplateStore();

  List<WorkflowTemplate> load() {
    final raw = HiCache.getInstance().get(_key);
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map(
              (item) => WorkflowTemplate.fromJson(item.cast<String, dynamic>()))
          .where((template) =>
              template.id.trim().isNotEmpty && template.title.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<WorkflowTemplate> templates) async {
    await HiCache.getInstance()
        .setString(_key, jsonEncode(templates.map((e) => e.toJson()).toList()));
  }

  Future<List<WorkflowTemplate>> add(WorkflowTemplate template) async {
    final list = [...load()];
    final normalized = _ensureUniqueId(template, list);
    list.add(normalized);
    await save(list);
    return list;
  }

  Future<List<WorkflowTemplate>> duplicate(WorkflowTemplate template,
      {int? now}) async {
    final list = [...load()];
    final stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final copy = _ensureUniqueId(
      template.copyWith(
        id: '${template.id}_copy_$stamp',
        title: '${template.title} 副本',
        category: template.category.isEmpty ? '自定义' : template.category,
      ),
      list,
    );
    list.add(copy);
    await save(list);
    return list;
  }

  Future<List<WorkflowTemplate>> update(WorkflowTemplate template) async {
    final list = [...load()];
    final index = list.indexWhere((item) => item.id == template.id);
    if (index < 0) return list;
    list[index] = template;
    await save(list);
    return list;
  }

  Future<List<WorkflowTemplate>> delete(String id) async {
    final list = load().where((template) => template.id != id).toList();
    await save(list);
    return list;
  }

  Future<List<WorkflowTemplate>> move(String id, int delta) async {
    final list = [...load()];
    final from = list.indexWhere((template) => template.id == id);
    if (from < 0) return list;
    final to = (from + delta).clamp(0, list.length - 1);
    if (from == to) return list;
    final item = list.removeAt(from);
    list.insert(to, item);
    await save(list);
    return list;
  }

  WorkflowTemplate _ensureUniqueId(
      WorkflowTemplate template, List<WorkflowTemplate> existing) {
    var base = template.id.trim();
    if (base.isEmpty) {
      base = template.title
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
    }
    if (base.isEmpty) base = 'custom_template';
    final ids = existing.map((e) => e.id).toSet();
    var id = base;
    var n = 1;
    while (ids.contains(id)) {
      id = '${base}_${++n}';
    }
    return template.copyWith(id: id);
  }
}
