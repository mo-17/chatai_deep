import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// 附件处理器。直译源项目 `prepareParams/fileProcessor.ts` 的策略：
/// **能原生喂模型就喂，不能就降级抽文本**（对用户透明）。
///
/// 决策流程（按能力探测结果 [ModelCapabilities]）：
/// 1. 图片 + caps.image -> 转 base64 data URI 作多模态 part（MIME 修正见
///    [imageMimeFor]）；
/// 2. PDF + caps.pdf 且未超 caps.fileSizeLimitFor('pdf') -> base64 原生发；
/// 3. 其余（不支持 PDF / 超限 / 文本类文件）-> 降级抽文本拼进 prompt：
///    PDF 用 syncfusion 抽文本（限 [maxPdfPages] 页，与源项目一致），
///    文本文件直接读（截断到 [maxTextChars]）。
///
/// 注：超限且 caps.largeFileUpload 时源项目走 File API 上传；本仓库两个
/// provider（OpenAI 直连 / 后端代理）尚无文件上传通道，先统一降级抽文本，
/// 待接入 Anthropic/Gemini 直连时再补。
class FileProcessor {
  /// PDF 降级抽文本的最大页数（源项目 pdf-text-extractor 同为 20 页）。
  static const int maxPdfPages = 20;

  /// 单个文本附件拼进 prompt 的最大字符数，防止撑爆上下文。
  static const int maxTextChars = 30000;

  /// 无能力位 / 无限制配置时的 PDF 原生发送兜底上限（与 OpenAI 32MB 对齐）。
  static const int defaultPdfLimit = 32 * 1024 * 1024;
  static const int maxImageBytes = 20 * 1024 * 1024;
  static const int maxTextFileBytes = 2 * 1024 * 1024;

  /// 文件选择器允许的扩展名（图片走 image_picker，不在此列）。
  static const List<String> pickerExtensions = [
    'pdf',
    'txt',
    'md',
    'markdown',
    'json',
    'csv',
    'log',
    'xml',
    'yaml',
    'yml',
    'html',
    'css',
    'sql',
    'sh',
    'dart',
    'js',
    'ts',
    'py',
    'java',
    'kt',
    'c',
    'cpp',
    'h',
    'swift',
    'go',
  ];

  static const Set<String> _textExts = {
    'txt',
    'md',
    'markdown',
    'json',
    'csv',
    'log',
    'xml',
    'yaml',
    'yml',
    'html',
    'css',
    'sql',
    'sh',
    'dart',
    'js',
    'ts',
    'py',
    'java',
    'kt',
    'c',
    'cpp',
    'h',
    'swift',
    'go',
  };

