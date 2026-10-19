import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_library.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';

class KnowledgeFileImportItem {
  final String path;
  final String name;
  final String title;
  final bool imported;
  final String? reason;

  const KnowledgeFileImportItem({
    required this.path,
    required this.name,
    required this.title,
    required this.imported,
    this.reason,
  });
}

class KnowledgeFileImportResult {
  final List<KnowledgeFileImportItem> items;

  const KnowledgeFileImportResult(this.items);

  int get total => items.length;
  int get imported => items.where((item) => item.imported).length;
  int get skipped => total - imported;
  List<KnowledgeFileImportItem> get failedItems =>
      items.where((item) => !item.imported).toList(growable: false);

  String get message {
    if (total == 0) return '未选择文件';
    if (imported == 0) return '未导入文档，$skipped 个文件未提取到文字';
    if (skipped == 0) return '已导入 $imported 个文档';
    return '已导入 $imported 个文档，$skipped 个文件跳过';
  }

  String get detailMessage {
    if (failedItems.isEmpty) return '';
    return failedItems
        .map((item) => '${item.name.isEmpty ? item.title : item.name}：'
            '${item.reason ?? '导入失败'}')
        .join('\n');
  }
}

class KnowledgeFileImporter {
  final KnowledgeDao dao;
  final String account;
  final bool Function()? isCurrent;

  const KnowledgeFileImporter(this.dao,
      {this.account = 'guest', this.isCurrent});

  Future<KnowledgeFileImportResult> importPaths(List<String> paths,
      {AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    final items = <KnowledgeFileImportItem>[];
    for (final path in paths) {
      if (isCurrent?.call() == false) break;
      final item = await _importPath(path, limits);
      items.add(item);
    }
    return KnowledgeFileImportResult(items);
  }

  Future<KnowledgeFileImportItem> _importPath(
      String path, AttachmentProcessingLimits limits) async {
    final name = _basename(path);
    final title = _titleOf(name);
    if (path.trim().isEmpty) {
      return KnowledgeFileImportItem(
        path: path,
        name: name,
        title: title,
        imported: false,
        reason: '路径为空',
      );
    }

    try {
      await FileProcessor.validateKnowledgeImportFile(path, limits: limits);
      final ext = _extOf(name);
      final isImage = OcrService.imageExtensions.contains(ext);
      String? text;
      if (isImage) {
        if (!OcrService.isSupported) {
          return KnowledgeFileImportItem(
            path: path,
            name: name,
            title: title,
            imported: false,
            reason: '当前平台不支持 OCR',
          );
        }
        text = await OcrService.recognizeImageFile(path);
      } else {
        text = await FileProcessor.extractTextForImport(path, limits: limits);
        if (ext == 'pdf' &&
            OcrService.isSupported &&
            OcrService.pdfNeedsOcr(text)) {
          text = await OcrService.recognizePdf(path);
        }
      }

      if (text == null || text.trim().isEmpty) {
        return KnowledgeFileImportItem(
          path: path,
          name: name,
          title: title,
          imported: false,
          reason: '未提取到文字',
        );
      }
      if (isCurrent?.call() == false) throw StateError('账号或页面已变化，停止导入');
      final library =
          await KnowledgeLibrary.create(dao.storage, account: account);
      if (isCurrent?.call() == false) throw StateError('账号或页面已变化，停止导入');
      int? docId;
      if (ext == 'pdf') {
        final bytes = await File(path).readAsBytes();
        final pdf = PdfDocument(inputBytes: bytes);
        List<String> pages;
        try {
          if (pdf.pages.count > FileProcessor.maxPdfPages) {
            throw const FormatException('PDF页数超过当前导入上限，请拆分后导入');
          }
          final extractor = PdfTextExtractor(pdf);
          pages = [
            for (var i = 0; i < pdf.pages.count; i++)
              extractor.extractText(startPageIndex: i, endPageIndex: i)
          ];
        } finally {
          pdf.dispose();
        }
        if (pages.join().trim().isEmpty) {
          // OCR旧接口未返回逐页位置，不能伪造页码。
          if (isCurrent?.call() == false) throw StateError('账号或页面已变化，停止导入');
          docId = await library.add(title, [text]);
        } else {
          if (pages.fold<int>(0, (n, p) => n + p.length) >
              limits.normalized.maxTextChars) {
            throw const FormatException('PDF文字超过导入预算，请拆分或提高限额');
          }
          if (isCurrent?.call() == false) throw StateError('账号或页面已变化，停止导入');
          docId = await library.add(title, pages, pdf: true);
        }
        if (docId != null) {
          try {
            await library.preservePdf(docId, bytes);
          } catch (_) {
            await dao.deleteDocument(docId);
            rethrow;
          }
        }
      } else {
        docId = await library.add(title, [text]);
      }
      return KnowledgeFileImportItem(
        path: path,
        name: name,
        title: title,
        imported: docId != null,
        reason: docId == null ? '导入失败（无可用内容）' : null,
      );
    } catch (e) {
      return KnowledgeFileImportItem(
        path: path,
        name: name,
        title: title,
        imported: false,
        reason: '识别失败：$e',
      );
    }
  }

  static String _basename(String path) {
    final parts =
        path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  static String _extOf(String name) =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';

  static String _titleOf(String name) {
    if (name.contains('.')) return name.substring(0, name.lastIndexOf('.'));
    return name.trim().isEmpty ? '未命名文档' : name;
  }
}
