import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../chat/application/pdf_ocr_result.dart';
import 'hi_db_manager.dart';
import 'table_name.dart';

enum OcrTaskState {
  waiting,
  queued,
  running,
  review,
  completed,
  failed,
  cancelled,
  interrupted
}

class OcrTaskRecord {
  final String id, name, origin, error;
  final bool pdf;
  final int size, createdAt, updatedAt;
  final OcrTaskState state;
  const OcrTaskRecord(
      {required this.id,
      required this.name,
      required this.origin,
      required this.pdf,
      required this.size,
      required this.createdAt,
      required this.updatedAt,
      required this.state,
      this.error = ''});
  factory OcrTaskRecord.fromRow(Map<String, Object?> row) => OcrTaskRecord(
      id: row['id'] as String,
      name: row['name'] as String,
      origin: row['origin'] as String,
      pdf: row['pdf'] == 1,
      size: row['size'] as int,
      createdAt: row['createdAt'] as int,
      updatedAt: row['updatedAt'] as int,
      state: OcrTaskState.values.byName(row['state'] as String),
      error: row['error'] as String);
  bool get retryable => const {
        OcrTaskState.waiting,
        OcrTaskState.failed,
        OcrTaskState.cancelled,
        OcrTaskState.interrupted
      }.contains(state);
  bool get hasResult =>
      state == OcrTaskState.review || state == OcrTaskState.completed;
}

class OcrTaskData {
  final OcrTaskRecord task;
  final Uint8List bytes;
  final PdfOcrResult? result;
  const OcrTaskData(this.task, this.bytes, this.result);
}

abstract class IOcrTasks {
  Future<List<OcrTaskRecord>> list();
  Future<OcrTaskData?> load(String id);
}

/// 原件与结果只存当前账号 SQLite；不存令牌，不进入云同步/备份。
class OcrTaskDao implements IOcrTasks, ITable {
  static const maxTasks = 20, maxSourceBytes = 40 * 1024 * 1024;
  static const maxResultBytes = 16 * 1024 * 1024;
  final HiDBManager storage;
  @override
  String tableName = 'tb_ocr_tasks';
  OcrTaskDao._(this.storage);
  static Future<OcrTaskDao> create(HiDBManager storage) async {
    final dao = OcrTaskDao._(storage);
    await storage.db.execute('''CREATE TABLE IF NOT EXISTS ${dao.tableName} (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, origin TEXT NOT NULL,
      pdf INTEGER NOT NULL, size INTEGER NOT NULL, digest TEXT NOT NULL,
      source BLOB NOT NULL, state TEXT NOT NULL, result TEXT,
      error TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL
    )''');
    return dao;
  }

  static const _summary = [
    'id',
    'name',
    'origin',
    'pdf',
    'size',
    'state',
    'error',
    'createdAt',
    'updatedAt'
  ];
  @override
  Future<List<OcrTaskRecord>> list() async => (await storage.db.query(tableName,
          columns: _summary, orderBy: 'createdAt ASC, id ASC'))
      .map(OcrTaskRecord.fromRow)
      .toList();

  @override
  Future<OcrTaskData?> load(String id) async {
    final rows = await storage.db
        .query(tableName, where: 'id=?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final bytes =
        Uint8List.fromList(row['source'] as List<int>).asUnmodifiableView();
    if (bytes.length != row['size'] ||
        sha256.convert(bytes).toString() != row['digest']) {
      throw const FormatException('原件副本校验失败，请删除任务并重新选择文件');
    }
    final result = row['result'] as String?;
    return OcrTaskData(OcrTaskRecord.fromRow(row), bytes,
        result == null ? null : PdfOcrResult.fromJson(jsonDecode(result)));
  }

  Future<String> add(
      {required String name,
      required String origin,
      required bool pdf,
      required Uint8List bytes,
      required void Function() verify}) async {
    if (bytes.isEmpty ||
        bytes.length > 8 * 1024 * 1024 ||
        name.trim().isEmpty ||
        name.length > 255) {
      throw const FormatException('请选择有效文件，单文件最多 8 MiB');
    }
    final frozen = Uint8List.fromList(bytes);
    final random = Random.secure();
    final id = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    return storage.db.transaction((tx) async {
      verify();
      final usage = (await tx.rawQuery(
              'SELECT COUNT(*) AS count, COALESCE(SUM(size),0) AS bytes FROM $tableName'))
          .single;
      if ((usage['count'] as int) >= maxTasks ||
          (usage['bytes'] as int) + frozen.length > maxSourceBytes) {
        throw const FormatException('任务中心最多保留 20 个任务、40 MiB 原件，请先删除旧任务');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await tx.insert(tableName, {
        'id': id,
        'name': name,
        'origin': origin,
        'pdf': pdf ? 1 : 0,
        'size': frozen.length,
        'digest': sha256.convert(frozen).toString(),
        'source': frozen,
        'state': OcrTaskState.waiting.name,
        'createdAt': now,
        'updatedAt': now
      });
      verify();
      return id;
    });
  }

  Future<void> recover(void Function() verify) =>
      storage.db.transaction((tx) async {
        verify();
        await tx.update(
            tableName,
            {
              'state': OcrTaskState.interrupted.name,
              'error': '上次处理已中断，请手动重试',
              'updatedAt': DateTime.now().millisecondsSinceEpoch
            },
            where: 'state IN (?,?)',
            whereArgs: [OcrTaskState.queued.name, OcrTaskState.running.name]);
        verify();
      });

  Future<bool> transition(String id, Set<OcrTaskState> from, OcrTaskState to,
          {required void Function() verify,
          String error = '',
          PdfOcrResult? result,
          bool clearResult = false}) =>
      storage.db.transaction((tx) async {
        verify();
        String? encoded;
        if (result != null) {
          encoded = jsonEncode(result.toJson());
          final size = utf8.encode(encoded).length;
          if (size > 2 * 1024 * 1024) {
            throw const FormatException('识别结果超过 2 MiB 上限');
          }
          final used = (await tx.rawQuery(
                  'SELECT COALESCE(SUM(LENGTH(CAST(result AS BLOB))),0) AS bytes FROM $tableName WHERE id<>?',
                  [id]))
              .single['bytes'] as int;
          if (used + size > maxResultBytes) {
            throw const FormatException('识别结果存储已满，请删除旧任务后重试');
          }
        }
        final changed = await tx.update(
            tableName,
            {
              'state': to.name,
              'error': error,
              'updatedAt': DateTime.now().millisecondsSinceEpoch,
              if (encoded != null || clearResult) 'result': encoded
            },
            where:
                'id=? AND state IN (${List.filled(from.length, '?').join(',')})',
            whereArgs: [id, ...from.map((s) => s.name)]);
        verify();
        return changed == 1;
      });

  Future<void> delete(String id, void Function() verify) =>
      storage.db.transaction((tx) async {
        verify();
        await tx.delete(tableName, where: 'id=?', whereArgs: [id]);
        verify();
      });
}
