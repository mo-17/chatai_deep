import 'dart:io';
import 'dart:typed_data';
import 'pdf_ocr_result.dart';
import 'import_operation.dart';
import 'knowledge_import_error.dart';
export 'import_operation.dart';
export 'knowledge_import_error.dart';
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
  final KnowledgeImportErrorKind? errorKind;

  const KnowledgeFileImportItem({
    required this.path,
    required this.name,
    required this.title,
    required this.imported,
    this.reason,
    this.errorKind,
  });
}

class KnowledgeFileImportResult {
  final List<KnowledgeFileImportItem> items;

  final bool cancelled;
  const KnowledgeFileImportResult(this.items, {this.cancelled = false});
  List<String> get retryPaths => failedItems.map((item) => item.path).toList();

  int get total => items.length;
  int get imported => items.where((item) => item.imported).length;
  int get skipped => total - imported;
  List<KnowledgeFileImportItem> get failedItems =>
      items.where((item) => !item.imported).toList(growable: false);

  String get message {
    if (cancelled) return '已取消，保留已导入的 $imported 个文档，$skipped 个文件未完成';
    if (total == 0) return '未选择文件';
    if (imported == 0) return '未导入文档，$skipped 个文件未完成';
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
  final Future<PdfOcrResult> Function(String path, List<int> pageNumbers)?
      pdfOcr;

  const KnowledgeFileImporter(this.dao,
      {this.account = 'guest', this.isCurrent, this.pdfOcr});

  Future<KnowledgeFileImportResult> importPaths(List<String> paths,
      {AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
      ImportCancellation? cancellation,
      void Function(KnowledgeImportProgress)? onProgress}) async {
    final operation = cancellation ?? ImportCancellation();
    final items = <KnowledgeFileImportItem>[];
    final unique = paths.toSet().toList();
    for (final path in unique) {
      if (isCurrent?.call() == false) operation.cancel();
      if (operation.isCancelled) {
        items.add(KnowledgeFileImportItem(
            path: path,
            name: _basename(path),
            title: _titleOf(_basename(path)),
            imported: false,
            reason: '已取消，未继续导入',
            errorKind: KnowledgeImportErrorKind.cancelled));
        continue;
      }
      void progress(String stage, [int? page, int? pages]) {
        if (isCurrent?.call() == false) operation.cancel();
        if (!operation.isCancelled) {
          onProgress?.call(KnowledgeImportProgress(
              completed: items.length,
              total: unique.length,
              filename: _basename(path),
              stage: stage,
              page: page,
              pages: pages));
        }
      }

      progress('正在导入');
      items.add(await _importPath(path, limits, operation, progress));
    }
    onProgress?.call(KnowledgeImportProgress(
        completed: items
            .where((i) => i.errorKind != KnowledgeImportErrorKind.cancelled)
            .length,
        total: unique.length,
        stage: operation.isCancelled ? '已取消' : '已完成'));
    return KnowledgeFileImportResult(items, cancelled: operation.isCancelled);
  }

  Future<KnowledgeFileImportItem> _importPath(
      String path,
      AttachmentProcessingLimits limits,
      ImportCancellation operation,
      void Function(String, [int?, int?]) progress) async {
    void check() {
      if (isCurrent?.call() == false) operation.cancel();
      operation.check();
    }

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
      check();
      await FileProcessor.validateKnowledgeImportFile(path, limits: limits);
      check();
      final ext = _extOf(name);
      final isImage = OcrService.imageExtensions.contains(ext);
      String? text;
      Uint8List? pdfBytes;
      List<String>? pdfPages;
      if (ext == 'pdf') {
        pdfBytes = await File(path).readAsBytes();
        check();
        final pdf = PdfDocument(inputBytes: pdfBytes);
        try {
          if (pdf.pages.count < 1 ||
              pdf.pages.count > FileProcessor.maxPdfPages) {
            throw const FormatException('PDF页数超过当前导入上限，请拆分后导入');
          }
          final extractor = PdfTextExtractor(pdf);
          pdfPages = [];
          for (var i = 0; i < pdf.pages.count; i++) {
            check();
            pdfPages
                .add(extractor.extractText(startPageIndex: i, endPageIndex: i));
            progress('正在提取文字', i + 1, pdf.pages.count);
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          pdf.dispose();
        }
        final missing = [
          for (var i = 0; i < pdfPages.length; i++)
            if (OcrService.pdfNeedsOcr(pdfPages[i])) i + 1
        ];
        if (missing.isNotEmpty && (pdfOcr != null || OcrService.isSupported)) {
          check();
          progress('正在识别扫描页');
          final recognized = pdfOcr != null
              ? await pdfOcr!(path, missing)
              : await OcrService.recognizePdfPages(path,
                  pageNumbers: missing,
                  cancellation: operation,
                  onProgress: (page, total) =>
                      progress('正在识别扫描页', page, total));
          check();
          if (recognized.totalPages != pdfPages.length ||
              recognized.pages.length != pdfPages.length) {
            throw const FormatException('OCR 页数与原 PDF 不一致，请重新导入');
          }
          for (final page in missing) {
            if (recognized.pages[page - 1].trim().isNotEmpty) {
              pdfPages[page - 1] = recognized.pages[page - 1];
            }
          }
        }
        if (pdfPages.fold<int>(0, (n, p) => n + p.length) >
            limits.normalized.maxTextChars) {
          throw const FormatException('PDF文字超过导入预算，请拆分或提高限额');
        }
        text = pdfPages.join('\n\n');
      } else if (isImage) {
        if (!OcrService.isSupported) {
          return KnowledgeFileImportItem(
            path: path,
            name: name,
            title: title,
            imported: false,
            reason: '当前平台不支持 OCR',
          );
        }
        progress('正在识别图片');
        check();
        text =
            await OcrService.recognizeImageFile(path, cancellation: operation);
      } else {
        text = await FileProcessor.extractTextForImport(path, limits: limits);
      }

      check();
      if (text == null || text.trim().isEmpty) {
        return KnowledgeFileImportItem(
          path: path,
          name: name,
          title: title,
          imported: false,
          reason: text == null ? '不支持此文件格式' : '未提取到文字',
          errorKind: text == null
              ? KnowledgeImportErrorKind.unsupported
              : KnowledgeImportErrorKind.noText,
        );
      }
      check();
      final library =
          await KnowledgeLibrary.create(dao.storage, account: account);
      check();
      progress('正在保存');
      check();
      int? docId;
      if (pdfPages != null && pdfBytes != null) {
        docId =
            await library.add(title, pdfPages, pdf: true, beforeCommit: check);
        if (docId != null) {
          try {
            await library.preservePdf(docId, pdfBytes);
          } catch (_) {
            await dao.deleteDocument(docId);
            rethrow;
          }
        }
      } else {
        docId = await library.add(title, [text], beforeCommit: check);
      }
      return KnowledgeFileImportItem(
        path: path,
        name: name,
        title: title,
        imported: docId != null,
        reason: docId == null ? '导入失败（无可用内容）' : null,
      );
    } catch (e) {
      if (isCurrent?.call() == false) operation.cancel();
      final failure = KnowledgeImportFailure.from(
          operation.isCancelled ? const ImportCancelled() : e,
          pdf: _extOf(name) == 'pdf');
      if (failure.kind == KnowledgeImportErrorKind.cancelled) {
        operation.cancel();
      }
      return KnowledgeFileImportItem(
        path: path,
        name: name,
        title: title,
        imported: false,
        reason: failure.message,
        errorKind: failure.kind,
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
