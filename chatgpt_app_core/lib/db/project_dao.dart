import 'dart:convert';
import 'dart:math' as math;
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:sqflite/sqflite.dart';

/// 对话项目分组 DAO。
class ProjectDao implements ITable {
  final HiDBManager storage;

  ProjectDao._(this.storage);

  static const _kTableName = 'tb_project';

  static Future<ProjectDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', name text not null, icon text, color integer, sortOrder integer'
        ', defaultProviderId text, defaultModelId text, backendSelection text, defaultAssistantId integer'
        ', defaultUseWebSearch integer, defaultToolIds text'
        ', createdAt integer, updatedAt integer);');
    await SchemaGuard.ensureColumns(
      storage.db,
      table: _kTableName,
      columns: const {
        'icon': 'text',
        'defaultProviderId': 'text',
        'defaultModelId': 'text',
        'backendSelection': 'text',
        'defaultAssistantId': 'integer',
        'defaultUseWebSearch': 'integer',
        'defaultToolIds': 'text',
      },
    );
    await storage.db.execute(
        'create index if not exists ${_kTableName}_sort_idx on $_kTableName(sortOrder, updatedAt desc);');
    return ProjectDao._(storage);
  }

  @override
  String tableName = _kTableName;

  Future<int?> saveProject(ProjectModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (model.id == null) {
      model.createdAt = model.updatedAt;
      final id = await storage.db.insert(tableName, model.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      model.id = id;
      return id;
    }
    final data = model.toJson();
    BackendSelection.preserveLegacyUpdate(data);
    await storage.db
        .update(tableName, data, where: 'id = ?', whereArgs: [model.id]);
    return model.id;
  }

  Future<List<ProjectModel>> getProjects({bool withCounts = false}) async {
    if (!withCounts) {
      final rows = await storage.db
          .query(tableName, orderBy: 'sortOrder, updatedAt desc');
      return rows.map((item) => ProjectModel.fromJson(item)).toList();
    }
    final rows = await storage.db.rawQuery('''
select p.*, count(c.id) as conversationCount
from $tableName p
left join tb_conversation_list c on c.projectId = p.id
group by p.id
order by p.sortOrder, p.updatedAt desc
''');
    return rows.map((item) => ProjectModel.fromJson(item)).toList();
  }

  Future<ProjectModel?> getProject(int id) async {
    final rows =
        await storage.db.query(tableName, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return ProjectModel.fromJson(rows.first);
  }

  Future<ProjectBackendSelectionSnapshot> backendSelectionSnapshot(
      ProjectModel model,
      {required void Function() validate}) async {
    validate();
    if (model.id == null) throw const ProjectBackendSelectionStale();
    final rows =
        await storage.db.query(tableName, where: 'id=?', whereArgs: [model.id]);
    validate();
    if (rows.length != 1 ||
        ProjectBackendSelectionSnapshot.selectionFields(model.toJson()) !=
            ProjectBackendSelectionSnapshot.selectionFields(rows.single)) {
      throw const ProjectBackendSelectionStale();
    }
    return ProjectBackendSelectionSnapshot(model, rows.single);
  }

  /// 弹窗后只读核对原seed，不重新选择来源或修改项目。
  Future<void> verifyBackendSeedChecked(
      ProjectModel model, ProjectBackendSelectionSnapshot expected,
      {required void Function() validate}) async {
    validate();
    if (!expected.matchesModel(model)) {
      throw const ProjectBackendSelectionStale();
    }
    final rows = await storage.db
        .query(tableName, where: 'id=?', whereArgs: [expected.id]);
    validate();
    if (rows.length != 1 || !expected.matchesRow(rows.single)) {
      throw const ProjectBackendSelectionStale();
    }
  }

  /// 只声明后端seed和更新时间；不回写本地字段或给已有会话补选择。
  Future<ProjectModel> saveBackendSelectionChecked(ProjectModel model,
      BackendSelection selection, ProjectBackendSelectionSnapshot expected,
      {required void Function() validate}) async {
    if (!selection.isValid) throw const FormatException('后端选择格式无效');
    return storage.db.transaction((txn) async {
      validate();
      if (!expected.matchesModel(model)) {
        throw const ProjectBackendSelectionStale();
      }
      final rows =
          await txn.query(tableName, where: 'id=?', whereArgs: [expected.id]);
      validate();
      if (rows.length != 1 || !expected.matchesRow(rows.single)) {
        throw const ProjectBackendSelectionStale();
      }
      final updatedAt = math.max(DateTime.now().millisecondsSinceEpoch,
          (rows.single['updatedAt'] as int? ?? 0) + 1);
      final changed = await txn.update(
          tableName,
          {
            'backendSelection': selection.toSqlValue(),
            'updatedAt': updatedAt,
          },
          where: 'id=?',
          whereArgs: [expected.id]);
      validate();
      if (changed != 1) throw const ProjectBackendSelectionStale();
      final saved =
          await txn.query(tableName, where: 'id=?', whereArgs: [expected.id]);
      validate();
      return ProjectModel.fromJson(saved.single);
    });
  }

  Future<int> deleteProject(int id) async {
    await storage.db.update('tb_conversation_list', {'projectId': null},
        where: 'projectId = ?', whereArgs: [id]);
    await storage.db
        .delete('tb_project_kb', where: 'projectId = ?', whereArgs: [id]);
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }
}

class ProjectBackendSelectionSnapshot {
  final int id;
  final Map<String, Object?> row;
  final String _model;
  ProjectBackendSelectionSnapshot(ProjectModel model, Map<String, Object?> row)
      : id = model.id!,
        row = Map.unmodifiable(row),
        _model = _rowText(model.toJson());
  bool matchesModel(ProjectModel model) => _rowText(model.toJson()) == _model;
  bool matchesRow(Map<String, Object?> current) =>
      _rowText(current) == _rowText(row);
  static String selectionFields(Map<String, Object?> value) => jsonEncode([
        value['id'],
        value['backendSelection'],
        value['defaultProviderId'],
        value['defaultModelId'],
      ]);
  static String _rowText(Map<String, Object?> value) {
    final keys = value.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: value[key]});
  }
}

class ProjectBackendSelectionStale implements Exception {
  const ProjectBackendSelectionStale();
  @override
  String toString() => '原项目已变化，请重新打开项目选择';
}
