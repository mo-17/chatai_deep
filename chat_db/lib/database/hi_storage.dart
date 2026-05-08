import 'package:chat_db/dao/note_dao.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../model/note_model.dart';

///数据存储类，可以实现不同的业务接口
class HiStorage implements INote {
  ///多实例
  static final Map<String, HiStorage> _storageMap = {};

  ///数据库名字
  final String _dbName;

  ///数据库实例
  late Database _db;

  ///多实例模式，一个数据库一个实例
  HiStorage._({required String dbName}) : _dbName = dbName {
    _storageMap[_dbName] = this;
  }

  ///获取HiStorage实例
  static Future<HiStorage> instance({required String dbName}) async {
    if (!dbName.endsWith(".db")) {
      dbName = '$dbName.db';
    }
    var storage = _storageMap[dbName];
    storage ??= await HiStorage._(dbName: dbName)._init();
    return storage;
  }

  ///初始化数据库
  Future<HiStorage> _init() async {
    _db = await openDatabase(_dbName);
    debugPrint('db ver:${await _db.getVersion()}');
    return this;
  }

  ///销毁数据库
  void destroy() {
    _db.close();
    _storageMap.remove(_dbName);
  }

  @override
  Future<List<NoteModel>> getAllNote() {
    return NoteDao(_db).getAllNote();
  }

  @override
  void saveNote(NoteModel model) {
    NoteDao(_db).saveNote(model);
  }

  @override
  void deleteNote(int id) {
    NoteDao(_db).deleteNote(id);
  }

  @override
  Future<int> getNoteCount() {
    return NoteDao(_db).getNoteCount();
  }

  @override
  void update(NoteModel model) {
    NoteDao(_db).update(model);
  }
}
