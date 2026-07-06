import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
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

  const KnowledgeFileImporter(this.dao);

  Future<KnowledgeFileImportResult> importPaths(List<String> paths) async {
    final items = <KnowledgeFileImportItem>[];
    for (final path in paths) {
      final item = await _importPath(path);
      items.add(item);
    }
    return KnowledgeFileImportResult(items);
  }

  Future<KnowledgeFileImportItem> _importPath(String path) async {
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
        text = await FileProcessor.extractTextForImport(path);
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
      final docId = await dao.addDocument(title, text);
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
