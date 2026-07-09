import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';

class StoryArtifactDao implements ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_story_artifact';

  static const revisionTable = 'tb_story_artifact_revision';

  StoryArtifactDao._(this.storage);

  static Future<StoryArtifactDao> create(HiDBManager storage) async {
    await storage.db.execute(
      'create table if not exists tb_story_artifact ('
      'id integer primary key autoincrement, roomId integer not null, '
      'type text, title text, content text, status text, sortOrder integer, '
      'createdAt integer, updatedAt integer)',
    );
    await storage.db.execute(
      'create index if not exists tb_story_artifact_room_idx '
      'on tb_story_artifact(roomId, type, sortOrder, id)',
    );
    await storage.db.execute(
      'create table if not exists $revisionTable ('
      'id integer primary key autoincrement, artifactId integer not null, '
      'title text, content text, status text, createdAt integer)',
    );
    await storage.db.execute(
      'create index if not exists tb_story_artifact_revision_item_idx '
      'on $revisionTable(artifactId, id desc)',
    );
    return StoryArtifactDao._(storage);
  }

  Future<int> saveArtifact(StoryArtifactModel model) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    model.updatedAt = now;
    if (model.id == null) {
      model.createdAt = now;
      final data = model.toJson()..remove('id');
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      return id;
    }
    await storage.db.transaction((txn) async {
      final rows = await txn.query(
        tableName,
        where: 'id = ?',
        whereArgs: [model.id],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final previous = StoryArtifactModel.fromJson(rows.first);
        final changed = previous.title != model.title ||
            previous.content != model.content ||
            previous.status != model.status;
        if (changed) {
          await txn.insert(revisionTable, {
            'artifactId': model.id,
            'title': previous.title,
            'content': previous.content,
            'status': previous.status,
            'createdAt': now,
          });
        }
      }
      final data = model.toJson()..remove('id');
      await txn.update(
        tableName,
        data,
        where: 'id = ?',
        whereArgs: [model.id],
      );
    });
    return model.id!;
  }

  Future<List<StoryArtifactModel>> getArtifacts(
    int roomId, {
    String? type,
  }) async {
    final rows = await storage.db.query(
      tableName,
      where: type == null ? 'roomId = ?' : 'roomId = ? and type = ?',
      whereArgs: type == null ? [roomId] : [roomId, type],
      orderBy: 'sortOrder asc, id asc',
    );
    return rows.map(StoryArtifactModel.fromJson).toList();
  }

  Future<List<StoryArtifactRevisionModel>> getRevisions(int artifactId) async {
    final rows = await storage.db.query(
      revisionTable,
      where: 'artifactId = ?',
      whereArgs: [artifactId],
      orderBy: 'id desc',
    );
    return rows.map(StoryArtifactRevisionModel.fromJson).toList();
  }

  Future<void> restoreRevision(
    StoryArtifactModel artifact,
    StoryArtifactRevisionModel revision,
  ) async {
    artifact
      ..title = revision.title
      ..content = revision.content
      ..status = revision.status;
    await saveArtifact(artifact);
  }

  Future<void> deleteArtifact(int id) async {
    await storage.db.transaction((txn) async {
      await txn.delete(
        revisionTable,
        where: 'artifactId = ?',
        whereArgs: [id],
      );
      await txn.delete(tableName, where: 'id = ?', whereArgs: [id]);
    });
  }
}