  /// 按扩展名推断图片 MIME，并做修正收敛：`jpg -> jpeg`（Anthropic 等上游
  /// 不认 `image/jpg`，源项目在 provider 适配层做同样收敛；本仓库的两个
  /// provider 都是 OpenAI 兼容协议，收敛在编码处即等价于适配层）。
  static String imageMimeFor(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'jpg':
      case 'jpeg':
      default:
        // jpg/jpeg 以及未知扩展名（image_picker 压缩产物多为 jpeg）统一 jpeg。
        return 'image/jpeg';
    }
  }

  /// 把本地图片编码为 base64 data URI（MIME 已修正）。
  static Future<String> encodeImage(String path) async {
    final bytes = await readFileBytesBounded(
      File(path),
      maxBytes: maxImageBytes,
      label: '图片附件',
    );
    return 'data:${imageMimeFor(path)};base64,${base64Encode(bytes)}';
  }

  static Future<List<String>> encodeImages(List<String> paths) async {
    return [for (final p in paths) await encodeImage(p)];
  }

  /// 按能力位处理一批用户选择的文件，分拣成「原生 part / 降级文本」，
  /// 并产出 [FileMetadata] 供消息里的 FileBlock 展示。
  static Future<ProcessedFiles> process(
      List<String> paths, ModelCapabilities caps) async {
    final nativeFiles = <NativeFilePart>[];
    final metas = <FileMetadata>[];

    for (final path in paths) {
      final file = File(path);
      final name = path.split(Platform.pathSeparator).last;
      final ext = name.split('.').last.toLowerCase();
      final size = await file.length();
      final managedPath = await ManagedAttachmentStore.importFile(
        file,
        maxBytes: ext == 'pdf' ? defaultPdfLimit : maxTextFileBytes,
      );

      if (ext == 'pdf') {
        final limit = caps.fileSizeLimitFor('pdf') ?? defaultPdfLimit;
        final nativeLimit = limit < defaultPdfLimit ? limit : defaultPdfLimit;
        if (caps.pdf && size <= nativeLimit) {
          // 原生路径：整个 PDF base64 直发（无降级文本，故 extractedText 为 null）。
          final bytes = await readFileBytesBounded(
            file,
            maxBytes: nativeLimit,
            label: 'PDF 附件',
          );
          nativeFiles.add(NativeFilePart(
            filename: name,
            dataUri: 'data:application/pdf;base64,${base64Encode(bytes)}',
          ));
          metas.add(FileMetadata(
              name: name,
              path: managedPath,
              mime: 'application/pdf',
              size: size));
        } else {
          // 降级路径：syncfusion 抽文本（限页），文本随 meta 落库（遗留项 6）。
          final text = _wrapFileText(name, await _extractPdfText(file));
          metas.add(FileMetadata(
              name: name,
              path: managedPath,
              mime: 'application/pdf',
              size: size,
              extractedText: text));
        }
        continue;
      }

      if (_textExts.contains(ext)) {
        final text = _wrapFileText(name, await _readTextFile(file));
        metas.add(FileMetadata(
            name: name,
            path: managedPath,
            mime: 'text/plain',
            size: size,
            extractedText: text));
        continue;
      }

      // 不可解析的类型（理论上被 pickerExtensions 挡掉，这里兜底）。
      metas.add(FileMetadata(
          name: name,
          path: managedPath,
          size: size,
          extractedText: '[附件 $name 的格式暂不支持解析，内容未提供]'));
    }

    return ProcessedFiles(
      nativeFiles: nativeFiles,
      // 当前轮降级文本由各 meta 的 extractedText 拼成 —— 与随消息落库的文本同一份，
      // 保证「当前轮发送」与「跨轮历史重建」格式完全一致。
      extraText:
          metas.map((m) => m.extractedText).whereType<String>().join('\n\n'),
      metas: metas,
    );
  }

  /// 抽取 PDF 文本（限 [maxPdfPages] 页）。解析失败返回提示文案而不抛，
  /// 保证一个坏文件不中断整次发送。
  static Future<String> _extractPdfText(File file) async {
    try {
      final document = PdfDocument(
        inputBytes: await readFileBytesBounded(
          file,
          maxBytes: defaultPdfLimit,
          label: 'PDF 文件',
        ),
      );
      try {
        final pageCount = document.pages.count;
        final endIndex =
            (pageCount > maxPdfPages ? maxPdfPages : pageCount) - 1;
        if (endIndex < 0) return '[PDF 无可读页面]';
        var text = PdfTextExtractor(document)
            .extractText(startPageIndex: 0, endPageIndex: endIndex);
        if (pageCount > maxPdfPages) {
          text += '\n\n[注：原文共 $pageCount 页，仅抽取前 $maxPdfPages 页]';
        }
        return text.trim().isEmpty ? '[PDF 未抽取到文本（可能是扫描件）]' : text;
      } finally {
        document.dispose();
      }
    } catch (e) {
      return '[PDF 解析失败: $e]';
    }
  }

  /// 读取文本文件（截断到 [maxTextChars]）。非 UTF-8 等读取失败时降级提示。
  static Future<String> _readTextFile(File file) async {
    try {
      final bytes = await readFileBytesBounded(
        file,
        maxBytes: maxTextFileBytes,
        label: '文本文件',
      );
      final text = utf8.decode(bytes);
      if (text.length <= maxTextChars) return text;
      return '${text.substring(0, maxTextChars)}\n\n[注：内容过长，已截断]';
    } catch (e) {
      return '[文件读取失败: $e]';
    }
  }

  static String _wrapFileText(String name, String content) =>
      '[附件「$name」内容开始]\n$content\n[附件「$name」内容结束]';

  /// 知识库导入用：从一个本地文件抽**纯正文**（不带附件包裹标记）。
  /// 支持 PDF（限页抽取）与文本类扩展名；其它类型返回 null。
  /// 复用 [_extractPdfText]/[_readTextFile]，解析失败由它们返回提示文案而不抛。
  static Future<String?> extractTextForImport(String path) async {
    final ext = path.split('.').last.toLowerCase();
    if (ext == 'pdf') return _extractPdfText(File(path));
    if (_textExts.contains(ext)) return _readTextFile(File(path));
    return null;
  }

  /// OCR/文本/PDF 共用的知识库导入预检；必须在原生解析器或 OCR 插件接收
  /// 路径前调用，避免它们在 Dart 侧预算建立前分配整个攻击者文件。
  static Future<void> validateKnowledgeImportFile(String path) async {
    final file = File(path);
    final ext = path.split('.').last.toLowerCase();
    final maxBytes = ext == 'pdf'
        ? defaultPdfLimit
        : _textExts.contains(ext)
            ? maxTextFileBytes
            : maxImageBytes;
    if (!await file.exists()) throw const FormatException('导入文件不存在');
    if (await file.length() > maxBytes) {
      throw FormatException('导入文件过大（最多 ${maxBytes ~/ (1024 * 1024)} MiB）');
    }
  }
}

/// [FileProcessor.process] 的产物。
class ProcessedFiles {
  /// 原生发给模型的文件 part（caps 支持时）。
  final List<NativeFilePart> nativeFiles;

  /// 降级抽取的文本（已带文件名包裹标记），拼进当前轮 prompt。
  final String extraText;

  /// 全部文件的元数据，供用户消息里的 FileBlock 展示。
  final List<FileMetadata> metas;

  const ProcessedFiles({
    this.nativeFiles = const [],
    this.extraText = '',
    this.metas = const [],
  });
}
