import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';

/// 任务附件只发送清单；原文持久保存，由 read_file 分段读取。
class WorkspaceAttachmentProcessor {
  final AgentWorkspaceService workspace;
  const WorkspaceAttachmentProcessor(this.workspace);

  Future<ProcessedFiles> process(List<String> paths,
      {required AttachmentProcessingLimits limits,
      ChatSendProgressCallback? onProgress,
      bool Function()? isCancelled}) async {
    final metas = <FileMetadata>[];
    final diagnostics = <FileProcessingDiagnostic>[];
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
      final record = await workspace.importPath(path, maxBytes: maxBytes);
      if (isCancelled?.call() == true) {
        throw const AttachmentProcessingCancelledException();
      }
      final managedPath = await ManagedAttachmentStore.importFile(File(path),
          maxBytes: maxBytes);
      metas.add(FileMetadata(
          name: record.name,
          path: managedPath,
          size: record.sizeBytes,
          mime: pdf ? 'application/pdf' : 'text/plain',
          workspaceFileId: record.id,
          extractedText: describe(record.toJson())));
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
