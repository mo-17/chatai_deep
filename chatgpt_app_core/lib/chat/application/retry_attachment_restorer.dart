import 'dart:async';
import 'package:login_sdk/platform/app_io.dart';
import 'dart:typed_data';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:crypto/crypto.dart';

final class RestoredRetryAttachments {
  final ChatAttachments attachments;
  final List<FileProcessingDiagnostic> diagnostics;

  const RestoredRetryAttachments(
      {required this.attachments, this.diagnostics = const []});

  bool get hasWarnings => diagnostics.isNotEmpty;
}

final class RetryAttachmentException implements Exception {
  final String message;
  const RetryAttachmentException(this.message);

  @override
  String toString() => message;
}

/// 沿用旧消息的图片和已抽取正文，仅恢复没有抽取正文的原生 PDF。
/// 任意旧路径不会成为读取能力；恢复失败应在删除旧回复前展示给用户。
final class RetryAttachmentRestorer {
  const RetryAttachmentRestorer();

  /// 新路径必须属于捕获账号/独占 generation，旧平铺托管文件仅沿原行授权读取。
  Future<Uint8List?> _readBoundAccountFile(
      String? path, String account, Future<void> Function() checkpoint) async {
    if (path == null || path.isEmpty) return null;
    final rawRoot = ManagedAttachmentStore.rootDirectory.absolute;
    if (await appFileType(rawRoot.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final root = appDirectory(await rawRoot.resolveSymbolicLinks());
    var file = appFile(path).absolute;
    final rawPrefix = '${rawRoot.path}${Platform.pathSeparator}';
    if (file.path.startsWith(rawPrefix)) {
      file = appFile('${root.path}/${file.path.substring(rawPrefix.length)}');
    }
    final prefix = '${root.path}${Platform.pathSeparator}';
    if (!file.path.startsWith(prefix)) return null;
    final segments =
        file.path.substring(prefix.length).split(Platform.pathSeparator);
    String? digest;
    if (segments.length == 1) {
      digest = RegExp(r'^([a-f0-9]{64})(?:\.[a-z0-9]{1,10})?$')
          .firstMatch(segments.single)
          ?.group(1);
    } else if (segments.length == 6 &&
        segments[0] == 'accounts' &&
        segments[1] == AccountResourceScope.tokenFor(account) &&
        segments[2] == 'generations' &&
        RegExp(r'^[a-f0-9-]{36}$').hasMatch(segments[3]) &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(segments[4])) {
      digest = segments[4];
    }
    if (digest == null) return null;
    try {
      await AccountResourceScope.ensureNoLinks(
          root: root, relativeSegments: segments);
      await checkpoint();
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file) return null;
      final bytes = await readFileBytesBounded(file,
          maxBytes: FileProcessor.defaultPdfLimit, label: '原 PDF');
      await checkpoint();
      await AccountResourceScope.ensureNoLinks(
          root: root, relativeSegments: segments);
      final after = await file.stat();
      if (after.type != before.type ||
          after.size != before.size ||
          after.modified != before.modified ||
          sha256.convert(bytes).toString() != digest) {
        return null;
      }
      return bytes;
    } on AttachmentProcessingCancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  Future<RestoredRetryAttachments> restore({
    required ChatAttachments persisted,
    required List<FileMetadata> files,
    required ModelCapabilities capabilities,
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
    ChatSendProgressCallback? onProgress,
    Future<void>? abortTrigger,
    bool Function()? isCancelled,
    String? accountHash,
    Future<void> Function()? beforeRead,
  }) async {
    if ((accountHash == null) != (beforeRead == null)) {
      throw ArgumentError('账号绑定恢复必须同时提供原运行校验');
    }
    var aborted = false;
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) => aborted = true,
          onError: (Object _) => aborted = true));
    }
    Future<void> checkpoint() async {
      await Future<void>.delayed(Duration.zero);
      if (aborted || isCancelled?.call() == true) {
        throw const AttachmentProcessingCancelledException();
      }
    }

    await checkpoint();
    if (persisted.images.isNotEmpty && !capabilities.image) {
      throw const RetryAttachmentException('原提问包含图片，当前模型不支持图片，请切换多模态模型后重试');
    }
    final native = [...persisted.nativeFiles];
    final text = <String>[
      if (persisted.extraText.isNotEmpty) persisted.extraText,
      if (persisted.extraText.isEmpty)
        ...files
            .map((file) => file.extractedText)
            .whereType<String>()
            .where((value) => value.isNotEmpty),
    ];
    final diagnostics = <FileProcessingDiagnostic>[];
    for (final file in files) {
      if (OfficeTextExtractor.isOfficeFile(file.name) &&
          file.extractedText == null &&
          !persisted.extraText.contains('[附件「${file.name}」内容开始]') &&
          !persisted.nativeFiles.any((part) => part.filename == file.name)) {
        // 旧消息只有路径时不能假装模型已经读过 Office 正文，也不重新读取
        // 用户未授权的历史路径；原提问与回复保留，明确重新选择后再发送。
        throw RetryAttachmentException(
            '附件「${file.name}」没有保存的解析正文，请重新选择该文件后发送；原提问和回复已保留');
      }
    }
    final pdfs = files
        .where((file) =>
            file.extractedText == null &&
            (file.mime?.toLowerCase() == 'application/pdf' ||
                file.name.toLowerCase().endsWith('.pdf')))
        .toList();
    for (var index = 0; index < pdfs.length; index++) {
      await checkpoint();
      final file = pdfs[index];
      // 调用者已提供原生 part 时无需重复恢复同一附件。
      if (persisted.nativeFiles.any((part) => part.filename == file.name)) {
        continue;
      }
      await beforeRead?.call();
      await checkpoint();
      final bytes = accountHash == null
          ? await ManagedAttachmentStore.readManagedBytes(file.path,
              maxBytes: FileProcessor.defaultPdfLimit)
          : await _readBoundAccountFile(file.path, accountHash, checkpoint);
      await beforeRead?.call();
      await checkpoint();
      if (bytes == null || (file.size != null && file.size != bytes.length)) {
        throw RetryAttachmentException(
            '附件「${file.name}」已失效或无法安全读取，请重新选择该文件后发送；原提问和回复已保留');
      }
      final basename = file.path!.split(RegExp(r'[/\\]')).last;
      final digest = RegExp(r'^([a-f0-9]{64})(?:\.[a-z0-9]{1,10})?$')
          .firstMatch(basename)
          ?.group(1);
      if (digest != null && sha256.convert(bytes).toString() != digest) {
        throw RetryAttachmentException(
            '附件「${file.name}」内容校验失败，请重新选择该文件后发送；原提问和回复已保留');
      }
      final restored = await FileProcessor.processPdfBytes(bytes, capabilities,
          filename: file.name,
          limits: limits,
          onProgress: (progress) => reportChatSendProgress(
              onProgress,
              ChatSendProgress(progress.label,
                  fileName: file.name, index: index + 1, total: pdfs.length)),
          abortTrigger: abortTrigger,
          isCancelled: isCancelled);
      await checkpoint();
      native.addAll(restored.nativeFiles);
      if (restored.extraText.isNotEmpty) text.add(restored.extraText);
      if (restored.nativeFiles.isEmpty) {
        diagnostics.add(FileProcessingDiagnostic(
          filename: file.name,
          kind: FileProcessingDiagnosticKind.textFallback,
          message: capabilities.pdf
              ? 'PDF 超过当前模型的原生文件上限，重试将发送解析后的文字'
              : '当前模型不支持原生 PDF，重试将发送解析后的文字',
        ));
      }
      diagnostics.addAll(restored.diagnostics);
    }
    return RestoredRetryAttachments(
      attachments: ChatAttachments(
          images: List.unmodifiable(persisted.images),
          nativeFiles: List.unmodifiable(native),
          extraText: text.join('\n\n')),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }
}
