import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/office_text_extractor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:login_sdk/platform/app_io.dart';
import 'attachment_ocr.dart';

/// 任务附件只发送清单；原文持久保存，由 read_file 分段读取。
class WorkspaceAttachmentProcessor {
  final AgentWorkspaceService workspace;
  const WorkspaceAttachmentProcessor(this.workspace);

  Future<ProcessedFiles> process(List<String> paths,
      {required AttachmentProcessingLimits limits,
      AttachmentBatchBudget? batchBudget,
      ChatSendProgressCallback? onProgress,
      AttachmentOcrHandler? ocr,
      bool Function()? isCancelled}) async {
    final metas = <FileMetadata>[];
    final diagnostics = <FileProcessingDiagnostic>[];
    final budget = batchBudget ?? AttachmentBatchBudget(limits: limits);
    await budget.preflightPaths(paths, isCancelled: isCancelled);
    for (var index = 0; index < paths.length; index++) {
      if (isCancelled?.call() == true) {
        throw const AttachmentProcessingCancelledException();
      }
      final path = paths[index];
      final name = path.split(RegExp(r'[/\\]')).last;
      onProgress?.call(ChatSendProgress('保存工作区附件',
          fileName: name, index: index + 1, total: paths.length));
      final pdf = name.toLowerCase().endsWith('.pdf');
      final maxBytes = pdf
          ? FileProcessor.defaultPdfLimit
          : limits.normalized.maxTextFileBytes;
      final snapshot =
          await budget.snapshotFile(appFile(path), maxBytes: maxBytes);
      final separator = metas.isEmpty ? '' : '\n\n';
      var reservedCharacters = 0;
      final record = await workspace.importBytes(snapshot.bytes,
          name: name,
          sourceKey: path,
          maxBytes: maxBytes,
          ocr: ocr,
          canCommit: () => isCancelled?.call() != true,
          validateParsed: (fullText, actualBytes, manifestPreview) {
            if (isCancelled?.call() == true) {
              throw const AttachmentProcessingCancelledException();
            }
            if (actualBytes != snapshot.bytes.length) {
              throw const FormatException('工作区附件快照字节不一致');
            }
            budget.consumeText(fullText);
            final manifest = '$separator${describe(manifestPreview)}';
            budget.consumeText(manifest);
            reservedCharacters = manifest.length;
          },
          onWarnings: (warnings) {
            diagnostics.addAll(warnings.map((warning) =>
                FileProcessingDiagnostic(
                    filename: name,
                    kind: FileProcessingDiagnosticKind.textFallback,
                    message: warning)));
          });
      final manifest = describe(record.toJson());
      budget.replaceTextReservation(reservedCharacters, '$separator$manifest');
      if (isCancelled?.call() == true) {
        throw const AttachmentProcessingCancelledException();
      }
      metas.add(FileMetadata(
          name: record.name,
          path: snapshot.path,
          size: record.sizeBytes,
          mime: pdf
              ? 'application/pdf'
              : OfficeTextExtractor.isOfficeFile(name)
                  ? OfficeTextExtractor.mimeFor(name)
                  : 'text/plain',
          workspaceFileId: record.id,
          extractedText: manifest));
      if (record.characterCount == 0) {
        diagnostics.add(FileProcessingDiagnostic(
            filename: record.name,
            kind: pdf
                ? FileProcessingDiagnosticKind.scannedPdf
                : FileProcessingDiagnosticKind.empty,
            message: pdf ? '未提取到 PDF 文字，扫描页暂不能按需阅读' : '文件内容为空'));
      }
    }
    return ProcessedFiles(
        metas: metas,
        extraText: metas.map((m) => m.extractedText!).join('\n\n'),
        diagnostics: diagnostics);
  }

  static String describe(Map<String, dynamic> metadata) =>
      '【工作区附件，正文尚未读取】\n${jsonEncode(metadata)}\n'
      '使用 read_file 按 offset/行/页/章节读取；file_search 只提供定位，不能代替全文阅读。';
}
