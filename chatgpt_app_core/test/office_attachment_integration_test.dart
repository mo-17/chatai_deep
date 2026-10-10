import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/creative_file_transfer_gateway.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/chat/application/retry_attachment_restorer.dart';
import 'package:chatgpt_app_core/chat/application/story_room_attachments.dart';
import 'package:chatgpt_app_core/chat/application/workspace_attachment_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/pages/agent_workspace_page.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 这些小型文件使用真实 OOXML 容器，经过解析器和持久化管线；没有模拟提取正文。
void main() {
  late Directory root;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('office_attachment_flow_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
  });

  Future<File> office(String extension, String text,
          {String stem = 'source'}) =>
      File('${root.path}/$stem.$extension')
          .writeAsBytes(_officeBytes(extension, text));

  Future<HiDBManager> manager() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    return HiDBManager.test(db);
  }

  test('统一附件选择白名单包含四种 Office 格式且保留原有文本和 PDF', () {
    expect(FileProcessor.pickerExtensions,
        containsAll(['doc', 'docx', 'xls', 'xlsx', 'txt', 'md', 'csv', 'pdf']));
  });

  for (final extension in ['docx', 'xlsx']) {
    final mime = _officeMime(extension);

    test('$extension 普通附件提取正文、保留 MIME 与托管原始字节并可落库恢复', () async {
      final source = await office(extension, '普通对话正文 & OFFICE_BODY_END');
      final bytes = await source.readAsBytes();
      final processed = await FileProcessor.process(
          [source.path], const ModelCapabilities(pdf: true));
      expect(processed.nativeFiles, isEmpty);
      expect(processed.hasWarnings, isFalse);
      expect(processed.extraText, contains('普通对话正文 & OFFICE_BODY_END'));
      expect(processed.extraText, contains('source.$extension'));
      final metadata = processed.metas.single;
      expect(metadata.mime, mime);
      expect(metadata.size, bytes.length);
      expect(metadata.workspaceFileId, isNull);
      expect(metadata.extractedText, processed.extraText);
      expect(
          await ManagedAttachmentStore.readManagedBytes(metadata.path), bytes);
      final restored = FileMetadata.fromJson(
          jsonDecode(jsonEncode(metadata.toJson())) as Map<String, dynamic>);
      expect(restored.toJson(), metadata.toJson());
      expect(restored.extractedText, contains('OFFICE_BODY_END'));
    });

    test('$extension 字符上限只截断普通发送，诊断告知正文尾部未提供', () async {
      final source =
          await office(extension, 'OFFICE_START${'文' * 4096}OFFICE_TAIL');
      final processed = await FileProcessor.process(
          [source.path], const ModelCapabilities.none(),
          limits: const AttachmentProcessingLimits(maxTextChars: 1024));
      expect(processed.extraText, contains('OFFICE_START'));
      expect(processed.extraText, isNot(contains('OFFICE_TAIL')));
      expect(processed.extraText, contains('已截断'));
      expect(processed.metas.single.mime, mime);
      expect(processed.diagnostics.map((item) => item.kind),
          contains(FileProcessingDiagnosticKind.truncated));
      expect(
          processed.diagnostics
              .every((item) => item.filename == 'source.$extension'),
          isTrue);
    });

    test('$extension 知识库抽取返回纯正文，支持同一份真实附件', () async {
      final source = await office(extension, 'KNOWLEDGE_OFFICE_SENTINEL');
      final text = await FileProcessor.extractTextForImport(source.path);
      expect(text, contains('KNOWLEDGE_OFFICE_SENTINEL'));
      expect(text, isNot(contains('[附件「')));
      expect(text, isNot(contains('内容结束]')));
    });

    test('$extension 知识库预检按文本字节限额拒绝，不误用图片限额', () async {
      final source = await File('${root.path}/too-large.$extension')
          .writeAsBytes(Uint8List(1024 * 1024 + 1));
      await expectLater(
          FileProcessor.validateKnowledgeImportFile(source.path,
              limits: const AttachmentProcessingLimits(
                  maxTextFileBytes: 1024 * 1024)),
          throwsA(isA<FormatException>()
              .having((error) => error.message, 'message', contains('1 MiB'))));
    });

    test('$extension 任务模式保留上限外全文，清单仅定位，删除源文件仍能按需读', () async {
      final workspace =
          await AgentWorkspaceService.create(await manager(), cid: 71);
      const tail = 'WORKSPACE_ONLY_TAIL';
      final source =
          await office(extension, 'WORKSPACE_HEAD${'文' * 4096}$tail');
      final bytes = await source.readAsBytes();
      final processed = await WorkspaceAttachmentProcessor(workspace).process(
          [source.path],
          limits: const AttachmentProcessingLimits(maxTextChars: 1024));
      expect(processed.nativeFiles, isEmpty);
      expect(processed.hasWarnings, isFalse);
      expect(processed.extraText, contains('正文尚未读取'));
      expect(processed.extraText, isNot(contains(tail)));
      expect(processed.extraText, isNot(contains('WORKSPACE_HEAD')));
      final metadata = FileMetadata.fromJson(processed.metas.single.toJson());
      expect(metadata.mime, mime);
      expect(metadata.size, bytes.length);
      expect(
          await ManagedAttachmentStore.readManagedBytes(metadata.path), bytes);
      final id = metadata.workspaceFileId!;
      final revision = await workspace.getRevision(id);
      expect(revision.content, contains(tail));
      expect(revision.content, isNot(contains('已截断')));
      expect(await workspace.manifest(), isNot(contains(tail)));
      await source.delete();
      final read = await workspace.readFile(id, tail: true, maxChars: 80);
      expect(read['content'], contains(tail));
      expect((read['content'] as String).length, lessThanOrEqualTo(80));
      expect(read['workspaceReadVersion'], 1);
      expect(read['sourceCitation'], isA<Map<String, dynamic>>());
    });

    test('$extension bytes-only 工作区保留只读输入快照，重导入不改写旧引用', () async {
      final workspace =
          await AgentWorkspaceService.create(await manager(), cid: 81);
      final first = await workspace.importBytes(
          _officeBytes(extension, 'VERSION_ONE_SOURCE'),
          name: 'cloud.$extension',
          sourceKey: 'files-provider:cloud',
          maxBytes: 1024 * 1024);
      expect(first.revision, 1);
      final read = await workspace.readFile(first.id);
      final citation = LocalSourceCitation.tryFromJson(
          read['sourceCitation'] as Map<String, dynamic>)!;
      expect(read['content'], contains('VERSION_ONE_SOURCE'));
      final second = await workspace.importBytes(
          _officeBytes(extension, 'VERSION_TWO_SOURCE'),
          name: 'cloud.$extension',
          sourceKey: 'files-provider:cloud',
          maxBytes: 1024 * 1024);
      // 输入文件按来源 + 正文哈希去重，修改后的源文件成为新的只读快照。
      expect(second.id, isNot(first.id));
      expect(second.revision, 1);
      expect(await workspace.listFiles(), hasLength(2));
      expect(await workspace.revisions(first.id), hasLength(1));
      expect((await workspace.getRevision(first.id, revision: 1)).content,
          contains('VERSION_ONE_SOURCE'));
      expect((await workspace.readFile(second.id))['content'],
          contains('VERSION_TWO_SOURCE'));
      final oldSource = await workspace.resolveCitation(citation);
      expect(oldSource.content, contains('VERSION_ONE_SOURCE'));
      expect(oldSource.currentRevision, 1);
      final duplicate = await workspace.importBytes(
          _officeBytes(extension, 'VERSION_TWO_SOURCE'),
          name: 'cloud.$extension',
          sourceKey: 'files-provider:cloud',
          maxBytes: 1024 * 1024);
      expect(duplicate.id, second.id);
      expect(duplicate.revision, 1);
      expect(await workspace.listFiles(), hasLength(2));
      expect(await workspace.revisions(second.id), hasLength(1));
    });

    test('$extension 旧对话历史和重试复用已保存正文，不依赖源文件或当前限额', () async {
      final source =
          await office(extension, 'SAVED_HEAD${'旧' * 4096}SAVED_TAIL');
      final processed = await FileProcessor.process(
          [source.path], const ModelCapabilities.none());
      final savedFiles = processed.metas
          .map((file) => FileMetadata.fromJson(file.toJson()))
          .toList();
      final savedText = processed.extraText;
      await source.delete();
      for (final file in savedFiles) {
        await File(file.path!).delete();
      }
      const restorer = RetryAttachmentRestorer();
      for (final persisted in [
        ChatAttachments(extraText: savedText),
        const ChatAttachments(),
      ]) {
        final restored = await restorer.restore(
            persisted: persisted,
            files: savedFiles,
            capabilities: const ModelCapabilities.none(),
            limits: const AttachmentProcessingLimits(maxTextChars: 1024));
        expect(restored.attachments.extraText, savedText);
        expect(restored.attachments.extraText, contains('SAVED_TAIL'));
        expect(restored.hasWarnings, isFalse);
      }
      final user = MessageModel(
          ownerType: OwnerType.sender, content: '请根据这个文件回答', createdAt: 31);
      final history = CompletionDao.buildHistory([user], const {},
          fileHistory: {user.createdAt: savedText});
      expect(history.single['role'], 'user');
      expect(history.single['content'], contains(user.content));
      expect(history.single['content'], contains('SAVED_TAIL'));
      expect(
          RegExp('SAVED_TAIL').allMatches(history.single['content'] as String),
          hasLength(1));
    });

    testWidgets('$extension 工作区页面导入无路径的云端附件，保存中文正文', (tester) async {
      late AgentWorkspaceService workspace;
      late AgentWorkspaceTools tools;
      await tester.runAsync(() async {
        final storage = await manager();
        workspace = await AgentWorkspaceService.create(storage, cid: 101);
        tools = await AgentWorkspaceTools.create(storage,
            cid: 101, workspace: workspace);
      });
      const body = '云端中文正文：海边的角色与季度收入。';
      final bytes = _officeBytes(extension, body);
      List<String>? selectedExtensions;
      var pickerCalls = 0;
      final transfer = CreativeFileTransferGateway(pickFiles: (
          {dialogTitle,
          initialDirectory,
          allowedExtensions,
          required withData}) async {
        expect(dialogTitle, '导入工作区文件');
        expect(withData, isTrue);
        selectedExtensions = allowedExtensions;
        pickerCalls++;
        // Files Provider 只给 bytes，没有可读平台 path。
        return FilePickerResult([
          PlatformFile(
              name: 'cloud.$extension', size: bytes.length, bytes: bytes),
        ]);
      }, readBytes: (_) async {
        throw StateError('bytes-only 附件不应回退读取路径');
      });
      await tester.pumpWidget(MaterialApp(
          home: AgentWorkspacePage(
              workspace: workspace, tools: tools, transfer: transfer)));
      await _settleWorkspace(tester);
      await tester.tap(find.byTooltip('导入文件'));
      await _settleWorkspace(tester);
      expect(pickerCalls, 1);
      expect(selectedExtensions, containsAll(['doc', 'docx', 'xls', 'xlsx']));
      expect(find.text('cloud.$extension'), findsOneWidget);
      expect(find.text('文件已导入，启用对话任务模式后可按需读取'), findsOneWidget);
      await tester.runAsync(() async {
        final file = (await workspace.listFiles()).single;
        expect(file.name, 'cloud.$extension');
        expect(file.sizeBytes, bytes.length);
        expect((await workspace.getRevision(file.id)).content, contains(body));
        expect((await workspace.readFile(file.id))['content'], contains(body));
      });
      expect(tester.takeException(), isNull);
    });
  }

  test('损坏 Office 提示解析失败，同批普通文本仍进入请求', () async {
    final broken = await File('${root.path}/broken.docx')
        .writeAsBytes(utf8.encode('not an Office container'));
    final brokenSheet =
        await File('${root.path}/broken.xlsx').writeAsBytes([0, 1, 2, 3]);
    final text = await File('${root.path}/valid.md')
        .writeAsString('VALID_TEXT_IN_SAME_BATCH');
    final processed = await FileProcessor.process(
        [broken.path, text.path, brokenSheet.path],
        const ModelCapabilities.none());
    expect(processed.metas.map((file) => file.name),
        ['broken.docx', 'valid.md', 'broken.xlsx']);
    expect(processed.extraText, contains('VALID_TEXT_IN_SAME_BATCH'));
    expect(processed.extraText, isNot(contains('not an Office container')));
    expect(processed.diagnostics.map((item) => item.filename),
        containsAll(['broken.docx', 'broken.xlsx']));
    expect(
        processed.diagnostics
            .every((item) => item.kind == FileProcessingDiagnosticKind.failed),
        isTrue);
    await expectLater(FileProcessor.extractTextForImport(broken.path),
        throwsA(isA<FormatException>()));
  });

  test('Excel 无缓存公式提醒传到普通发送、任务诊断和 bytes-only 导入', () async {
    final bytes = _xlsx('FORMULA_INPUT_CONTEXT', uncachedFormula: true);
    final source = await File('${root.path}/formula.xlsx').writeAsBytes(bytes);
    final ordinary = await FileProcessor.process(
        [source.path], const ModelCapabilities.none());
    expect(ordinary.extraText, contains('FORMULA_INPUT_CONTEXT'));
    expect(ordinary.extraText, contains('公式未计算'));
    expect(
        ordinary.diagnostics.any((item) =>
            item.kind == FileProcessingDiagnosticKind.textFallback &&
            item.message.contains('公式')),
        isTrue);

    final workspace =
        await AgentWorkspaceService.create(await manager(), cid: 91);
    final task = await WorkspaceAttachmentProcessor(workspace)
        .process([source.path], limits: const AttachmentProcessingLimits());
    expect(
        task.diagnostics.any((item) =>
            item.filename == 'formula.xlsx' &&
            item.kind == FileProcessingDiagnosticKind.textFallback &&
            item.message.contains('公式')),
        isTrue);
    expect(
        (await workspace
            .readFile(task.metas.single.workspaceFileId!))['content'],
        contains('公式未计算'));
    final warnings = <String>[];
    await workspace.importBytes(bytes,
        name: 'cloud-formula.xlsx',
        maxBytes: 1024 * 1024,
        onWarnings: warnings.addAll);
    expect(warnings.any((warning) => warning.contains('公式')), isTrue);
  });

  test('知识库混合导入 Office 与普通文本，坏文件失败且不会存成提示正文', () async {
    final doc = await office('docx', 'WORD_KNOWLEDGE_BODY', stem: 'word');
    final sheet = await office('xlsx', 'EXCEL_KNOWLEDGE_BODY', stem: 'excel');
    final broken = await File('${root.path}/broken.docx').writeAsBytes([0, 1]);
    final note = await File('${root.path}/note.txt')
        .writeAsString('PLAIN_KNOWLEDGE_BODY');
    final dao = await KnowledgeDao.create(await manager());
    final result = await KnowledgeFileImporter(dao)
        .importPaths([doc.path, broken.path, sheet.path, note.path]);
    expect(result.imported, 3);
    expect(result.skipped, 1);
    expect(result.failedItems.single.name, 'broken.docx');
    expect(result.failedItems.single.reason, contains('识别失败'));
    final docs = await dao.getDocuments();
    expect(
        docs.map((doc) => doc.title), containsAll(['word', 'excel', 'note']));
    expect(docs, hasLength(3));
    final rows = await dao.storage.db.query('tb_kb_chunk');
    final content = rows.map((row) => row['content'] as String).join('\n');
    expect(content, contains('WORD_KNOWLEDGE_BODY'));
    expect(content, contains('EXCEL_KNOWLEDGE_BODY'));
    expect(content, contains('PLAIN_KNOWLEDGE_BODY'));
    expect(content, isNot(contains('内容未提供')));
    expect(content, isNot(contains('识别失败')));
  });

  test('旧 FileMetadata 无工作区字段时仍逐字保留正文和纯文本历史', () async {
    final file = FileMetadata.fromJson({
      'name': 'old.docx',
      'path': '/missing/old.docx',
      'extractedText': '原来存好的附件正文\n旧数据尾部',
    });
    expect(file.workspaceFileId, isNull);
    expect(file.toJson().containsKey('workspaceFileId'), isFalse);
    final restored = await const RetryAttachmentRestorer().restore(
        persisted: const ChatAttachments(),
        files: [file],
        capabilities: const ModelCapabilities.none());
    expect(restored.attachments.extraText, file.extractedText);
    final plain = MessageModel(
        ownerType: OwnerType.sender, content: '无附件的旧对话', createdAt: 51);
    expect(CompletionDao.buildHistory([plain], const {}).single['content'],
        plain.content);
  });

  test('故事房间接入真实 Office 正文，重试继续沿用存好的原提问', () async {
    final doc = await office('docx', 'STORY_WORD_CONTEXT', stem: 'story');
    final sheet = await office('xlsx', 'STORY_EXCEL_CONTEXT', stem: 'sheet');
    final first = await StoryRoomAttachmentService.prepare(
        imagePaths: const [],
        filePaths: [doc.path, sheet.path],
        capabilities: const ModelCapabilities.none());
    expect(first.attachments.extraText, contains('STORY_WORD_CONTEXT'));
    expect(first.attachments.extraText, contains('STORY_EXCEL_CONTEXT'));
    await doc.writeAsBytes(_officeBytes('docx', 'CHANGED_STORY_SOURCE'));
    await sheet.delete();
    final retry = await StoryRoomAttachmentService.prepare(
        imagePaths: const [],
        filePaths: first.filePaths,
        capabilities: const ModelCapabilities.none(),
        fallbackContext: first.attachmentContext,
        reuseExtractedContext: true,
        limits: const AttachmentProcessingLimits(maxTextChars: 1024));
    expect(retry.attachmentContext, first.attachmentContext);
    expect(retry.attachments.extraText, first.attachments.extraText);
  });
}

