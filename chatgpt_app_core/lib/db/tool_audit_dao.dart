import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/tool_audit_record.dart';

class ToolAuditDao implements ITable {
  final HiDBManager storage;

  ToolAuditDao._(this.storage);

  static const _kTableName = 'tb_tool_audit';

  static Future<ToolAuditDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', toolName text not null, sourceType text, sourceId text, sourceName text'
        ', trusted integer not null, readOnly integer not null'
        ', approved integer not null, success integer not null, argCount integer not null'
        ', argsPreview text, resultPreview text, error text, createdAt integer not null);');
    await storage.db.execute(
        'create index if not exists ${_kTableName}_created_idx on $_kTableName(createdAt desc);');
    await storage.db.execute(
        'create index if not exists ${_kTableName}_tool_idx on $_kTableName(toolName);');
    return ToolAuditDao._(storage);
  }

  @override
  String tableName = _kTableName;

  Future<int> record(ToolAuditRecord record) {
    final data = record.toJson()..remove('id');
    return storage.db.insert(tableName, data);
  }

  Future<List<ToolAuditRecord>> latest({int limit = 50}) async {
    final rows = await storage.db.query(
      tableName,
      orderBy: 'createdAt desc, id desc',
      limit: limit.clamp(1, 200),
    );
    return rows.map((row) => ToolAuditRecord.fromJson(row)).toList();
  }

  Future<int> clear() => storage.db.delete(tableName);
}
