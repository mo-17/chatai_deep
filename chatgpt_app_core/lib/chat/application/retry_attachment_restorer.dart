import 'dart:async';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
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

  Future<RestoredRetryAttachments> restore({
    required ChatAttachments persisted,
    required List<FileMetadata> files,
    required ModelCapabilities capabilities,
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
    ChatSendProgressCallback? onProgress,
    Future<void>? abortTrigger,
    bool Function()? isCancelled,
  }) async {
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
      final bytes = await ManagedAttachmentStore.readManagedBytes(file.path,
          maxBytes: FileProcessor.defaultPdfLimit);
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