Future<void> _settleWorkspace(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

String _officeMime(String extension) => extension == 'docx'
    ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

Uint8List _officeBytes(String extension, String text) =>
    extension == 'docx' ? _docx(text) : _xlsx(text);

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

Uint8List _zip(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

Uint8List _docx(String text) => _zip({
      '[Content_Types].xml': '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''',
      '_rels/.rels': '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''',
      'word/document.xml': '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t xml:space="preserve">${_xml(text)}</w:t></w:r></w:p>
<w:p><w:r><w:t>文档第二段</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>表格单元格</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:sectPr/></w:body></w:document>''',
    });

Uint8List _xlsx(String text, {bool uncachedFormula = false}) => _zip({
      '[Content_Types].xml': '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>''',
      '_rels/.rels': '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''',
      'xl/workbook.xml': '''<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="数据表" sheetId="1" r:id="rId1"/></sheets></workbook>''',
      'xl/_rels/workbook.xml.rels': '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>''',
      'xl/sharedStrings.xml': '''<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">
<si><t xml:space="preserve">${_xml(text)}</t></si></sst>''',
      'xl/worksheets/sheet1.xml': '''<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>
<c r="B1" t="inlineStr"><is><t>表格文本</t></is></c>
<c r="C1"><v>42</v></c></row>
${uncachedFormula ? '<row r="2"><c r="A2"><f>SUM(C1:C1)</f></c></row>' : ''}
</sheetData></worksheet>''',
    });
