import 'dart:async';
import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'dart:typed_data';
import 'attachment_ocr.dart';
import 'ocr_service.dart' show OcrService;

import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:syncfusion_flutter_pdf/pdf.dart';

export 'attachment_batch_budget.dart'
    show AttachmentProcessingCancelledException;

/// 附件处理器。直译源项目 `prepareParams/fileProcessor.ts` 的策略：
/// **能原生喂模型就喂，不能就降级抽文本**（对用户透明）。
///
/// 决策流程（按能力探测结果 [ModelCapabilities]）：
/// 1. 图片 + caps.image -> 转 base64 data URI 作多模态 part（MIME 修正见
///    [imageMimeFor]）；
/// 2. PDF + caps.pdf 且未超 caps.fileSizeLimitFor('pdf') -> base64 原生发；
/// 3. 其余（不支持 PDF / 超限 / 文本与 Office 文件）-> 抽文本拼进 prompt：
///    PDF 用 syncfusion 抽文本（限 [maxPdfPages] 页，与源项目一致），
///    文本文件直接读，Word / Excel 提取正文与单元格（截断到 [maxTextChars]）。
///
/// 注：超限且 caps.largeFileUpload 时源项目走 File API 上传；本仓库两个
/// provider（OpenAI 直连 / 后端代理）尚无文件上传通道，先统一降级抽文本，
/// 待接入 Anthropic/Gemini 直连时再补。
class FileProcessor {
  /// PDF 降级抽文本的最大页数（源项目 pdf-text-extractor 同为 20 页）。
  static const int maxPdfPages = 20;

  /// 未传入用户配置时，单个文本附件拼进 prompt 的默认最大字符数。
  static const int maxTextChars =
      AttachmentProcessingLimits.defaultMaxTextChars;

  /// 无能力位 / 无限制配置时的 PDF 原生发送兜底上限（与 OpenAI 32MB 对齐）。
  static const int defaultPdfLimit = 32 * 1024 * 1024;
  static const int maxImageBytes = 20 * 1024 * 1024;
  static const List<String> ocrImageExtensions = [
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp'
  ];
  static const int maxTextFileBytes =
      AttachmentProcessingLimits.defaultMaxTextFileBytes;

