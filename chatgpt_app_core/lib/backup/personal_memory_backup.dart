import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:sqflite/sqflite.dart';

/// 个人记忆只走本地备份，不进入 SyncV2 或远端同步实体。
class PersonalMemoryBackup {
  static const rowFiles = {
    'personal_memories.json': 'personalMemories',
    'personal_memory_preferences.json': 'personalMemoryPreferences',
    'personal_memory_journal.json': 'personalMemoryJournal',
    'personal_memory_tombstones.json': 'personalMemoryTombstones',
    'personal_memory_suppression.json': 'personalMemorySuppression',
  };
  static const tables = {
    'personal_memories.json': 'tb_personal_memory',
    'personal_memory_preferences.json': 'tb_personal_memory_preferences',
    'personal_memory_journal.json': 'tb_personal_memory_journal',
    'personal_memory_tombstones.json': 'tb_personal_memory_tombstone',
    'personal_memory_suppression.json': 'tb_personal_memory_suppression',
  };
  static Future<Map<String, List<Map<String, dynamic>>>> read(
          DatabaseExecutor db) async =>
      {
        for (final entry in tables.entries)
          entry.key: await db.query(entry.value),
      };
  static bool _uuid(Object? value) =>
      value is String &&
      RegExp(r'^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$')
          .hasMatch(value);
  static bool _hash(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static void _require(bool condition, String detail) {
    if (!condition) throw FormatException('个人记忆备份无效：$detail');
  }

  /// 在恢复事务前验证边界；非法状态保守停用，凭证、无界数据直接拒绝。
  static Map<String, List<Map<String, dynamic>>> validate(
      Map<String, List<Map<String, dynamic>>> input,
      {List<Map<String, dynamic>> messages = const [],
      List<Map<String, dynamic>> conversations = const []}) {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final file in tables.keys) {
      final rows = input[file] ?? const <Map<String, dynamic>>[];
      final limit = file == 'personal_memories.json'
          ? PersonalMemoryDao.maxEntries
          : file == 'personal_memory_preferences.json'
              ? 1
              : 5000;
      _require(rows.length <= limit, '$file 超过上限');
      result[file] = [];
      final ids = <String>{};
      final contentKeys = <String>{};
      for (final row in rows) {
        if (file == 'personal_memories.json') {
          _require(
              _uuid(row['memoryId']) && row['content'] is String, '身份或正文类型');
          PersonalMemoryDao.validateContent(row['content'] as String);
          _require(
              row['revision'] is int &&
                  (row['revision'] as int) > 0 &&
                  row['createdAt'] is int &&
                  row['updatedAt'] is int,
              '时间或修订号');
          final memory = PersonalMemory.fromJson(row);
          _require(
              ids.add(memory.memoryId) && contentKeys.add(memory.normalizedKey),
              '重复记忆');
          _require(
              _hash(row['normalizedKey']) &&
                  memory.normalizedKey == PersonalMemory.keyFor(memory.content),
              '正文指纹');
          final recognizedSource = const [
            'manual',
            'user_message',
            'local_suggestion'
          ].contains(memory.sourceType);
          final validSource = recognizedSource &&
              (memory.sourceType == 'manual'
                  ? memory.sourceCid == null && memory.sourceMessageId.isEmpty
                  : memory.sourceCid != null &&
                      _uuid(memory.sourceMessageId) &&
                      _hash(memory.sourceFingerprint) &&
                      conversations
                              .where((c) =>
                                  c['cid'] == memory.sourceCid &&
                                  c['assistantId'] == null)
                              .length ==
                          1 &&
                      messages
                              .where((m) =>
                                  m['cid'] == memory.sourceCid &&
                                  m['memorySourceId'] ==
                                      memory.sourceMessageId &&
                                  m['ownerType'] ==
                                      OwnerType.sender.toString() &&
                                  PersonalMemory.fingerprint(
                                          m['content'] as String? ?? '') ==
                                      memory.sourceFingerprint)
                              .length ==
                          1);
          final next = memory.toJson();
          if (memory.status != PersonalMemoryStatus.active) {
            next['confirmedByUser'] = 0;
          }
          if (!validSource ||
              !PersonalMemoryStatus.values
                  .any((s) => s.name == row['status']) ||
              memory.status == PersonalMemoryStatus.active &&
                  !memory.confirmedByUser) {
            next['status'] = 'archived';
            next['confirmedByUser'] = 0;
            next['invalidReason'] = '恢复数据状态或来源无效';
          }
          // 恢复不迁移自动建议授权，pending 不能在新账号/epoch 确认。
          if (memory.status == PersonalMemoryStatus.pending) {
            next['status'] = 'archived';
            next['confirmedByUser'] = 0;
            next['invalidReason'] = '恢复后需手动重新添加';
          }
          result[file]!.add(next);
        } else if (file == 'personal_memory_preferences.json') {
          _require(
              row['id'] == 1 &&
                  row['epoch'] is int &&
                  row['revision'] is int &&
                  row['enabledSince'] is int &&
                  const [0, 1].contains(row['enabled']) &&
                  const [0, 1].contains(row['suggestionsEnabled']),
              '配置元数据');
          result[file]!.add(Map.from(row));
        } else if (file == 'personal_memory_suppression.json') {
          _require(
              _hash(row['normalizedKey']) &&
                  ids.add(row['normalizedKey'] as String),
              '候选抑制键');
          result[file]!.add({'normalizedKey': row['normalizedKey']});
        } else if (file == 'personal_memory_tombstones.json') {
          _require(
              _uuid(row['memoryId']) &&
                  ids.add(row['memoryId'] as String) &&
                  row['deletedAt'] is int,
              '删除标记');
          result[file]!.add(
              {'memoryId': row['memoryId'], 'deletedAt': row['deletedAt']});
        } else {
          _require(
              _uuid(row['sourceMessageId']) &&
                  ids.add(row['sourceMessageId'] as String) &&
                  (row['memoryId'] == '' || _uuid(row['memoryId'])) &&
                  row['epoch'] is int,
              '来源去重标记');
          result[file]!.add({
            'sourceMessageId': row['sourceMessageId'],
            'memoryId': row['memoryId'],
            'epoch': 0
          });
        }
      }
    }
    return result;
  }

