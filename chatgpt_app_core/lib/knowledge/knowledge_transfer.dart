import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'knowledge_library.dart';
import 'knowledge_repository.dart';
import 'knowledge_evidence.dart';

/// 只传输知识工作台数据，不包含 AI 配置、凭据和本地绝对路径。
class KnowledgeTransfer {
  static const file = 'knowledge_workbench.json';
  static const maxAssetBytes = 24 * 1024 * 1024;
  static void validateSnapshot(Map<String, dynamic> payload) {
    const docKeys = {
      'id',
      'title',
      'chunkCount',
      'createdAt',
      'uid',
      'revision',
      'folder',
      'tags',
      'contentHash',
      'updatedAt',
      'archived',
      'sourceKind',
      'sourceAsset',
      'syncParent'
    };
    const chunkKeys = {'id', 'docId', 'seq', 'content', 'pageNumber'};
    final doc = (payload['document'] as Map).cast<String, dynamic>();
    final chunks = payload['chunks'] as List;
    final seen = <int>{};
    final asset = doc['sourceAsset'] as String? ?? '';
    if (doc.keys.any((k) => !docKeys.contains(k)) ||
        doc['uid'] is! String ||
        (doc['uid'] as String).isEmpty ||
        doc['title'] is! String ||
        (doc['title'] as String).length > 1000 ||
        doc['revision'] is! int ||
        (doc['revision'] as int) < 1 ||
        doc['createdAt'] is! int ||
        doc['updatedAt'] is! int ||
        !const [0, 1].contains(doc['archived']) ||
        chunks.length > 5000 ||
        doc['chunkCount'] != chunks.length ||
        asset.isNotEmpty && !RegExp(r'^[a-f0-9]{64}\.pdf$').hasMatch(asset)) {
      throw const FormatException('知识文档快照无效');
    }
    for (final raw in chunks) {
      final c = (raw as Map).cast<String, dynamic>();
      final seq = c['seq'], page = c['pageNumber'];
      if (c.keys.any((k) => !chunkKeys.contains(k)) ||
          seq is! int ||
          seq < 0 ||
          !seen.add(seq) ||
          c['content'] is! String ||
          (c['content'] as String).length > 3000 ||
          page != null && (page is! int || page < 1 || page > 10000)) {
        throw const FormatException('知识片段位置或正文无效');
      }
    }
    if (seen.length != chunks.length || seen.any((n) => n >= chunks.length)) {
      throw const FormatException('知识片段序号不连续');
    }
  }

  static Future<void> ensure(HiDBManager storage) async {
    await KnowledgeLibrary.create(storage, account: 'schema-only');
    await KnowledgeRepository.create(storage);
    await storage.db.execute(
        'create table if not exists tb_knowledge_conflict ('
        'id integer primary key autoincrement, uid text not null, payload text not null, createdAt integer not null)');
  }

  static Future<List<Map<String, dynamic>>> read(
      HiDBManager storage, String account) async {
    await ensure(storage);
    final rows = <Map<String, dynamic>>[];
    for (final row in await storage.db.query('tb_knowledge_answer')) {
      rows.add({
        'kind': 'answer',
        'uid': row['uid'],
        'createdAt': row['createdAt'],
        'deletedAt': row['deletedAt'],
        'payload': row['payload']
      });
    }
    for (final row in await storage.db.query('tb_kb_revision')) {
      rows.add({'kind': 'revision', ...row});
    }
    for (final row in await storage.db.query('tb_kb_deleted')) {
      rows.add({'kind': 'deletedDocument', ...row});
    }
    final assets = <String>{};
    for (final doc
        in await storage.db.query('tb_kb_doc', columns: ['sourceAsset'])) {
      final name = doc['sourceAsset'] as String? ?? '';
      if (name.isNotEmpty) assets.add(name);
    }
    // 修订与历史引用也可能指向已替换的原件。
    for (final row in rows) {
      if (row['kind'] == 'deletedDocument') continue;
      final payload = jsonDecode(row['payload'] as String);
      if (row['kind'] == 'revision') {
        final name = payload['document']['sourceAsset'] as String? ?? '';
        if (name.isNotEmpty) assets.add(name);
      } else {
        for (final s in payload['sources'] as List) {
          final name = s['sourceAsset'] as String? ?? '';
          if (name.isNotEmpty) assets.add(name);
        }
      }
    }
    var bytes = 0;
    for (final name in assets) {
      final original =
          await KnowledgeLibrary.verifiedPdf(name, account: account);
      if (original == null) continue;
      final data = await original.readAsBytes();
      bytes += data.length;
      if (bytes > maxAssetBytes) {
        throw const FormatException('知识原件合计超过24MiB，请分批备份');
      }
      rows.add({'kind': 'asset', 'uid': name, 'data': base64Encode(data)});
    }
    return validate(rows);
  }

