import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';

class StoryTemplateDao implements ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_story_template';

  StoryTemplateDao._(this.storage);

  static Future<StoryTemplateDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_story_template (id integer primary key autoincrement'
        ', title text, sourceTitle text, kind text, translated integer'
        ', payload text, createdAt integer, updatedAt integer)');
    await storage.db.execute(
        'create index if not exists tb_story_template_kind_idx on tb_story_template(kind, updatedAt desc)');
    return StoryTemplateDao._(storage);
  }

  Future<int> saveTemplate(StoryTemplateModel model) async {
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

  Future<List<StoryTemplateModel>> getTemplates({
    String kind = StoryTemplateKind.tavernRoom,
  }) async {
    final rows = await storage.db.query(
      tableName,
      where: 'kind = ?',
      whereArgs: [kind],
      orderBy: 'updatedAt desc, id desc',
    );
    return rows.map(StoryTemplateModel.fromJson).toList();
  }

  Future<StoryTemplateModel?> getTemplate(int id) async {
    final rows = await storage.db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return StoryTemplateModel.fromJson(rows.first);
  }

  Future<void> deleteTemplate(int id) async {
    await storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }
}
