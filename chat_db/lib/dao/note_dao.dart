import 'package:sqflite/sqflite.dart';

import '../model/note_model.dart';

///数据表接口
abstract class ITable {
  late String tableName;
}

///Note表数据操作接口
abstract class INote {
  void saveNote(NoteModel model);

  void deleteNote(int id);

  void update(NoteModel model);

  Future<int> getNoteCount();

  Future<List<NoteModel>> getAllNote();
}

///INote的的具体实现
class NoteDao implements INote, ITable {
  final Database db;

  @override
  String tableName = 't_note';

  NoteDao(this.db) {
    db.execute(
        'create table if not exists $tableName (id integer primary key autoincrement, content text)');
  }

  @override
  Future<List<NoteModel>> getAllNote() async {
    var results = await db.rawQuery('select * from $tableName');
    var list = results.map((item) => NoteModel.fromJson(item)).toList();
    return list;
  }

  @override
  void saveNote(NoteModel model) {
    db.insert(tableName, model.toJson());
  }

  @override
  void deleteNote(int id) {
    db.delete(tableName, where: 'id=$id');
  }

  @override
  Future<int> getNoteCount() async {
    var result = await db.query(tableName, columns: ['COUNT(*) as cnt']);
    return result.first['cnt'] as int;
  }

  @override
  void update(NoteModel model) {
    db.update(tableName, model.toJson(), where: 'id =?', whereArgs: [model.id]);
  }
}
