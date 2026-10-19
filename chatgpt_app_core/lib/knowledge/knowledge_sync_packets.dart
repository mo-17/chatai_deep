import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';

/// 沿用服务器单条512KiB预算；大快照拆为内容寻址分片，指针保留原来的LWW身份。
class KnowledgeSyncPackets {
  static const packet = 'knowledge_packet_v2', pointer = 'knowledge_pointer_v2';
  static const entities = {packet, pointer};
  static const partBytes = 128 * 1024, maxBytes = 8 * 1024 * 1024;
  static Object? canonical(Object? value) => value is Map
      ? {
          for (final key in value.keys.cast<String>().toList()..sort())
            key: canonical(value[key])
        }
      : value is List
          ? value.map(canonical).toList()
          : value;
  static List<SyncChange> wrap(List<SyncChange> changes) {
    final result = <SyncChange>[];
    final sent = <String>{};
    for (final raw in changes) {
      final change = SyncChange(
          entity: raw.entity,
          id: raw.id,
          op: raw.op,
          updatedAt: raw.updatedAt,
          payload: (canonical(raw.payload) as Map).cast<String, dynamic>());
      final bytes = utf8.encode(jsonEncode(change.payload));
      if (bytes.length <= 384 * 1024) {
        result.add(change);
        continue;
      }
      if (bytes.length > maxBytes) {
        throw const FormatException('单个知识快照超过8MiB，请拆分资料');
      }
      final hash = sha256.convert(bytes).toString(),
          total = (bytes.length / partBytes).ceil();
      if (sent.add(hash)) {
        for (var i = 0; i < total; i++) {
          final end = (i + 1) * partBytes > bytes.length
              ? bytes.length
              : (i + 1) * partBytes;
          result.add(SyncChange(
              entity: packet,
              id: '$hash:$i',
              op: SyncOp.upsert,
              updatedAt: 1,
              payload: {
                'hash': hash,
                'part': i,
                'total': total,
                'data': base64Encode(bytes.sublist(i * partBytes, end))
              }));
        }
      }
      result.add(SyncChange(
          entity: pointer,
          id: sha256.convert(utf8.encode(change.key)).toString(),
          op: SyncOp.upsert,
          updatedAt: change.updatedAt,
          payload: {
            'entity': change.entity,
            'id': change.id,
            'hash': hash,
            'total': total,
            'size': bytes.length
          }));
    }
    return result;
  }

  static Future<List<SyncChange>> unwrap(HiDBManager storage,
      List<SyncChange> changes, Set<String> allowed) async {
    await storage.db.execute(
        'create table if not exists tb_kb_packet (hash text,part integer,total integer,data text,primary key(hash,part))');
    for (final change in changes.where((c) => c.entity == packet)) {
      final p = change.payload,
          hash = change.payload['hash'],
          part = change.payload['part'],
          total = change.payload['total'];
      if (hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          part is! int ||
          total is! int ||
          total < 1 ||
          total > 64 ||
          part < 0 ||
          part >= total ||
          change.id != '$hash:$part' ||
          p['data'] is! String ||
          (p['data'] as String).length > 180000) {
        throw const FormatException('知识快照分片无效');
      }
      final bytes = base64Decode(p['data'] as String);
      if (bytes.length > partBytes) throw const FormatException('知识快照分片超限');
      await storage.db.insert('tb_kb_packet',
          {'hash': hash, 'part': part, 'total': total, 'data': p['data']},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final expanded =
        changes.where((c) => !entities.contains(c.entity)).toList();
    for (final change in changes.where((c) => c.entity == pointer)) {
      final hash = change.payload['hash'],
          entity = change.payload['entity'],
          id = change.payload['id'],
          total = change.payload['total'],
          size = change.payload['size'];
      if (hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          entity is! String ||
          !allowed.contains(entity) ||
          id is! String ||
          id.length > 255 ||
          size is! int ||
          size < 1 ||
          size > maxBytes ||
          total is! int ||
          total < 1 ||
          total > 64 ||
          change.id != sha256.convert(utf8.encode('$entity:$id')).toString()) {
        throw const FormatException('知识快照指针无效');
      }
      final parts = await storage.db.query('tb_kb_packet',
          where: 'hash = ?', whereArgs: [hash], orderBy: 'part');
      if (parts.length != total || parts.any((r) => r['total'] != total)) {
        throw const FormatException('知识快照分片未齐，请稍后重试同步');
      }
      final bytes = <int>[];
      for (var i = 0; i < parts.length; i++) {
        if (parts[i]['part'] != i) throw const FormatException('知识快照分片位置无效');
        bytes.addAll(base64Decode(parts[i]['data'] as String));
      }
      if (bytes.length != size || sha256.convert(bytes).toString() != hash) {
        throw const FormatException('知识快照摘要不符');
      }
      final payload =
          (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
      expanded.add(SyncChange(
          entity: entity,
          id: id,
          op: SyncOp.upsert,
          updatedAt: change.updatedAt,
          payload: payload));
    }
    return expanded;
  }
}
