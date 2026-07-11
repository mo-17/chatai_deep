import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';

class StoryPersonaDao implements ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_story_persona';

  StoryPersonaDao._(this.storage);

  static Future<StoryPersonaDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_story_persona (id integer primary key autoincrement'
        ', personaKey text, name text, description text'
        ', avatarType text, avatarValue text, createdAt integer, updatedAt integer)');
    for (final column in const [
      'personaKey text',
      'name text',
      'description text',
      'avatarType text',
      'avatarValue text',
      'createdAt integer',
      'updatedAt integer',
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_persona add column $column');
      } catch (_) {
        // 旧表已存在该列时忽略，保持数据库可自愈升级。
      }
    }
    await _migrateLegacyKeys(storage);
    await storage.db.execute(
        'create unique index if not exists tb_story_persona_key_uq on tb_story_persona(personaKey)');
    await storage.db.execute(
        'create index if not exists tb_story_persona_updated_idx on tb_story_persona(updatedAt desc, id desc)');
    await SyncTombstoneStore.ensure(storage.db);
    return StoryPersonaDao._(storage);
  }

  static Future<void> _migrateLegacyKeys(HiDBManager storage) async {
    final rows = await storage.db.query(
      'tb_story_persona',
      where: 'personaKey is null or trim(personaKey) = ?',
      whereArgs: const [''],
      orderBy: 'id asc',
    );
    final usedKeys = <String>{
      for (final row in await storage.db.query(
        'tb_story_persona',
        columns: const ['personaKey'],
        where: 'personaKey is not null and trim(personaKey) != ?',
        whereArgs: const [''],
      ))
        (row['personaKey'] as String).trim(),
    };
    for (final row in rows) {
      final model = StoryPersonaModel.fromJson(row);
      var key = model.personaKey;
      var suffix = 1;
      while (!usedKeys.add(key)) {
        key = '${model.personaKey}-$suffix';
        suffix++;
      }
      await storage.db.update(
        'tb_story_persona',
        {'personaKey': key},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<int> savePersona(StoryPersonaModel model) {
    return storage.db.transaction((txn) async {
      model.normalize();
      final now = DateTime.now().millisecondsSinceEpoch;
      model.updatedAt = now;
      final sameKey = await txn.query(
        tableName,
        columns: const ['id', 'createdAt'],
        where: 'personaKey = ?',
        whereArgs: [model.personaKey],
        limit: 1,
      );
      if (model.id == null && sameKey.isNotEmpty) {
        model.id = sameKey.first['id'] as int;
        model.createdAt = sameKey.first['createdAt'] as int? ?? now;
      }
      if (model.id == null) {
        model.createdAt = now;
        final id = await txn.insert(tableName, model.toJson()..remove('id'));
        model.id = id;
        return id;
      }
      await txn.update(
        tableName,
        model.toJson()..remove('id'),
        where: 'id = ?',
        whereArgs: [model.id],
      );
      return model.id!;
    });
  }

  Future<List<StoryPersonaModel>> getPersonas() async {
    final rows = await storage.db.query(
      tableName,
      orderBy: 'updatedAt desc, id desc',
    );
    return rows.map(StoryPersonaModel.fromJson).toList();
  }

  Future<StoryPersonaModel?> getPersona(int id) async {
    final rows = await storage.db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : StoryPersonaModel.fromJson(rows.first);
  }

  Future<StoryPersonaModel?> getPersonaByKey(String personaKey) async {
    final key = personaKey.trim();
    if (key.isEmpty) return null;
    final rows = await storage.db.query(
      tableName,
      where: 'personaKey = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : StoryPersonaModel.fromJson(rows.first);
  }

  /// 选取的头像先复制到应用 Documents，再写入 Persona，避免临时路径失效。
  Future<String> savePersonaAvatar(
    StoryPersonaModel model, {
    required String sourcePath,
  }) async {
    final path = await AvatarAssetService.savePersonaAvatar(
      sourcePath: sourcePath,
      personaKey: model.personaKey,
    );
    model
      ..avatarType = AvatarAssetService.imageType
      ..avatarValue = path;
    try {
      await savePersona(model);
    } catch (_) {
      await AvatarAssetService.deletePersonaAvatar(path);
      rethrow;
    }
    // 旧消息保存的是 Persona 头像路径快照，不能在换头像时立即删除旧文件。
    // 孤儿资源只能在扫描所有消息引用后另行清理。
    return path;
  }

  Future<bool> deletePersona(int id) async {
    StoryPersonaModel? deleted;
    await storage.db.transaction((txn) async {
      final rows = await txn.query(
        tableName,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      deleted = StoryPersonaModel.fromJson(rows.first);
      await SyncTombstoneStore.record(
        txn,
        entity: 'story_persona',
        id: deleted!.personaKey,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await txn.delete(tableName, where: 'id = ?', whereArgs: [id]);
    });
    if (deleted != null) return true;
    return false;
  }

  Future<bool> deletePersonaByKey(String personaKey) async {
    final model = await getPersonaByKey(personaKey);
    if (model?.id == null) return false;
    return deletePersona(model!.id!);
  }
}
