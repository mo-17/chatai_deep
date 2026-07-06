import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/model/tool_audit_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));

  test('记录并按时间倒序读取工具审计', () async {
    final storage = await newDb();
    final dao = await ToolAuditDao.create(storage);

    await dao.record(const ToolAuditRecord(
      toolName: 'mcp__srv__echo',
      sourceType: 'mcp',
      sourceId: 'srv',
      sourceName: 'Srv',
      trusted: false,
      readOnly: false,
      approved: true,
      success: true,
      argCount: 1,
      argsPreview: '{"text":"hi"}',
      resultPreview: 'pong:hi',
      createdAt: 10,
    ));
    await dao.record(const ToolAuditRecord(
      toolName: 'save_favorite',
      sourceType: 'builtin',
      sourceId: 'local',
      sourceName: '内置工具',
      trusted: true,
      readOnly: false,
      approved: false,
      success: false,
      argCount: 2,
      resultPreview: '用户拒绝',
      createdAt: 20,
    ));

    final rows = await dao.latest();
    expect(rows.map((e) => e.toolName), ['save_favorite', 'mcp__srv__echo']);
    expect(rows.first.approved, isFalse);
    expect(rows.last.argsPreview, contains('hi'));
    await storage.db.close();
  });
}