  /// 调用方已经在同一事务内恢复了消息和会话。配置只保留本地 epoch 并关闭。
  static Future<int> restore(
      DatabaseExecutor txn, Map<String, List<Map<String, dynamic>>> rows,
      {required bool overwrite, Map<int, int> cidMap = const {}}) async {
    if (overwrite) await txn.delete('tb_personal_memory');
    final retainedIds = overwrite
        ? const <Object?>{}
        : (await txn.query('tb_personal_memory', columns: ['memoryId']))
            .map((row) => row['memoryId'])
            .toSet();
    // 删除/抑制标记合并保留，旧备份或同次 merge 重试不可复活用户删掉的项目。
    for (final file in [
      'personal_memory_tombstones.json',
      'personal_memory_suppression.json',
      'personal_memory_journal.json'
    ]) {
      final table = tables[file]!;
      for (final row in rows[file] ?? const <Map<String, dynamic>>[]) {
        // append/游客迁移保留目标现有行。来源删除不是目标的删除授权，
        // 也不能留下与保留行矛盾的标记，让下一次合并再删除它。
        if (file == 'personal_memory_tombstones.json' &&
            retainedIds.contains(row['memoryId'])) {
          continue;
        }
        await txn.insert(table, row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      _require(
          Sqflite.firstIntValue(
                  await txn.rawQuery('select count(*) from $table'))! <=
              5000,
          '去重元数据达到上限');
    }
    final deleted = (await txn.query('tb_personal_memory_tombstone'))
        .map((r) => r['memoryId'])
        .toSet();
    var inserted = 0;
    for (final raw
        in rows['personal_memories.json'] ?? const <Map<String, dynamic>>[]) {
      final next = Map<String, dynamic>.from(raw);
      final id = next['memoryId'];
      final key = next['normalizedKey'];
      if (deleted.contains(id) ||
          (await txn.query('tb_personal_memory',
                  where: 'memoryId=? or normalizedKey=?', whereArgs: [id, key]))
              .isNotEmpty) {
        continue;
      }
      _require(
          Sqflite.firstIntValue(await txn
                  .rawQuery('select count(*) from tb_personal_memory'))! <
              PersonalMemoryDao.maxEntries,
          '合并后超过200条');
      final source = next['sourceCid'] as int?;
      if (source != null && cidMap.isNotEmpty) {
        next['sourceCid'] = cidMap[source];
      }
      final sourceId = next['sourceMessageId'] as String;
      if (sourceId.isNotEmpty &&
          (next['sourceCid'] == null ||
              !await PersonalMemoryDao.sourceValid(
                  txn,
                  PersonalMemorySource(next['sourceCid'] as int, sourceId,
                      next['sourceFingerprint'] as String)))) {
        next['status'] = 'archived';
        next['confirmedByUser'] = 0;
        next['invalidReason'] = '来源已删除或修改';
      }
      await txn.insert('tb_personal_memory', next);
      inserted++;
    }
    await PersonalMemoryDao.disableAfterImport(txn);
    return inserted;
  }
}
