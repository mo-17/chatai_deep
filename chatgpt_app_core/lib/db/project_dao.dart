import 'package:chatgpt_app_core/db/hi_db_manager.dart';
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
        ', defaultProviderId text, defaultModelId text, defaultAssistantId integer'
        ', defaultUseWebSearch integer, defaultToolIds text'
        ', createdAt integer, updatedAt integer);');
    try {
      await storage.db.execute('alter table $_kTableName add column icon text');
    } catch (_) {
      // 列已存在，忽略
    }
    await _addColumn(storage, 'defaultProviderId text');
    await _addColumn(storage, 'defaultModelId text');
    await _addColumn(storage, 'defaultAssistantId integer');
    await _addColumn(storage, 'defaultUseWebSearch integer');
    await _addColumn(storage, 'defaultToolIds text');
    await storage.db.execute(
        'create index if not exists ${_kTableName}_sort_idx on $_kTableName(sortOrder, updatedAt desc);');
    return ProjectDao._(storage);
  }

  @override
  String tableName = _kTableName;

  static Future<void> _addColumn(HiDBManager storage, String columnSql) async {
    try {
      await storage.db
          .execute('alter table $_kTableName add column $columnSql');
    } catch (_) {
      // 列已存在，忽略
    }
  }

  Future<int?> saveProject(ProjectModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (model.id == null) {
      model.createdAt = model.updatedAt;
      final id = await storage.db.insert(tableName, model.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      model.id = id;
      return id;
    }
    await storage.db.update(tableName, model.toJson(),
        where: 'id = ?', whereArgs: [model.id]);
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

  Future<int> deleteProject(int id) async {
    await storage.db.update('tb_conversation_list', {'projectId': null},
        where: 'projectId = ?', whereArgs: [id]);
    await storage.db
        .delete('tb_project_kb', where: 'projectId = ?', whereArgs: [id]);
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }
}
