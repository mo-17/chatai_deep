@TestOn('browser')
library;

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/ocr_task_dao.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('真实 WASM SQLite / IndexedDB 恢复原件 BLOB、校对文字和中断状态', () async {
    final base = Uri.parse(const String.fromEnvironment('OCR_TEST_BASE',
        defaultValue: 'http://127.0.0.1:48353/'));
    final factory = createDatabaseFactoryFfiWeb(
        noWebWorker: true,
        options: SqfliteFfiWebOptions(
            sqlite3WasmUri: base.resolve('sqlite3.wasm'),
            indexedDbName: 'ocr-workbench-test'));
    final path = 'ocr-${DateTime.now().microsecondsSinceEpoch}.db';
    var db = await factory.openDatabase(path);
    void verify() {}
    try {
      var dao = await OcrTaskDao.create(HiDBManager.test(db));
      final input = Uint8List.fromList([0, 255, 128, 42]);
      final id = await dao.add(
          name: '扫描.png',
          origin: 'https://example.test',
          pdf: false,
          bytes: input,
          verify: verify);
      input[0] = 9;
      await dao.transition(id, {OcrTaskState.waiting}, OcrTaskState.review,
          verify: verify,
          result: PdfOcrResult(totalPages: 1, pages: [
            '中文校对'
          ], details: [
            OcrPageDetail(page: 1, width: 100, height: 100, lines: [
              OcrLine(text: '原文', confidence: .6, box: [
                [1, 2],
                [20, 2],
                [20, 10],
                [1, 10]
              ])
            ])
          ]));
      final queued = await dao.add(
          name: '等待.pdf',
          origin: 'https://example.test',
          pdf: true,
          bytes: Uint8List.fromList([1, 2]),
          verify: verify);
      await dao.transition(queued, {OcrTaskState.waiting}, OcrTaskState.queued,
          verify: verify);
      await db.close();
      db = await factory.openDatabase(path);
      dao = await OcrTaskDao.create(HiDBManager.test(db));
      final restored = (await dao.load(id))!;
      expect(restored.bytes, [0, 255, 128, 42]);
      expect(restored.result!.text, '中文校对');
      expect(restored.result!.details.single.lines.single.confidence, .6);
      await dao.recover(verify);
      expect((await dao.load(queued))!.task.state, OcrTaskState.interrupted);
      expect((await dao.load(id))!.task.state, OcrTaskState.review);
    } finally {
      await db.close();
      await factory.deleteDatabase(path);
    }
  });
}
