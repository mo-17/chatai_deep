import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/data/knowledge_chunker.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/knowledge_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'knowledge_repository.dart';

abstract class IKnowledgeLibrary {
  Future<List<KnowledgeDoc>> list(
      {String query = '',
      String? folder,
      String? tag,
      bool includeArchived = false});
  Future<int?> add(String title, List<String> pages, {bool pdf = false});
  Future<void> organize(KnowledgeDoc doc,
      {required String folder,
      required List<String> tags,
      required bool archived});
  Future<void> revise(KnowledgeDoc doc, String text);
}

class KnowledgeLibrary implements IKnowledgeLibrary, ITable {
  final HiDBManager storage;
  final KnowledgeDao dao;
  final String account;
  @override
  String tableName = 'tb_kb_revision';
  KnowledgeLibrary._(this.storage, this.dao, this.account);
  static Future<KnowledgeLibrary> create(HiDBManager storage,
      {String? account}) async {
    final dao = await KnowledgeDao.create(storage);
    await storage.db.execute('create table if not exists tb_kb_revision ('
        'uid text not null, revision integer not null, hash text not null, payload text not null, '
        'primary key(uid, hash))');
    final columns =
        await storage.db.rawQuery('pragma table_info(tb_kb_revision)');
    if (!columns.any((c) => c['name'] == 'hash')) {
      await storage.db.transaction((tx) async {
        if ((await tx.rawQuery('pragma table_info(tb_kb_revision)'))
            .any((c) => c['name'] == 'hash')) {
          return;
        }
        await tx.execute(
            'create table tb_kb_revision_upgrade (uid text not null, revision integer not null, hash text not null, payload text not null, primary key(uid,hash))');
        for (final row in await tx.query('tb_kb_revision')) {
          final value = (jsonDecode(row['payload'] as String) as Map)
              .cast<String, dynamic>();
          await tx.insert(
              'tb_kb_revision_upgrade', {...row, 'hash': snapshotHash(value)},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await tx.execute('drop table tb_kb_revision');
        await tx.execute(
            'alter table tb_kb_revision_upgrade rename to tb_kb_revision');
      });
    }
    return KnowledgeLibrary._(
        storage, dao, AccountResourceScope.currentAccountHash(account));
  }

  @override
  Future<List<KnowledgeDoc>> list(
      {String query = '',
      String? folder,
      String? tag,
      bool includeArchived = false}) async {
    final docs = await dao.getDocuments();
    return docs
        .where((d) =>
            (includeArchived || !d.archived) &&
            (folder == null || d.folder == folder) &&
            (tag == null || d.tags.contains(tag)) &&
            '${d.title} ${d.folder} ${d.tags.join(' ')}'
                .toLowerCase()
                .contains(query.trim().toLowerCase()))
        .toList();
  }

  static String hashPages(List<String> pages) =>
      sha256.convert(utf8.encode(pages.join('\n\n').trim())).toString();
  static int _nextAt(int previous) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now > previous ? now : previous + 1;
  }

  @override
  Future<int?> add(String title, List<String> pages, {bool pdf = false}) async {
    if (title.length > 1000 ||
        pages.fold<int>(0, (n, p) => n + p.length) > 1000000) {
      throw const KnowledgeScopeException('标题最多1000字、正文最多100万字符，请拆分后导入');
    }
    int? id;
    try {
      id = await dao.addPagedDocument(title, pages,
          isPdf: pdf, rejectDuplicates: true);
    } on FormatException catch (e) {
      throw KnowledgeScopeException(e.message);
    }
    if (id != null) await checkpoint(id);
    return id;
  }

  Future<Map<String, Object?>> snapshot(DatabaseExecutor db, int id) async {
    final docs = await db.query('tb_kb_doc', where: 'id = ?', whereArgs: [id]);
    if (docs.length != 1) throw const KnowledgeScopeException('文档已删除，请刷新');
    final chunks = await db.query('tb_kb_chunk',
        where: 'docId = ?', whereArgs: [id], orderBy: 'seq');
    return {'document': docs.single, 'chunks': chunks};
  }

  Future<void> _checkpoint(DatabaseExecutor db, int id) async {
    final value = await snapshot(db, id);
    final doc = value['document'] as Map;
    await db.insert(
        tableName,
        {
          'uid': doc['uid'],
          'revision': doc['revision'],
          'hash': snapshotHash(value.cast<String, dynamic>()),
          'payload': jsonEncode(value)
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static String snapshotHash(Map<String, dynamic> value) {
    final doc = Map<String, dynamic>.from(value['document'] as Map)
      ..remove('id');
    final chunks = [
      for (final raw in value['chunks'] as List)
        Map<String, dynamic>.from(raw as Map)
          ..remove('id')
          ..remove('docId')
    ];
    // 键排序后计算，SQLite/JSON 的字段顺序不参与版本身份。
    Object? canonical(Object? x) => x is Map
        ? {
            for (final k in x.keys.map((k) => k.toString()).toList()..sort())
              k: canonical(x[k])
          }
        : x is List
            ? x.map(canonical).toList()
            : x;
    return sha256
        .convert(utf8
            .encode(jsonEncode(canonical({'document': doc, 'chunks': chunks}))))
        .toString();
  }

  Future<void> checkpoint(int id) =>
      storage.db.transaction((tx) => _checkpoint(tx, id));
  Future<List<Map<String, dynamic>>> versions(KnowledgeDoc doc) async {
    await checkpoint(doc.id!);
    final rows = await storage.db.query(tableName,
        where: 'uid = ?', whereArgs: [doc.uid], orderBy: 'revision desc');
    return rows
        .map((r) =>
            (jsonDecode(r['payload'] as String) as Map).cast<String, dynamic>())
        .toList();
  }

  Future<void> _guard(DatabaseExecutor db, KnowledgeDoc doc) async {
    final rows = await db.query('tb_kb_doc',
        where: 'id = ? and uid = ? and revision = ?',
        whereArgs: [doc.id, doc.uid, doc.revision]);
    if (rows.length != 1) throw const KnowledgeScopeException('文档版本已变化，请刷新后重试');
  }

  Future<List<Map<String, Object?>>> conflicts() async {
    final exists = await storage.db.rawQuery(
        "select name from sqlite_master where type='table' and name='tb_knowledge_conflict'");
    return exists.isEmpty
        ? []
        : await storage.db
            .query('tb_knowledge_conflict', orderBy: 'id desc', limit: 100);
  }

  Future<int?> copyConflict(int conflictId) async {
    final rows = await storage.db.query('tb_knowledge_conflict',
        where: 'id = ?', whereArgs: [conflictId]);
    if (rows.length != 1) throw const KnowledgeScopeException('冲突记录已变化，请刷新');
    final record = (jsonDecode(rows.single['payload'] as String) as Map)
        .cast<String, dynamic>();
    if (record['kind'] == 'answer') {
      throw const KnowledgeScopeException('这是问答快照冲突，可查看原始记录后保留待处理');
    }
    final snap = record['kind'] == 'document'
        ? record['snapshot'] as Map
        : jsonDecode(record['payload'] as String) as Map;
    final doc = snap['document'] as Map;
    final chunks = snap['chunks'] as List;
    final text = chunks.map((c) => c['content']).join('\n\n');
    final id = await add('${doc['title']}（冲突副本）', [text]);
    if (id != null) {
      await storage.db.delete('tb_knowledge_conflict',
          where: 'id = ?', whereArgs: [conflictId]);
    }
    return id;
  }

  Future<String?> headHash(String uid) async {
    final docs = await storage.db.query('tb_kb_doc',
        columns: ['id'], where: 'uid = ?', whereArgs: [uid]);
    return docs.length == 1
        ? snapshotHash((await snapshot(storage.db, docs.single['id'] as int))
            .cast<String, dynamic>())
        : null;
  }

  Future<void> resolveConflict(int id,
      {required bool incoming, required String expectedHead}) async {
    await storage.db.transaction((tx) async {
      final rows = await tx
          .query('tb_knowledge_conflict', where: 'id = ?', whereArgs: [id]);
      if (rows.length != 1) throw const KnowledgeScopeException('冲突已变化，请刷新');
      final record = jsonDecode(rows.single['payload'] as String) as Map;
      if (record['kind'] == 'answer') {
        throw const KnowledgeScopeException('问答冲突请保留原文核对');
      }
      final foreign = (record['kind'] == 'document'
              ? record['snapshot'] as Map
              : jsonDecode(record['payload'] as String) as Map)
          .cast<String, dynamic>();
      final foreignDoc = foreign['document'] as Map;
      final docs = await tx
          .query('tb_kb_doc', where: 'uid = ?', whereArgs: [foreignDoc['uid']]);
      if (docs.length != 1) {
        throw const KnowledgeScopeException('文档已删除，请将冲突另存为新文档');
      }
      final current = (await snapshot(tx, docs.single['id'] as int))
          .cast<String, dynamic>();
      if (snapshotHash(current) != expectedHead) {
        throw const KnowledgeScopeException('本机版本已变化，请重新核对');
      }
      await _checkpoint(tx, docs.single['id'] as int);
      await tx.insert(
          tableName,
          {
            'uid': foreignDoc['uid'],
            'revision': foreignDoc['revision'],
            'hash': snapshotHash(foreign),
            'payload': jsonEncode(foreign)
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      final selected = incoming ? foreign : current;
      final next = Map<String, dynamic>.from(selected['document'] as Map)
        ..remove('id');
      final old = docs.single;
      next['revision'] =
          (old['revision'] as int) > (foreignDoc['revision'] as int)
              ? (old['revision'] as int) + 1
              : (foreignDoc['revision'] as int) + 1;
      final remoteAt = foreignDoc['updatedAt'] as int;
      next['updatedAt'] = _nextAt((old['updatedAt'] as int) > remoteAt
          ? old['updatedAt'] as int
          : remoteAt);
      next['createdAt'] = old['createdAt'];
      next['syncParent'] = snapshotHash(foreign);
      await tx
          .update('tb_kb_doc', next, where: 'id = ?', whereArgs: [old['id']]);
      await tx
          .delete('tb_kb_chunk', where: 'docId = ?', whereArgs: [old['id']]);
      await tx
          .delete('tb_kb_vector', where: 'docId = ?', whereArgs: [old['id']]);
      for (final c in selected['chunks'] as List) {
        await tx.insert(
            'tb_kb_chunk',
            Map<String, dynamic>.from(c as Map)
              ..remove('id')
              ..['docId'] = old['id']);
      }
      await _checkpoint(tx, old['id'] as int);
      await tx
          .delete('tb_knowledge_conflict', where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<void> organize(KnowledgeDoc doc,
      {required String folder,
      required List<String> tags,
      required bool archived}) async {
    final clean =
        tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList();
    if (folder.length > 100 ||
        clean.length > 20 ||
        clean.any((t) => t.length > 40)) {
      throw const KnowledgeScopeException('文件夹最多100字，标签最多20个、每个40字');
    }
    await storage.db.transaction((tx) async {
      await _guard(tx, doc);
      await _checkpoint(tx, doc.id!);
      final parent =
          snapshotHash((await snapshot(tx, doc.id!)).cast<String, dynamic>());
      await tx.update(
          'tb_kb_doc',
          {
            'folder': folder.trim(),
            'tags': jsonEncode(clean),
            'archived': archived ? 1 : 0,
            'revision': doc.revision + 1,
            'syncParent': parent,
            'updatedAt': _nextAt(doc.updatedAt)
          },
          where: 'id = ?',
          whereArgs: [doc.id]);
      await _checkpoint(tx, doc.id!);
    });
  }

  @override
  Future<void> revise(KnowledgeDoc doc, String text) async {
    final chunks = KnowledgeChunker.split(text);
    if (chunks.isEmpty || text.length > 1000000) {
      throw const KnowledgeScopeException('新版本正文须为1～1000000字符');
    }
    await storage.db.transaction((tx) async {
      await _guard(tx, doc);
      await _checkpoint(tx, doc.id!);
      final parent =
          snapshotHash((await snapshot(tx, doc.id!)).cast<String, dynamic>());
      await tx.delete('tb_kb_chunk', where: 'docId = ?', whereArgs: [doc.id]);
      await tx.delete('tb_kb_vector', where: 'docId = ?', whereArgs: [doc.id]);
      final batch = tx.batch();
      for (var i = 0; i < chunks.length; i++) {
        batch.insert('tb_kb_chunk', {
          'docId': doc.id,
          'seq': i,
          'content': chunks[i],
          'pageNumber': null
        });
      }
      await batch.commit(noResult: true);
      await tx.update(
          'tb_kb_doc',
          {
            'chunkCount': chunks.length,
            'revision': doc.revision + 1,
            'syncParent': parent,
            'contentHash': hashPages([text]),
            'sourceKind': 'text',
            'sourceAsset': '',
            'updatedAt': _nextAt(doc.updatedAt)
          },
          where: 'id = ?',
          whereArgs: [doc.id]);
      await _checkpoint(tx, doc.id!);
    });
    await dao.rebuildVectorIndex(docId: doc.id);
  }

  static Future<Directory> assetDirectory({String? account}) async {
    final root = await getApplicationDocumentsDirectory();
    final token = AccountResourceScope.tokenFor(
        AccountResourceScope.currentAccountHash(account));
    return Directory('${root.path}/accounts/$token/knowledge_sources')
        .create(recursive: true);
  }

  Future<void> preservePdf(int docId, Uint8List bytes) async {
    final name = '${sha256.convert(bytes)}.pdf';
    final dir = await assetDirectory(account: account);
    final file = File('${dir.path}/$name');
    if (await verifiedPdf(name, account: account) == null) {
      final temporary =
          File('${file.path}.part-${DateTime.now().microsecondsSinceEpoch}');
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    await storage.db.transaction((tx) async {
      final before = (await snapshot(tx, docId)).cast<String, dynamic>();
      final old = before['document'] as Map;
      if (old['sourceAsset'] == name) return;
      await tx.update(
          'tb_kb_doc',
          {
            'sourceAsset': name,
            'updatedAt': _nextAt(old['updatedAt'] as int),
            'syncParent': snapshotHash(before)
          },
          where: 'id = ?',
          whereArgs: [docId]);
      final snap = (await snapshot(tx, docId)).cast<String, dynamic>();
      final doc = snap['document'] as Map;
      await tx.delete(tableName,
          where: 'uid = ? and hash = ?',
          whereArgs: [doc['uid'], snapshotHash(before)]);
      await tx.insert(
          tableName,
          {
            'uid': doc['uid'],
            'revision': doc['revision'],
            'hash': snapshotHash(snap),
            'payload': jsonEncode(snap)
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  static Future<File?> verifiedPdf(String name, {String? account}) async {
    if (!RegExp(r'^[a-f0-9]{64}\.pdf$').hasMatch(name)) return null;
    final dir = await assetDirectory(account: account);
    final file = File('${dir.path}/$name');
    if (!await file.exists() || await file.length() > 64 * 1024 * 1024) {
      return null;
    }
    final resolved = await file.resolveSymbolicLinks();
    if (resolved != '${await dir.resolveSymbolicLinks()}/$name') return null;
    return sha256.convert(await file.readAsBytes()).toString() ==
            name.substring(0, 64)
        ? file
        : null;
  }
}
