import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';

class StoryTemplateTranslationTaskDao implements ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_story_template_translation_task';

  StoryTemplateTranslationTaskDao._(this.storage);

  static Future<StoryTemplateTranslationTaskDao> create(
    HiDBManager storage,
  ) async {
    await storage.db.execute(
      'create table if not exists tb_story_template_translation_task ('
      'id integer primary key autoincrement, '
      'templateId integer, sourceTitle text, sourcePayload text, outputTitle text, '
      'outputTemplateId integer, status text, progress real, stage text, detail text, '
      'log text, error text, roleIndex integer, roleTotal integer, roleName text, '
      'fieldIndex integer, fieldTotal integer, fieldLabel text, fieldProgress real, '
      'partialPayload text, createdAt integer, updatedAt integer)',
    );
    await storage.db.execute(
      'create index if not exists tb_story_template_translation_task_status_idx '
      'on tb_story_template_translation_task(status, updatedAt desc)',
    );
    return StoryTemplateTranslationTaskDao._(storage);
  }

  Future<int> saveTask(StoryTemplateTranslationTaskModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final data = model.toJson()..remove('id');
    if (model.id == null) {
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      return id;
    }
    await storage.db.update(
      tableName,
      data,
      where: 'id = ?',
      whereArgs: [model.id],
    );
    return model.id!;
  }

  Future<List<StoryTemplateTranslationTaskModel>> getTasks() async {
    final rows = await storage.db.query(
      tableName,
      orderBy: 'updatedAt desc, id desc',
    );
    return rows.map(StoryTemplateTranslationTaskModel.fromJson).toList();
  }

  Future<StoryTemplateTranslationTaskModel?> getTask(int id) async {
    final rows = await storage.db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return StoryTemplateTranslationTaskModel.fromJson(rows.first);
  }

  /// 网络请求无法跨进程恢复；把上次意外中断的运行态降级为显式可重试。
  Future<void> recoverInterruptedTasks() async {
    final rows = await storage.db.query(
      tableName,
      where: 'status = ?',
      whereArgs: [StoryTemplateTranslationTaskStatus.running],
    );
    for (final row in rows) {
      final task = StoryTemplateTranslationTaskModel.fromJson(row)
        ..status = StoryTemplateTranslationTaskStatus.retryable
        ..stage = '上次运行已中断，可重试'
        ..detail = taskCheckpointDetail(
            StoryTemplateTranslationTaskModel.fromJson(row))
        ..error = '';
      task.log = _appendLog(task.log, '应用已重启，运行中的任务已恢复为可重试状态');
      await saveTask(task);
    }
  }

  Future<void> deleteTask(int id) async {
    await storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  static String taskCheckpointDetail(StoryTemplateTranslationTaskModel task) {
    final parts = <String>[
      if (task.roleTotal > 0) '角色 ${task.roleIndex}/${task.roleTotal}',
      if (task.roleName.trim().isNotEmpty) task.roleName.trim(),
      if (task.fieldLabel.trim().isNotEmpty) task.fieldLabel.trim(),
      if (task.fieldTotal > 1) '${task.fieldIndex}/${task.fieldTotal}',
    ];
    return parts.join(' · ');
  }

  static String _appendLog(String log, String line) {
    final lines = [
      ...log.split('\n').where((item) => item.trim().isNotEmpty),
      line,
    ];
    const maxLines = 500;
    if (lines.length <= maxLines) return lines.join('\n');
    return [
      '日志较长，已隐藏前 ${lines.length - maxLines} 行',
      ...lines.skip(lines.length - maxLines),
    ].join('\n');
  }
}