  /// 文件选择器允许的扩展名（图片走 image_picker，不在此列）。
  static const List<String> pickerExtensions = [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
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
  static Future<String> encodeImage(
    String path, {
    AttachmentBatchBudget? batchBudget,
    void Function(String managedPath)? onSnapshot,
    Future<void>? abortTrigger,
    bool Function()? isCancelled,
  }) async {
    final cancellation = _ProcessingCancellation(abortTrigger, isCancelled);
    await cancellation.checkpoint();
    final budget =
        batchBudget ?? (onSnapshot == null ? null : AttachmentBatchBudget());
    if (budget != null) {
      await budget
          .preflightPaths([path], isCancelled: () => cancellation.isCancelled);
    }
    final Uint8List bytes;
    String? managedPath;
    if (budget == null) {
      bytes = await readFileBytesBounded(appFile(path),
          maxBytes: maxImageBytes, label: '图片附件');
    } else {
      // 编码与历史持久化使用同一份快照，原路径后续增长不会改变本轮附件。
      final snapshot =
          await budget.snapshotFile(appFile(path), maxBytes: maxImageBytes);
      bytes = snapshot.bytes;
      managedPath = snapshot.path;
    }
    await cancellation.checkpoint();
    if (managedPath != null) onSnapshot?.call(managedPath);
    return 'data:${imageMimeFor(path)};base64,${base64Encode(bytes)}';
  }

  static Future<List<String>> encodeImages(
    List<String> paths, {
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
    AttachmentBatchBudget? batchBudget,
    void Function(String sourcePath, String managedPath)? onSnapshot,
    ChatSendProgressCallback? onProgress,
    Future<void>? abortTrigger,
    bool Function()? isCancelled,
  }) async {
    final cancellation = _ProcessingCancellation(abortTrigger, isCancelled);
    final budget = batchBudget ?? AttachmentBatchBudget(limits: limits);
    await budget.preflightPaths(paths,
        isCancelled: () => cancellation.isCancelled);
    final images = <String>[];
    for (var i = 0; i < paths.length; i++) {
      await cancellation.checkpoint();
      reportChatSendProgress(
        onProgress,
        ChatSendProgress('准备图片',
            fileName: paths[i].split(RegExp(r'[/\\]')).last,
            index: i + 1,
            total: paths.length),
      );
      images.add(await encodeImage(paths[i],
          batchBudget: budget,
          onSnapshot: onSnapshot == null
              ? null
              : (managedPath) => onSnapshot(paths[i], managedPath),
          abortTrigger: abortTrigger,
          isCancelled: isCancelled));
      await cancellation.checkpoint();
    }
    return images;
  }

  /// 按能力位处理一批用户选择的文件，分拣成「原生 part / 降级文本」，
  /// 并产出 [FileMetadata] 供消息里的 FileBlock 展示。
  static Future<ProcessedFiles> process(
    List<String> paths,
    ModelCapabilities caps, {
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
    AttachmentBatchBudget? batchBudget,
    ChatSendProgressCallback? onProgress,
    Future<void>? abortTrigger,
    bool Function()? isCancelled,
    AttachmentOcrHandler? ocr,
  }) async {
    final nativeFiles = <NativeFilePart>[];
    final metas = <FileMetadata>[];
    final diagnostics = <FileProcessingDiagnostic>[];
    final cancellation = _ProcessingCancellation(abortTrigger, isCancelled);
    final effectiveLimits = limits.normalized;
    final budget =
        batchBudget ?? AttachmentBatchBudget(limits: effectiveLimits);
    await budget.preflightPaths(paths,
        isCancelled: () => cancellation.isCancelled);
    var hasText = false;
    void addMeta(FileMetadata meta) {
      final text = meta.extractedText;
      if (text != null) {
        budget.consumeText('${hasText ? '\n\n' : ''}$text');
        hasText = true;
      }
      metas.add(meta);
    }

    for (var index = 0; index < paths.length; index++) {
      await cancellation.checkpoint();
      final path = paths[index];
      final file = appFile(path);
      final name = path.split(Platform.pathSeparator).last;
      final ext = name.split('.').last.toLowerCase();
      reportChatSendProgress(
          onProgress,
          ChatSendProgress('解析附件',
              fileName: name, index: index + 1, total: paths.length));
      await cancellation.checkpoint();
      final snapshot = await budget.snapshotFile(
        file,
        maxBytes:
            ext == 'pdf' ? defaultPdfLimit : effectiveLimits.maxTextFileBytes,
      );
      final managedPath = snapshot.path;
      final bytes = snapshot.bytes;
      final size = bytes.length;
      await cancellation.checkpoint();

      if (ext == 'pdf') {
        final limit = caps.fileSizeLimitFor('pdf') ?? defaultPdfLimit;
        final nativeLimit = limit < defaultPdfLimit ? limit : defaultPdfLimit;
        if (caps.pdf && size <= nativeLimit) {
          // 原生路径：整个 PDF base64 直发（无降级文本，故 extractedText 为 null）。
          nativeFiles.add(NativeFilePart(
            filename: name,
            dataUri: 'data:application/pdf;base64,${base64Encode(bytes)}',
          ));
          addMeta(FileMetadata(
              name: name,
              path: managedPath,
              mime: 'application/pdf',
              size: size));
        } else {
          // 降级路径：syncfusion 抽文本（限页），文本随 meta 落库（遗留项 6）。
          final extracted = ocr == null
              ? _extractPdfBytesContent(bytes,
                  limitCharacters: true, limits: effectiveLimits)
              : await _extractPdfWithOcr(bytes,
                  filename: name,
                  limits: effectiveLimits,
                  ocr: ocr,
                  cancellation: cancellation);
          await cancellation.checkpoint();
          diagnostics.addAll(extracted.diagnosticsFor(name));
          final text = _wrapFileText(name, extracted.text);
          addMeta(FileMetadata(
              name: name,
              path: managedPath,
              mime: 'application/pdf',
              size: size,
              extractedText: text));
        }
        continue;
      }

      if (ocr != null && ocrImageExtensions.contains(ext)) {
        final recognized = await ocr(
            AttachmentOcrRequest(filename: name, bytes: bytes, pdf: false));
        await cancellation.checkpoint();
        if (recognized.totalPages != 1 || recognized.pages.length != 1) {
          throw const AttachmentOcrException('图片识别结果无效，请重新选择后发送');
        }
        final extracted =
            _limitRecognizedText(recognized.text, effectiveLimits);
        diagnostics.addAll(extracted.diagnosticsFor(name));
        addMeta(FileMetadata(
            name: name,
            path: managedPath,
            size: size,
            mime: ext == 'bmp' ? 'image/bmp' : imageMimeFor(name),
            extractedText: _wrapFileText(name, extracted.text)));
        continue;
      }

      if (_textExts.contains(ext)) {
        final extracted = _textBytesContent(bytes, limits: effectiveLimits);
        await cancellation.checkpoint();
        diagnostics.addAll(extracted.diagnosticsFor(name));
        final text = _wrapFileText(name, extracted.text);
        addMeta(FileMetadata(
            name: name,
            path: managedPath,
            mime: 'text/plain',
            size: size,
            extractedText: text));
        continue;
      }

      if (OfficeTextExtractor.isOfficeFile(name)) {
        final extracted = await _extractOfficeByteContent(bytes,
            filename: name, limits: effectiveLimits);
        await cancellation.checkpoint();
        diagnostics.addAll(extracted.diagnosticsFor(name));
        addMeta(FileMetadata(
            name: name,
            path: managedPath,
            mime: OfficeTextExtractor.mimeFor(name),
            size: size,
            extractedText: _wrapFileText(name, extracted.text)));
        continue;
      }

      // 不可解析的类型（理论上被 pickerExtensions 挡掉，这里兜底）。
      diagnostics.add(FileProcessingDiagnostic(
        filename: name,
        kind: FileProcessingDiagnosticKind.unsupported,
        message: '文件格式暂不支持解析，模型不会收到文件正文',
      ));
      addMeta(FileMetadata(
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
      diagnostics: diagnostics,
    );
  }

  static _ExtractedContent _limitRecognizedText(
      String text, AttachmentProcessingLimits limits) {
    if (text.trim().isEmpty) {
      throw const AttachmentOcrException('未识别到附件文字，原输入已保留，请更换清晰图片后重试');
    }
    final limit = limits.normalized.maxTextChars;
    if (text.length > limit) {
      return _ExtractedContent('${text.substring(0, limit)}\n\n[注：内容过长，已截断]', [
        _ExtractionWarning(FileProcessingDiagnosticKind.truncated,
            '识别文字超过 $limit 字符，仅发送前 $limit 字符')
      ]);
    }
    return _ExtractedContent(text);
  }

  static Future<_ExtractedContent> _extractPdfWithOcr(Uint8List bytes,
      {required String filename,
      required AttachmentProcessingLimits limits,
      required AttachmentOcrHandler ocr,
      required _ProcessingCancellation cancellation}) async {
    final pages = <String>[];
    int total;
    // PDF 解析失败沿用原有诊断；OCR 的拒绝/失败不能被解析器 catch 吞掉。
    try {
      final document = PdfDocument(inputBytes: bytes);
      try {
        total = document.pages.count;
        final extractor = PdfTextExtractor(document);
        for (var i = 0; i < total && i < maxPdfPages; i++) {
          pages.add(extractor.extractText(startPageIndex: i, endPageIndex: i));
        }
      } finally {
        document.dispose();
      }
    } catch (_) {
      return _pdfExtractionFailure;
    }
    await cancellation.checkpoint();
    final missing = [
      for (var i = 0; i < pages.length; i++)
        if (OcrService.pdfNeedsOcr(pages[i])) i + 1
    ];
    if (missing.isEmpty || total > maxPdfPages) {
      return _extractPdfBytesContent(bytes,
          limitCharacters: true, limits: limits);
    }
    final recognized = await ocr(AttachmentOcrRequest(
        filename: filename,
        bytes: bytes,
        pdf: true,
        totalPages: total,
        pageNumbers: missing));
    await cancellation.checkpoint();
    if (recognized.totalPages != total || recognized.pages.length != total) {
      throw const AttachmentOcrException('OCR 页数与 PDF 不一致，原输入已保留');
    }
    for (final page in missing) {
      if (recognized.pages[page - 1].trim().isNotEmpty) {
        pages[page - 1] = recognized.pages[page - 1];
      }
    }
    final warnings = <_ExtractionWarning>[];
    final empty = [
      for (final page in missing)
        if (recognized.pages[page - 1].trim().isEmpty) page
    ];
    if (empty.isNotEmpty) {
      warnings.add(_ExtractionWarning(FileProcessingDiagnosticKind.scannedPdf,
          '第 ${empty.join('、')} 页未补充识别文字，已保留原有文字；请确认是否为空白页'));
    }
    final nonempty = pages.any((page) => page.trim().isNotEmpty);
    if (!nonempty) {
      throw const AttachmentOcrException('未识别到 PDF 文字，原输入已保留，请更换清晰扫描件后重试');
    }
    final result = _limitRecognizedText(
        [
          for (var i = 0; i < pages.length; i++)
            '【第 ${i + 1} 页】\n${pages[i].trim()}'
        ].join('\n\n'),
        limits);
    return _ExtractedContent(result.text, [...warnings, ...result.warnings]);
  }

  /// 抽取 PDF 文本（限 [maxPdfPages] 页）。解析失败返回提示文案而不抛，
  /// 保证一个坏文件不中断整次发送。
  static Future<String> _extractPdfText(File file,
          {AttachmentProcessingLimits limits =
              const AttachmentProcessingLimits()}) async =>
      (await _extractPdfContent(file, limitCharacters: true, limits: limits))
          .text;

  static Future<_ExtractedContent> _extractPdfContent(File file,
      {bool limitCharacters = false,
      AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    try {
      final bytes = await readFileBytesBounded(file,
          maxBytes: defaultPdfLimit, label: 'PDF 文件');
      return _extractPdfBytesContent(bytes,
          limitCharacters: limitCharacters, limits: limits);
    } catch (_) {
      return _pdfExtractionFailure;
    }
  }

  /// 重试附件已通过托管目录检查后使用其准确字节，避免再次读取旧路径。
  static Future<ProcessedFiles> processPdfBytes(
    Uint8List bytes,
    ModelCapabilities caps, {
    required String filename,
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
    ChatSendProgressCallback? onProgress,
    Future<void>? abortTrigger,
    bool Function()? isCancelled,
  }) async {
    final cancellation = _ProcessingCancellation(abortTrigger, isCancelled);
    await cancellation.checkpoint();
    if (bytes.length > defaultPdfLimit) {
      throw const FormatException('PDF 附件过大（最多 32 MiB）');
    }
    reportChatSendProgress(
        onProgress, ChatSendProgress('恢复 PDF 附件', fileName: filename));
    await cancellation.checkpoint();
    final configuredLimit = caps.fileSizeLimitFor('pdf') ?? defaultPdfLimit;
    final nativeLimit =
        configuredLimit < defaultPdfLimit ? configuredLimit : defaultPdfLimit;
    if (caps.pdf && bytes.length <= nativeLimit) {
      return ProcessedFiles(nativeFiles: [
        NativeFilePart(
            filename: filename,
            dataUri: 'data:application/pdf;base64,${base64Encode(bytes)}')
      ]);
    }
    final extracted = _extractPdfBytesContent(bytes,
        limitCharacters: true, limits: limits.normalized);
    await cancellation.checkpoint();
    return ProcessedFiles(
        extraText: _wrapFileText(filename, extracted.text),
        diagnostics: extracted.diagnosticsFor(filename).toList());
  }

  static const _pdfExtractionFailure = _ExtractedContent('[PDF 解析失败，内容未提供]', [
    _ExtractionWarning(
        FileProcessingDiagnosticKind.failed, 'PDF 解析失败，模型不会收到文件正文'),
  ]);

  static _ExtractedContent _extractPdfBytesContent(Uint8List bytes,
      {bool limitCharacters = false,
      AttachmentProcessingLimits limits = const AttachmentProcessingLimits()}) {
    try {
      final document = PdfDocument(inputBytes: bytes);
      try {
        final pageCount = document.pages.count;
        final endIndex =
            (pageCount > maxPdfPages ? maxPdfPages : pageCount) - 1;
        if (endIndex < 0) {
          return const _ExtractedContent('[PDF 无可读页面]', [
            _ExtractionWarning(
                FileProcessingDiagnosticKind.empty, 'PDF 无可读页面，模型不会收到文件正文'),
          ]);
        }
        var text = PdfTextExtractor(document)
            .extractText(startPageIndex: 0, endPageIndex: endIndex);
        final warnings = <_ExtractionWarning>[];
        if (text.trim().isEmpty) {
          return const _ExtractedContent('[PDF 未抽取到文本（可能是扫描件）]', [
            _ExtractionWarning(FileProcessingDiagnosticKind.scannedPdf,
                '未抽取到文字，PDF 可能是扫描件；当前仅发送解析提示'),
          ]);
        }
        final textLimit = limits.normalized.maxTextChars;
        if (limitCharacters && text.length > textLimit) {
          text = '${text.substring(0, textLimit)}\n\n[注：内容过长，已截断]';
          warnings.add(_ExtractionWarning(
              FileProcessingDiagnosticKind.truncated,
              'PDF 文字超过 $textLimit 字符，仅发送前 $textLimit 字符'));
        }
        if (pageCount > maxPdfPages) {
          text += '\n\n[注：原文共 $pageCount 页，仅抽取前 $maxPdfPages 页]';
          warnings.add(_ExtractionWarning(
              FileProcessingDiagnosticKind.truncated,
              'PDF 共 $pageCount 页，仅解析前 $maxPdfPages 页'));
        }
        return _ExtractedContent(text, warnings);
      } finally {
        document.dispose();
      }
    } catch (_) {
      return _pdfExtractionFailure;
    }
  }

  /// 读取文本文件（按用户配置截断）。非 UTF-8 等读取失败时降级提示。
  static Future<String> _readTextFile(File file,
          {AttachmentProcessingLimits limits =
              const AttachmentProcessingLimits()}) async =>
      (await _readTextContent(file, limits: limits)).text;

  static Future<_ExtractedContent> _readTextContent(File file,
      {AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    final effectiveLimits = limits.normalized;
    try {
      final bytes = await readFileBytesBounded(
        file,
        maxBytes: effectiveLimits.maxTextFileBytes,
        label: '文本文件',
      );
      return _textBytesContent(bytes, limits: effectiveLimits);
    } catch (_) {
      return _textReadFailure;
    }
  }

  static const _textReadFailure = _ExtractedContent('[文件读取失败，内容未提供]', [
    _ExtractionWarning(
        FileProcessingDiagnosticKind.failed, '文件读取失败，可能不是 UTF-8 文本或文件不可访问'),
  ]);

  static _ExtractedContent _textBytesContent(Uint8List bytes,
      {required AttachmentProcessingLimits limits}) {
    final effectiveLimits = limits.normalized;
    try {
      final text = utf8.decode(bytes);
      if (text.trim().isEmpty) {
        return _ExtractedContent(text, const [
          _ExtractionWarning(FileProcessingDiagnosticKind.empty, '文件没有可读文字'),
        ]);
      }
      final textLimit = effectiveLimits.maxTextChars;
      if (text.length <= textLimit) return _ExtractedContent(text);
      return _ExtractedContent(
          '${text.substring(0, textLimit)}\n\n[注：内容过长，已截断]', [
        _ExtractionWarning(FileProcessingDiagnosticKind.truncated,
            '文字超过 $textLimit 字符，仅发送前 $textLimit 字符'),
      ]);
    } catch (_) {
      return _textReadFailure;
    }
  }

  static String _wrapFileText(String name, String content) =>
      '[附件「$name」内容开始]\n$content\n[附件「$name」内容结束]';

  static Future<_ExtractedContent> _extractOfficeByteContent(Uint8List bytes,
      {required String filename,
      required AttachmentProcessingLimits limits}) async {
    try {
      final extraction = await compute(
          _extractOfficeBytes, {'bytes': bytes, 'filename': filename});
      return _officeContent(extraction, limits);
    } catch (error) {
      final message = error is FormatException
          ? _officeFailureMessage(error)
          : 'Word / Excel 文件读取或解析失败';
      return _ExtractedContent('[$message，内容未提供]', [
        _ExtractionWarning(FileProcessingDiagnosticKind.failed, message),
      ]);
    }
  }

  static Future<OfficeTextExtraction> _readOfficeFile(File file,
      {required String filename,
      required AttachmentProcessingLimits limits}) async {
    final bytes = await readFileBytesBounded(file,
        maxBytes: limits.normalized.maxTextFileBytes, label: 'Word / Excel 文件');
    // 解析压缩包和二进制表格在后台 isolate 完成，避免阻塞输入和停止按钮。
    return compute(_extractOfficeBytes, {'bytes': bytes, 'filename': filename});
  }

  static _ExtractedContent _officeContent(
      OfficeTextExtraction extraction, AttachmentProcessingLimits limits) {
    var text = extraction.text;
    final warnings = [
      for (final warning in extraction.warnings)
        _ExtractionWarning(FileProcessingDiagnosticKind.textFallback, warning),
    ];
    if (text.trim().isEmpty) {
      warnings.add(const _ExtractionWarning(
          FileProcessingDiagnosticKind.empty, 'Word / Excel 文件没有可读文字'));
    }
    final limit = limits.normalized.maxTextChars;
    if (text.length > limit) {
      // 不在 UTF-16 代理对中间截断中文之外的字符。
      var end = limit;
      final last = text.codeUnitAt(end - 1);
      if (last >= 0xd800 && last <= 0xdbff) end--;
      text = '${text.substring(0, end)}\n\n[注：内容过长，已截断]';
      warnings.add(_ExtractionWarning(FileProcessingDiagnosticKind.truncated,
          'Word / Excel 文字超过 $limit 字符，仅发送前 $limit 字符'));
    }
    return _ExtractedContent(text, warnings);
  }

  static String _officeFailureMessage(FormatException error) {
    // 原生 XML / 压缩包异常可能包含正文片段；只展示本地固定诊断。
    final message = error.message.toString();
    if (message.contains('加密') || message.contains('密码')) {
      return 'Word / Excel 文件已加密，请移除密码后重新上传';
    }
    if (message.contains('上限') ||
        message.contains('过大') ||
        message.contains('超出') ||
        message.contains('超过')) {
      return 'Word / Excel 文件解析内容超过安全上限，请拆分后重新上传';
    }
    if (message.contains('版本') || message.contains('不支持')) {
      return 'Word / Excel 文件版本或内容暂不支持，请另存为 DOCX / XLSX 后上传';
    }
    return 'Word / Excel 文件损坏或格式不正确，请检查后重新上传';
  }

  /// 引用预览直接解析已校验的字节，不再打开可能被替换的路径。
  static Future<String?> extractTextFromBytes(Uint8List bytes,
      {required String filename,
      AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    final effectiveLimits = limits.normalized;
    final ext = filename.split('.').last.toLowerCase();
    if (ext == 'pdf') {
      return _extractPdfBytesContent(bytes,
              limitCharacters: true, limits: effectiveLimits)
          .text;
    }
    if (_textExts.contains(ext)) {
      return _textBytesContent(bytes, limits: effectiveLimits).text;
    }
    if (OfficeTextExtractor.isOfficeFile(filename)) {
      return (await _extractOfficeByteContent(bytes,
              filename: filename, limits: effectiveLimits))
          .text;
    }
    return null;
  }

  /// 知识库导入用：从一个本地文件抽**纯正文**（不带附件包裹标记）。
  /// 支持 PDF（限页抽取）、文本与 Word / Excel；其它类型返回 null。
  /// Office 解析失败抛出异常，避免把错误提示当成知识库正文保存。
  static Future<String?> extractTextForImport(String path,
      {AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    final ext = path.split('.').last.toLowerCase();
    final effectiveLimits = limits.normalized;
    if (ext == 'pdf') {
      return _extractPdfText(appFile(path), limits: effectiveLimits);
    }
    if (_textExts.contains(ext)) {
      return _readTextFile(appFile(path), limits: effectiveLimits);
    }
    if (OfficeTextExtractor.isOfficeFile(path)) {
      // 导入失败必须由调用方报告，不能把失败提示当成知识库正文保存。
      final extraction = await _readOfficeFile(appFile(path),
          filename: path.split(RegExp(r'[/\\]')).last, limits: effectiveLimits);
      return _officeContent(extraction, effectiveLimits).text;
    }
    return null;
  }

  /// OCR/文本/PDF 共用的知识库导入预检；必须在原生解析器或 OCR 插件接收
  /// 路径前调用，避免它们在 Dart 侧预算建立前分配整个攻击者文件。
  static Future<void> validateKnowledgeImportFile(String path,
      {AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    final file = appFile(path);
    final ext = path.split('.').last.toLowerCase();
    final maxBytes = ext == 'pdf'
        ? defaultPdfLimit
        : (_textExts.contains(ext) || OfficeTextExtractor.isOfficeFile(path))
            ? limits.normalized.maxTextFileBytes
            : maxImageBytes;
    if (!await file.exists()) throw const FormatException('导入文件不存在');
    if (await file.length() > maxBytes) {
      final mib = maxBytes / (1024 * 1024);
      final display =
          mib == mib.roundToDouble() ? '${mib.toInt()} MiB' : '$maxBytes bytes';
      throw FormatException('导入文件过大（最多 $display）');
    }
  }
}

OfficeTextExtraction _extractOfficeBytes(Map<String, dynamic> input) =>
    OfficeTextExtractor.extractBytes(input['bytes'] as Uint8List,
        filename: input['filename'] as String);

/// [FileProcessor.process] 的产物。
class ProcessedFiles {
  /// 原生发给模型的文件 part（caps 支持时）。
  final List<NativeFilePart> nativeFiles;

  /// 降级抽取的文本（已带文件名包裹标记），拼进当前轮 prompt。
  final String extraText;

  /// 全部文件的元数据，供用户消息里的 FileBlock 展示。
  final List<FileMetadata> metas;

  /// 本轮预检结果，供发送前确认；不修改旧消息的 FileMetadata/落库格式。
  final List<FileProcessingDiagnostic> diagnostics;

  bool get hasWarnings => diagnostics.isNotEmpty;

  const ProcessedFiles({
    this.nativeFiles = const [],
    this.extraText = '',
    this.metas = const [],
    this.diagnostics = const [],
  });
}

enum FileProcessingDiagnosticKind {
  failed,
  empty,
  scannedPdf,
  truncated,
  unsupported,
  textFallback,
}

final class FileProcessingDiagnostic {
  final String filename;
  final FileProcessingDiagnosticKind kind;
  final String message;

  const FileProcessingDiagnostic({
    required this.filename,
    required this.kind,
    required this.message,
  });
}

final class _ProcessingCancellation {
  final bool Function()? _isCancelled;
  bool _aborted = false;

  _ProcessingCancellation(Future<void>? abortTrigger, this._isCancelled) {
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) => _aborted = true,
          onError: (Object _) => _aborted = true));
    }
  }

  bool get isCancelled => _aborted || _isCancelled?.call() == true;

  Future<void> checkpoint() async {
    // 给取消信号与画面更新一次执行机会；同步解析器完成后再检查一次。
    await Future<void>.delayed(Duration.zero);
    if (isCancelled) {
      throw const AttachmentProcessingCancelledException();
    }
  }
}

final class _ExtractionWarning {
  final FileProcessingDiagnosticKind kind;
  final String message;

  const _ExtractionWarning(this.kind, this.message);
}

final class _ExtractedContent {
  final String text;
  final List<_ExtractionWarning> warnings;

  const _ExtractedContent(this.text, [this.warnings = const []]);

  Iterable<FileProcessingDiagnostic> diagnosticsFor(String name) =>
      warnings.map((warning) => FileProcessingDiagnostic(
            filename: name,
            kind: warning.kind,
            message: warning.message,
          ));
}
