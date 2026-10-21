import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'knowledge_library.dart';
import 'knowledge_transfer.dart';
import 'knowledge_sync_packets.dart';
import 'package:crypto/crypto.dart';
import 'package:login_sdk/dao/backend_host.dart';

/// 复用账号隔离的同步传输；文档使用稳定 UUID，冲突正文另存而不静默覆盖。
class KnowledgeSync {
  static const document = 'knowledge_document_v2',
      record = 'knowledge_record_v2',
      asset = 'knowledge_pdf_part_v2',
      link = 'knowledge_project_link_v2';
  static const entities = {
    document,
    record,
    asset,
    link,
    ...KnowledgeSyncPackets.entities
  };
  static String _fingerprint(SyncChange c) => sha256
      .convert(utf8.encode(jsonEncode(KnowledgeSyncPackets.canonical(
          {'op': c.op.name, 'updatedAt': c.updatedAt, 'payload': c.payload}))))
      .toString();
  static Future<void> _ackTable(HiDBManager storage) => storage.db.execute(
      'create table if not exists tb_kb_upload_ack ('
      'origin text, entity text, entityId text, fingerprint text not null, primary key(origin,entity,entityId))');
  static Future<void> acknowledge(
      HiDBManager storage, Iterable<SyncChange> changes,
      {required String origin}) async {
    final known = changes.where((c) => entities.contains(c.entity)).toList();
    if (known.isEmpty) return;
    await _ackTable(storage);
    await storage.db.transaction((tx) async {
      for (final c in known) {
        await tx.insert(
            'tb_kb_upload_ack',
            {
              'origin': origin,
              'entity': c.entity,
              'entityId': c.id,
              'fingerprint': _fingerprint(c)
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Map<String, dynamic> _wireSnapshot(Map<String, dynamic> value) => {
        'document': Map<String, dynamic>.from(value['document'] as Map)
          ..remove('id'),
        'chunks': [
          for (final c in value['chunks'] as List)
            Map<String, dynamic>.from(c as Map)
              ..remove('id')
              ..remove('docId')
        ],
      };
  static Future<void> _links(HiDBManager storage) => storage.db.execute(
      'create table if not exists tb_kb_sync_link ('
      'projectId integer, uid text, updatedAt integer not null, deleted integer not null, primary key(projectId,uid))');
  static Future<List<SyncChange>> export(HiDBManager storage, String account,
      {int updatedAfter = 0, String? origin}) async {
    final scope = origin ?? BackendConfig.buildUri('/').origin;
    await KnowledgeTransfer.ensure(storage);
    final library = await KnowledgeLibrary.create(storage, account: account);
    final changes = <SyncChange>[];
    await _links(storage);
    final live = await storage.db.rawQuery(
        'select p.projectId,d.uid from tb_project_kb p inner join tb_kb_doc d on d.id=p.docId');
    final keys = {for (final row in live) '${row['projectId']}:${row['uid']}'};
    final tracked = await storage.db.query('tb_kb_sync_link');
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in live) {
      if (!tracked.any((t) =>
          t['projectId'] == row['projectId'] &&
          t['uid'] == row['uid'] &&
          t['deleted'] == 0)) {
        await storage.db.insert(
            'tb_kb_sync_link', {...row, 'updatedAt': now, 'deleted': 0},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    for (final row in tracked) {
      if (row['deleted'] == 0 &&
          !keys.contains('${row['projectId']}:${row['uid']}')) {
        await storage.db.update(
            'tb_kb_sync_link', {'deleted': 1, 'updatedAt': now},
            where: 'projectId = ? and uid = ?',
            whereArgs: [row['projectId'], row['uid']]);
      }
    }
    for (final row in await storage.db.query('tb_kb_sync_link')) {
      changes.add(SyncChange(
          entity: link,
          id: '${row['projectId']}:${row['uid']}',
          op: row['deleted'] == 1 ? SyncOp.delete : SyncOp.upsert,
          updatedAt: row['updatedAt'] as int,
          payload: {'projectId': row['projectId'], 'uid': row['uid']}));
    }
    for (final doc in await storage.db.query('tb_kb_doc')) {
      changes.add(SyncChange(
          entity: document,
          id: doc['uid'] as String,
          op: SyncOp.upsert,
          updatedAt: doc['updatedAt'] as int,
          payload: _wireSnapshot(
              (await library.snapshot(storage.db, doc['id'] as int))
                  .cast<String, dynamic>())));
    }
    for (final deleted in await storage.db.query('tb_kb_deleted')) {
      changes.add(SyncChange(
          entity: document,
          id: deleted['uid'] as String,
          op: SyncOp.delete,
          updatedAt: deleted['updatedAt'] as int));
    }
    for (final row in await KnowledgeTransfer.read(storage, account)) {
      if (row['kind'] == 'deletedDocument') continue;
      if (row['kind'] == 'asset') {
        final bytes = base64Decode(row['data'] as String);
        const size = 128 * 1024;
        final total = (bytes.length / size).ceil();
        for (var i = 0; i < total; i++) {
          final end =
              (i + 1) * size > bytes.length ? bytes.length : (i + 1) * size;
          changes.add(SyncChange(
              entity: asset,
              id: '${row['uid']}:$i',
              op: SyncOp.upsert,
              updatedAt: 1,
              payload: {
                'uid': row['uid'],
                'part': i,
                'total': total,
                'data': base64Encode(bytes.sublist(i * size, end))
              }));
        }
      } else {
        final digest = row['kind'] == 'revision'
            ? KnowledgeLibrary.snapshotHash(
                (jsonDecode(row['payload'] as String) as Map)
                    .cast<String, dynamic>())
            : '';
        changes.add(SyncChange(
            entity: record,
            id: '${row['kind']}:${row['uid']}:${row['revision'] ?? ''}:$digest',
            op: SyncOp.upsert,
            updatedAt: row['kind'] == 'answer'
                ? (row['deletedAt'] as int) > 0
                    ? row['deletedAt'] as int
                    : row['createdAt'] as int
                : 1,
            payload: row['kind'] == 'revision'
                ? {
                    ...row,
                    'payload': jsonEncode(KnowledgeSyncPackets.canonical(
                        _wireSnapshot(
                            (jsonDecode(row['payload'] as String) as Map)
                                .cast<String, dynamic>())))
                  }
                : row));
      }
    }
    // 不可变历史与内容寻址原件始终发送，由服务端幂等去重；删除只会推进。
    await _ackTable(storage);
    final acknowledged = {
      for (final r in await storage.db
          .query('tb_kb_upload_ack', where: 'origin = ?', whereArgs: [scope]))
        '${r['entity']}:${r['entityId']}': r['fingerprint']
    };
    return KnowledgeSyncPackets.wrap(changes)
        .where((c) => acknowledged[c.key] != _fingerprint(c))
        .toList();
  }

  static Future<SyncMergeResult> apply(
      HiDBManager storage, String account, List<SyncChange> incoming) async {
    await KnowledgeTransfer.ensure(storage);
    final wireAccepted = incoming
        .where((c) => KnowledgeSyncPackets.entities.contains(c.entity))
        .toList();
    incoming = await KnowledgeSyncPackets.unwrap(
        storage, incoming, {document, record});
    await _links(storage);
    await storage.db.execute(
        'create table if not exists tb_kb_pdf_part (uid text, part integer, total integer, data text, primary key(uid,part))');
    final library = await KnowledgeLibrary.create(storage, account: account);
    final accepted = <SyncChange>[...wireAccepted], stale = <SyncChange>[];
    final conflicts = <String>[];
    await storage.db.transaction((tx) async {
      for (final change in incoming.where((c) => c.entity == record)) {
        KnowledgeTransfer.validate([change.payload]);
        await KnowledgeTransfer.restore(tx, [change.payload], overwrite: false);
        accepted.add(change);
      }
      final heads = incoming.where((c) => c.entity == document).toList()
        ..sort((a, b) {
          if (a.op == SyncOp.delete) return b.op == SyncOp.delete ? 0 : 1;
          if (b.op == SyncOp.delete) return -1;
          return ((a.payload['document'] as Map)['revision'] as int)
              .compareTo((b.payload['document'] as Map)['revision'] as int);
        });
      for (final change in heads) {
        final deleted = await tx
            .query('tb_kb_deleted', where: 'uid = ?', whereArgs: [change.id]);
        final docs = await tx
            .query('tb_kb_doc', where: 'uid = ?', whereArgs: [change.id]);
        if (change.op == SyncOp.delete) {
          await tx.insert('tb_kb_deleted',
              {'uid': change.id, 'updatedAt': change.updatedAt},
              conflictAlgorithm: ConflictAlgorithm.replace);
          for (final d in docs) {
            for (final table in [
              'tb_kb_chunk',
              'tb_kb_vector',
              'tb_project_kb'
            ]) {
              await tx.delete(table, where: 'docId = ?', whereArgs: [d['id']]);
            }
          }
          await tx
              .delete('tb_kb_doc', where: 'uid = ?', whereArgs: [change.id]);
          accepted.add(change);
          continue;
        }
        if (deleted.isNotEmpty) {
          stale.add(change);
          continue;
        }
        final raw = change.payload;
        final doc = Map<String, dynamic>.from(raw['document'] as Map);
        if (doc['uid'] != change.id) throw const FormatException('知识同步身份不一致');
        KnowledgeTransfer.validate([
          {
            'kind': 'revision',
            'uid': doc['uid'],
            'revision': doc['revision'],
            'payload': jsonEncode(raw)
          }
        ]);
        final hash = KnowledgeLibrary.snapshotHash(raw);
        if (docs.isNotEmpty) {
          final current = (await library.snapshot(tx, docs.single['id'] as int))
              .cast<String, dynamic>();
          final currentHash = KnowledgeLibrary.snapshotHash(current);
          if (hash == currentHash) {
            accepted.add(change);
            continue;
          }
          var ancestor = doc['syncParent'] as String? ?? '';
          final chain = <String, String>{};
          for (final row in await tx.query('tb_kb_revision',
              where: 'uid = ?', whereArgs: [change.id])) {
            final snapshot = (jsonDecode(row['payload'] as String) as Map)
                .cast<String, dynamic>();
            chain[KnowledgeLibrary.snapshotHash(snapshot)] =
                (snapshot['document'] as Map)['syncParent'] as String? ?? '';
          }
          final visited = <String>{};
          while (ancestor.isNotEmpty &&
              ancestor != currentHash &&
              visited.length < 1000 &&
              visited.add(ancestor)) {
            ancestor = chain[ancestor] ?? '';
          }
          if (ancestor != currentHash) {
            final conflict = jsonEncode(
                {'kind': 'document', 'uid': change.id, 'snapshot': raw});
            if ((await tx.query('tb_knowledge_conflict',
                    where: 'uid = ? and payload = ?',
                    whereArgs: [change.id, conflict]))
                .isEmpty) {
              await tx.insert('tb_knowledge_conflict', {
                'uid': change.id,
                'payload': conflict,
                'createdAt': change.updatedAt
              });
            }
            conflicts.add(change.key);
            continue;
          }
        }
        final next = Map<String, dynamic>.from(doc)..remove('id');
        final id = docs.isEmpty
            ? await tx.insert('tb_kb_doc', next)
            : docs.single['id'] as int;
        if (docs.isNotEmpty) {
          await tx.update('tb_kb_doc', next, where: 'id = ?', whereArgs: [id]);
          await tx.delete('tb_kb_chunk', where: 'docId = ?', whereArgs: [id]);
          await tx.delete('tb_kb_vector', where: 'docId = ?', whereArgs: [id]);
        }
        for (final c in raw['chunks'] as List) {
          await tx.insert(
              'tb_kb_chunk',
              Map<String, dynamic>.from(c as Map)
                ..remove('id')
                ..['docId'] = id);
        }
        accepted.add(change);
      }
      for (final change in incoming.where((c) => c.entity == link)) {
        final project = change.payload['projectId'],
            uid = change.payload['uid'];
        if (project is! int ||
            project < 1 ||
            uid is! String ||
            change.id != '$project:$uid') {
          throw const FormatException('知识库项目绑定无效');
        }
        final existing = await tx.query('tb_kb_sync_link',
            where: 'projectId = ? and uid = ?', whereArgs: [project, uid]);
        if (existing.isNotEmpty &&
            (existing.single['updatedAt'] as int) > change.updatedAt) {
          stale.add(change);
          continue;
        }
        final docs = await tx.query('tb_kb_doc',
            columns: ['id'], where: 'uid = ?', whereArgs: [uid]);
        if (docs.length == 1) {
          if (change.op == SyncOp.delete) {
            await tx.delete('tb_project_kb',
                where: 'projectId = ? and docId = ?',
                whereArgs: [project, docs.single['id']]);
          } else {
            await tx.insert('tb_project_kb',
                {'projectId': project, 'docId': docs.single['id']},
                conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        await tx.insert(
            'tb_kb_sync_link',
            {
              'projectId': project,
              'uid': uid,
              'updatedAt': change.updatedAt,
              'deleted': change.op == SyncOp.delete ? 1 : 0
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        accepted.add(change);
      }
      for (final change in incoming.where((c) => c.entity == asset)) {
        final p = change.payload;
        final uid = p['uid'], part = p['part'], total = p['total'];
        if (uid is! String ||
            !RegExp(r'^[a-f0-9]{64}\.pdf$').hasMatch(uid) ||
            part is! int ||
            total is! int ||
            total < 1 ||
            total > 192 ||
            part < 0 ||
            part >= total ||
            change.id != '$uid:$part' ||
            p['data'] is! String ||
            (p['data'] as String).length > 180000) {
          throw const FormatException('知识原件分片无效');
        }
        await tx.insert('tb_kb_pdf_part',
            {'uid': uid, 'part': part, 'total': total, 'data': p['data']},
            conflictAlgorithm: ConflictAlgorithm.replace);
        accepted.add(change);
      }
    });
    // 分页可能拆开同一原件；所有分片到齐且 SHA 校验通过后才写入内容寻址文件。
    for (final uid in incoming
        .where((c) => c.entity == asset)
        .map((c) => c.payload['uid'] as String)
        .toSet()) {
      final parts = await storage.db.query('tb_kb_pdf_part',
          where: 'uid = ?', whereArgs: [uid], orderBy: 'part');
      if (parts.isEmpty ||
          parts.length != parts.first['total'] ||
          parts.any((p) => p['total'] != parts.length)) {
        continue;
      }
      final bytes = <int>[];
      for (final p in parts) {
        bytes.addAll(base64Decode(p['data'] as String));
      }
      final rows = [
        {'kind': 'asset', 'uid': uid, 'data': base64Encode(bytes)}
      ];
      KnowledgeTransfer.validate(rows);
      final target = await KnowledgeLibrary.assetDirectory(account: account);
      final file = appFile('${target.path}/$uid');
      if (await KnowledgeLibrary.verifiedPdf(uid, account: account) == null) {
        final temporary =
            appFile('${file.path}.part-${DateTime.now().microsecondsSinceEpoch}');
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      await storage.db
          .delete('tb_kb_pdf_part', where: 'uid = ?', whereArgs: [uid]);
    }
    return SyncMergeResult(
        accepted: accepted, rejectedStale: stale, conflicts: conflicts);
  }
}