  static List<Map<String, dynamic>> validate(List<Map<String, dynamic>> rows) {
    if (rows.length > 10000) throw const FormatException('知识工作台记录过多');
    final seen = <String>{};
    var total = 0;
    for (final row in rows) {
      final uid = row['uid'];
      final kind = row['kind'];
      if (uid is! String ||
          uid.isEmpty ||
          uid.length > 128 ||
          !const ['answer', 'revision', 'asset', 'deletedDocument']
              .contains(kind)) {
        throw const FormatException('知识工作台记录身份无效');
      }
      final key =
          '$kind:$uid:${row['revision'] ?? ''}:${kind == 'revision' ? KnowledgeLibrary.snapshotHash((jsonDecode(row['payload'] as String) as Map).cast<String, dynamic>()) : ''}';
      if (!seen.add(key)) throw const FormatException('知识工作台记录重复');
      if (kind == 'deletedDocument') {
        if (row['updatedAt'] is! int || (row['updatedAt'] as int) < 1) {
          throw const FormatException('文档删除标记无效');
        }
      } else if (kind == 'asset') {
        if (!RegExp(r'^[a-f0-9]{64}\.pdf$').hasMatch(uid) ||
            row.keys.any((k) => !const ['kind', 'uid', 'data'].contains(k))) {
          throw const FormatException('知识原件名称无效');
        }
        final data = base64Decode(row['data'] as String);
        total += data.length;
        if (total > maxAssetBytes ||
            data.isEmpty ||
            sha256.convert(data).toString() != uid.substring(0, 64)) {
          throw const FormatException('知识原件摘要或大小无效');
        }
      } else {
        if (row['payload'] is! String ||
            (row['payload'] as String).length > 2000000) {
          throw const FormatException('知识快照大小无效');
        }
        final payload = (jsonDecode(row['payload'] as String) as Map)
            .cast<String, dynamic>();
        if (kind == 'answer') {
          final answer = KnowledgeAnswer.fromJson(payload);
          if (row['createdAt'] is! int ||
              row['deletedAt'] is! int ||
              answer.question.length > 1000 ||
              answer.sources.length > 6) {
            throw const FormatException('知识问答元数据无效');
          }
          if (answer.status == KnowledgeAnswerStatus.cited) {
            final verified = KnowledgeAnswerVerifier.verify(
                jsonEncode({
                  'status': 'supported',
                  'claims': [
                    for (final c in answer.claims)
                      {
                        'text': c.text,
                        'evidence': [
                          for (final q in c.evidence)
                            {'source': q.source.key, 'quote': q.quote}
                        ]
                      }
                  ]
                }),
                answer.sources);
            if (verified == null ||
                verified.isEmpty ||
                answer.claims.any((c) => c.evidence.any((q) =>
                    !answer.sources.any((s) => s.digest == q.source.digest)))) {
              throw const FormatException('知识问答引文核验失败');
            }
          } else if (answer.claims.isNotEmpty) {
            throw const FormatException('无证据状态不能包含结论');
          }
        } else {
          validateSnapshot(payload);
          final doc = (payload['document'] as Map).cast<String, dynamic>();
          final chunks = payload['chunks'] as List;
          if (row['revision'] is! int ||
              (row['revision'] as int) < 1 ||
              doc['uid'] != uid ||
              doc['revision'] != row['revision'] ||
              chunks.length > 5000 ||
              chunks.any((c) =>
                  c['content'] is! String ||
                  (c['content'] as String).length > 3000)) {
            throw const FormatException('知识修订快照无效');
          }
        }
      }
    }
    return rows;
  }

