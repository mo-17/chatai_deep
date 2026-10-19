import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_library.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_evidence.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_hybrid_search.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_repository.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_sync.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_sync_packets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  late HiDBManager db;
  late KnowledgeLibrary library;
  setUp(() async {
    db = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    library = await KnowledgeLibrary.create(db);
  });
  tearDown(() async => db.db.close());
  test('设备时钟回调时，资料连续修订仍使用严格递增的更新时间', () async {
    final id = (await library.add('时钟资料', ['用于验证更新时间。']))!;
    final future = DateTime.now().millisecondsSinceEpoch + 60000;
    await db.db.update('tb_kb_doc', {'updatedAt': future},
        where: 'id = ?', whereArgs: [id]);
    await library.organize((await library.list()).single,
        folder: '分类', tags: [], archived: false);
    final edited = (await library.list()).single;
    expect(edited.updatedAt, greaterThan(future));
    await library.revise(edited, '新的文档正文。');
    expect(
        (await library.list()).single.updatedAt, greaterThan(edited.updatedAt));
  });
  test('旧版修订表原子升级为内容摘要主键，不丢原始快照', () async {
    await library.add('升级资料', ['升级前的原始内容。']);
    final row = (await db.db.query('tb_kb_revision')).single;
    await db.db.execute('drop table tb_kb_revision');
    await db.db.execute(
        'create table tb_kb_revision(uid text,revision integer,payload text,primary key(uid,revision))');
    await db.db.insert(
        'tb_kb_revision', Map<String, Object?>.from(row)..remove('hash'));
    final migrated = await KnowledgeLibrary.create(db, account: 'test');
    expect(
        await migrated.versions((await migrated.list()).single), hasLength(1));
    expect((await db.db.query('tb_kb_revision')).single['hash'], isNotEmpty);
  });
  test('合成检索题库：12个中英同义词与无依据问题', () async {
    final data = jsonDecode(await File(
            '../chatgpt_app_core/test/fixtures/knowledge_retrieval_cases.json')
        .readAsString()) as Map;
    final sources = [
      for (final d in data['documents'] as List)
        KnowledgeEvidence(
            docId: d['id'],
            chunkId: d['id'],
            seq: 0,
            importedAt: 1,
            title: d['title'],
            content: d['content'])
    ];
    for (final c in data['cases'] as List) {
      final hits = KnowledgeHybridSearch.search(c['question'], sources);
      if (c['firstDocument'] == null) {
        expect(hits, isEmpty, reason: c['question']);
      } else {
        expect(hits, isNotEmpty, reason: c['question']);
        expect(hits.first.source.docId, c['firstDocument'],
            reason: c['question']);
      }
    }
  });
  test('超过512KiB的知识快照分片传输，校验后恢复且重复导出身份稳定', () async {
    await library.add('较大的政策资料',
        List.generate(12, (i) => '第$i页。${List.filled(6000, '资料正文。').join()}'));
    final wire = await KnowledgeSync.export(db, 'test');
    expect(wire.any((c) => c.entity == KnowledgeSyncPackets.packet), isTrue);
    expect(
        wire.every(
            (c) => utf8.encode(jsonEncode(c.payload)).length < 512 * 1024),
        isTrue);
    final target = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    try {
      final other = await KnowledgeLibrary.create(target, account: 'test');
      await other.add('另一篇资料', ['必须保留在目标设备。']);
      await KnowledgeSync.apply(target, 'test', wire);
      expect((await other.list()).where((d) => d.title == '较大的政策资料'),
          hasLength(1));
      final again = await KnowledgeSync.export(target, 'test');
      for (final source
          in wire.where((c) => c.entity == KnowledgeSyncPackets.pointer)) {
        expect(
            again
                .singleWhere(
                    (c) => c.entity == source.entity && c.id == source.id)
                .payload,
            source.payload);
      }
    } finally {
      await target.db.close();
    }
  });
  test('跨设备本地ID碰撞、修订分叉保留和删除不复活', () async {
    await library.add('政策', ['可在7天内申请退款。']);
    final target = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    try {
      final other = await KnowledgeLibrary.create(target, account: 'test');
      await other.add('本机独有', ['本机资料必须保留。']);
      final before = await KnowledgeSync.export(db, 'test');
      await KnowledgeSync.apply(target, 'test', before);
      expect(await other.list(), hasLength(2));
      final copied = (await other.list()).firstWhere((d) => d.title == '政策');
      await library.dao
          .setProjectDocIds(7, [(await library.list()).single.id!]);
      await KnowledgeSync.apply(
          target, 'test', await KnowledgeSync.export(db, 'test'));
      expect(await other.dao.getProjectDocIds(7), [copied.id]);
      expect(copied.id, isNot((await library.list()).single.id));
      await library.organize((await library.list()).single,
          folder: '设备A', tags: [], archived: false);
      await other.organize(copied, folder: '设备B', tags: [], archived: false);
      final merge = await KnowledgeSync.apply(
          target, 'test', await KnowledgeSync.export(db, 'test'));
      expect(merge.conflicts, isNotEmpty);
      expect((await other.list()).firstWhere((d) => d.title == '政策').folder,
          '设备B');
      expect(await target.db.query('tb_knowledge_conflict'), isNotEmpty);
      final conflict = (await target.db.query('tb_knowledge_conflict')).first;
      await other.resolveConflict(conflict['id'] as int,
          incoming: true, expectedHead: (await other.headHash(copied.uid))!);
      expect((await other.list()).firstWhere((d) => d.uid == copied.uid).folder,
          '设备A');
      expect(
          await other.versions(
              (await other.list()).firstWhere((d) => d.uid == copied.uid)),
          hasLength(4));
      await library.dao.deleteDocument((await library.list()).single.id!);
      await KnowledgeSync.apply(
          target, 'test', await KnowledgeSync.export(db, 'test'));
      await KnowledgeSync.apply(target, 'test', before);
      expect((await other.list()).map((d) => d.title), ['本机独有']);
    } finally {
      await target.db.close();
    }
  });
  test('旧的数字行号删除不能删除已经有UUID的另一篇文档', () async {
    final id = (await library.add('本机资料', ['应当保留的文档正文。']))!;
    final sync = LocalSyncService(db, accountHash: 'test');
    final result = await sync.applyRemoteChanges([
      SyncChange(
          entity: 'knowledge_doc',
          id: '$id',
          op: SyncOp.delete,
          updatedAt: DateTime.now().millisecondsSinceEpoch + 1000)
    ]);
    expect(result.conflicts, isNotEmpty);
    expect(await library.list(), hasLength(1));
    await library.dao.deleteDocument(id);
    expect(
        (await sync.exportChanges()).where((c) => c.entity == 'knowledge_doc'),
        isEmpty);
  });
  test('全量ZIP与仅知识库恢复包含引用历史及修订，重复合并不复制文档', () async {
    await library.add('政策', ['可在7天内申请退款。']);
    final repo = await KnowledgeRepository.create(db);
    final source =
        (await repo.retrieve('退款', {(await library.list()).single.id!})).single;
    final answer = KnowledgeAnswer(
        question: '退款期限？',
        model: 'test',
        createdAt: 1,
        status: KnowledgeAnswerStatus.cited,
        sources: [
          source
        ],
        claims: [
          KnowledgeClaim('七天内申请。', [KnowledgeQuote(source, '可在7天内申请退款。')])
        ]);
    await repo.save(answer, {source.docId}, () => true);
    final bytes = await BackupService(db)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'test');
    final target = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    try {
      await BackupService(target).importArchive(bytes,
          accountHash: 'test', mode: BackupImportMode.knowledgeBaseOnly);
      final restored = await KnowledgeRepository.create(target);
      expect(
          (await restored.history()).single.claims.single.evidence.single.quote,
          '可在7天内申请退款。');
      expect(await target.db.query('tb_kb_revision'), hasLength(1));
      await BackupService(target).importArchive(bytes,
          accountHash: 'test', mode: BackupImportMode.mergeAppend);
      expect(await restored.documents(), hasLength(1));
      await restored.clearHistory();
      expect((await target.db.query('tb_knowledge_answer')).single['payload'],
          isNot(contains('7天内')));
      await BackupService(target).importArchive(bytes,
          accountHash: 'test', mode: BackupImportMode.mergeAppend);
      expect(await restored.history(), isEmpty);
      expect(await target.db.query('tb_knowledge_conflict'), isEmpty);
    } finally {
      await target.db.close();
    }
  });
  test('并发导入相同正文只保留一个文档', () async {
    final result = await Future.wait([
      for (var i = 0; i < 2; i++)
        library
            .add('政策$i', ['可在7天内申请退款。'])
            .then<Object?>((v) => v)
            .catchError((Object e) => e)
    ]);
    expect(result.whereType<int>(), hasLength(1));
    expect(result.whereType<KnowledgeScopeException>(), hasLength(1));
    expect(await library.list(), hasLength(1));
  });
  test('文件夹标签过滤、失效排除、版本CAS和历史原文', () async {
    await library.add('政策', ['可在7天内申请退款。']);
    final v1 = (await library.list()).single;
    await library.organize(v1,
        folder: '客服', tags: [' 售后 ', '售后'], archived: false);
    final v2 =
        (await library.list(folder: '客服', tag: '售后', query: '政策')).single;
    expect(v2.revision, 2);
    expect(v2.tags, ['售后']);
    await expectLater(library.revise(v1, '旧界面不能覆盖新版本'),
        throwsA(isA<KnowledgeScopeException>()));
    await library.revise(v2, '可在14天内申请退款。');
    final v3 = (await library.list()).single;
    expect(v3.revision, 3);
    final history = await library.versions(v3);
    expect(history, hasLength(3));
    expect(history.last['chunks'][0]['content'], contains('7天'));
    await library.organize(v3, folder: '客服', tags: ['售后'], archived: true);
    expect(await library.list(), isEmpty);
    final repo = await KnowledgeRepository.create(db);
    expect(await repo.documents(), isEmpty);
    await expectLater(
        repo.retrieve('退款', {v3.id!}), throwsA(isA<KnowledgeScopeException>()));
  });
  test('真实页码、同义词命中和跨本地ID快照校验', () async {
    final id = (await library.add('退款政策', ['目录', '可在7天内申请退款。'], pdf: true))!;
    final repo = await KnowledgeRepository.create(db);
    final source = (await repo.retrieve('退费的期限', {id})).first;
    expect(source.pageNumber, 2);
    expect(source.revision, 1);
    final remapped = KnowledgeEvidence.fromJson(
        {...source.toJson(), 'docId': 999, 'chunkId': 1000});
    expect(remapped.digest, source.digest);
    expect(await repo.sourceUnchanged(remapped), isTrue);
    await library.revise((await library.list()).single, '30天内申请退费。');
    expect(await repo.sourceUnchanged(source), isFalse);
  });
  test('排序只接纳正文匹配，分数有穷且不作为置信度', () {
    const good = KnowledgeEvidence(
        docId: 1,
        chunkId: 1,
        seq: 0,
        importedAt: 1,
        title: '政策',
        content: '退费必须在7天内提出。');
    const bad = KnowledgeEvidence(
        docId: 2,
        chunkId: 2,
        seq: 0,
        importedAt: 1,
        title: '退款',
        content: '苹果树在春天开花。');
    final hits = KnowledgeHybridSearch.search('退款期限', [bad, good]);
    expect(hits.map((h) => h.source), [good]);
    expect(hits.single.rankScore.isFinite, isTrue);
  });
  test('Word/PDF保留逐字引文、页码版本和SHA且XML正确转义', () async {
    const source = KnowledgeEvidence(
        docId: 1,
        chunkId: 1,
        seq: 0,
        importedAt: 1,
        uid: 'doc',
        revision: 3,
        pageNumber: 2,
        title: '政策 & <规范>',
        content: '可在7天内申请退款。');
    final answer = KnowledgeAnswer(
        question: '退款期限？',
        model: 'test',
        createdAt: 1,
        status: KnowledgeAnswerStatus.cited,
        claims: [
          KnowledgeClaim('七天内申请。', [const KnowledgeQuote(source, '可在7天内申请退款。')])
        ],
        sources: [
          source
        ]);
    final report = KnowledgeReport(
        title: '测试报告', kind: KnowledgeReportKind.report, answers: [answer]);
    final zip = ZipDecoder().decodeBytes(report.docx());
    final xml = XmlDocument.parse(
        utf8.decode(zip.findFile('word/document.xml')!.content));
    expect(xml.innerText, contains(source.title));
    expect(xml.innerText, contains(source.digest));
    expect(xml.innerText, contains('第 2 页'));
    expect(xml.innerText, contains('v3'));
    final pdf = PdfDocument(inputBytes: await report.pdf());
    try {
      final text = PdfTextExtractor(pdf).extractText();
      expect(text, contains('可在7天内申请退款。'));
      expect(text.replaceAll(RegExp(r'\s'), ' ').replaceAll(' ', ''),
          contains(source.digest));
    } finally {
      pdf.dispose();
    }
    final comparison = KnowledgeReport(
        title: '观点对比', kind: KnowledgeReportKind.comparison, answers: [answer]);
    final comparedZip = ZipDecoder().decodeBytes(comparison.docx());
    final comparedXml = XmlDocument.parse(
        utf8.decode(comparedZip.findFile('word/document.xml')!.content));
    expect(comparedXml.findAllElements('w:tbl'), hasLength(1));
    final comparedPdf = PdfDocument(inputBytes: await comparison.pdf());
    try {
      expect(
          PdfTextExtractor(comparedPdf).extractText(), contains('可在7天内申请退款。'));
    } finally {
      comparedPdf.dispose();
    }
    expect(
        () => KnowledgeReport(
                title: 'x',
                kind: KnowledgeReportKind.report,
                answers: [
                  KnowledgeAnswer(
                      question: '?',
                      model: '',
                      createdAt: 1,
                      status: KnowledgeAnswerStatus.rejected)
                ]),
        throwsA(isA<KnowledgeScopeException>()));
  });
}