  static Future<void> writeAssets(
      List<Map<String, dynamic>> rows, Directory staged) async {
    for (final row in validate(rows).where((r) => r['kind'] == 'asset')) {
      await File('${staged.path}/${row['uid']}')
          .writeAsBytes(base64Decode(row['data'] as String), flush: true);
    }
  }

  static Future<void> restore(
      DatabaseExecutor tx, List<Map<String, dynamic>> rows,
      {required bool overwrite}) async {
    if (overwrite) {
      await tx.delete('tb_knowledge_answer', where: 'deletedAt = 0');
      await tx.delete('tb_kb_revision');
      await tx.delete('tb_knowledge_conflict');
    }
    for (final row in rows.where((r) => r['kind'] == 'deletedDocument')) {
      await tx.insert(
          'tb_kb_deleted', {'uid': row['uid'], 'updatedAt': row['updatedAt']},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // 恢复旧备份也不得清除已同步的删除标记。
    for (final deleted in await tx.query('tb_kb_deleted')) {
      final docs = await tx.query('tb_kb_doc',
          columns: ['id'], where: 'uid = ?', whereArgs: [deleted['uid']]);
      for (final doc in docs) {
        for (final table in ['tb_kb_chunk', 'tb_kb_vector', 'tb_project_kb']) {
          await tx.delete(table, where: 'docId = ?', whereArgs: [doc['id']]);
        }
      }
      await tx
          .delete('tb_kb_doc', where: 'uid = ?', whereArgs: [deleted['uid']]);
    }
    for (final row in rows
        .where((r) => r['kind'] == 'answer' || r['kind'] == 'revision')) {
      final answer = row['kind'] == 'answer';
      final table = answer ? 'tb_knowledge_answer' : 'tb_kb_revision';
      final hash = answer
          ? ''
          : KnowledgeLibrary.snapshotHash(
              (jsonDecode(row['payload'] as String) as Map)
                  .cast<String, dynamic>());
      final where = answer ? 'uid = ?' : 'uid = ? and hash = ?';
      final args = [row['uid'], if (!answer) hash];
      final existing = await tx.query(table, where: where, whereArgs: args);
      final value = Map<String, dynamic>.from(row)..remove('kind');
      if (!answer) value['hash'] = hash;
      if (answer && (row['deletedAt'] as int) > 0) {
        value['payload'] =
            KnowledgeRepository.emptyHistoryPayload(row['createdAt'] as int);
      }
      if (answer &&
          existing.isNotEmpty &&
          (existing.single['deletedAt'] as int) > 0 &&
          (row['deletedAt'] as int) == 0) {
        continue;
      }
      if (existing.isEmpty) {
        await tx.insert(table, value);
      } else if (answer && (row['deletedAt'] as int) > 0) {
        // 删除标记只推进删除状态，不能被旧备份或同步快照复活。
        await tx.update(
            table, {'deletedAt': row['deletedAt'], 'payload': value['payload']},
            where: where, whereArgs: args);
      } else if (answer && existing.single['payload'] != row['payload']) {
        await tx.insert('tb_knowledge_conflict', {
          'uid': row['uid'],
          'payload': jsonEncode(row),
          'createdAt': DateTime.now().millisecondsSinceEpoch
        });
      }
    }
  }
}
