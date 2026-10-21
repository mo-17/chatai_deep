import 'dart:async';
import 'attachment_ocr.dart';
import 'attachment_batch_budget.dart';
import 'conversation_generation_service.dart';
import 'import_operation.dart';
import 'knowledge_import_error.dart';
import 'pdf_ocr_result.dart';
import 'server_ocr_client.dart';
import '../domain/chat_send_progress.dart';

/// 普通聊天沿用 run 的确认与撤销能力，不捕获页面或 BuildContext。
class ConversationAttachmentOcr {
  final Future<void> Function() verify;
  final bool Function() isCurrent;
  final Future<void> abortTrigger;
  final Future<bool> Function(String, String) confirm;
  final ServerOcrClient Function() createClient;
  final ChatSendProgressCallback? onProgress;
  final String destinationNotice;
  ConversationAttachmentOcr(
      {required this.verify,
      required this.isCurrent,
      required this.abortTrigger,
      required this.confirm,
      required this.createClient,
      this.onProgress,
      this.destinationNotice = '识别文字将随本次消息保存在本地，并发送给当前模型服务。'});

  static AttachmentOcrHandler forRun(ConversationGenerationRun run,
          {ServerOcrClient Function()? createClient}) =>
      ConversationAttachmentOcr(
              verify: run.guard,
              isCurrent: () => run.current && run.profile.visiblyCurrent,
              abortTrigger: run.abortTrigger,
              confirm: run.confirm,
              createClient: createClient ??
                  () => ServerOcrClient.capture(
                      additionalCurrent: () =>
                          run.current && run.profile.visiblyCurrent),
              onProgress: run.requestOptions.onProgress)
          .recognize;

  Future<PdfOcrResult> recognize(AttachmentOcrRequest request) async {
    if (request.bytes.length > ServerOcrClient.maxBytes) {
      throw const AttachmentOcrException(
          '服务器 OCR 单文件最多 8 MiB，请缩小或拆分后发送；原输入已保留');
    }
    final operation = ImportCancellation();
    var finished = false;
    unawaited(abortTrigger.then((_) {
      if (!finished) operation.cancel();
    }, onError: (Object _) {
      if (!finished) operation.cancel();
    }));
    try {
      await _verify();
      final client = createClient();
      if (!await confirm(
          '服务器 OCR 上传确认',
          '附件：${request.filename}\n'
              '${request.pdf ? 'PDF 第 ${request.pageNumbers.join('、')} 页需要识别，整份 PDF 会上传' : '图片会上传并识别为文字'}'
              '至当前后端 ${client.base.authority}。\n\n'
              '任务结束删除服务器原件，$destinationNotice'
              '每个文件最多 8 MiB、PDF 最多 20 页。\n\n'
              '取消会保留草稿，不发送本次消息。')) {
        throw const AttachmentOcrException('已取消服务器 OCR，原输入已保留');
      }
      await _verify();
      operation.check();
      final result = await client.recognizeBytes(request.bytes,
          pdf: request.pdf,
          pageNumbers: request.pageNumbers,
          cancellation: operation,
          onProgress: (stage, page, pages) => reportChatSendProgress(
              onProgress,
              ChatSendProgress(
                  '$stage${pages != null && pages > 0 ? '（$page/$pages 页）' : ''}',
                  fileName: request.filename)));
      await _verify();
      return result;
    } on ImportCancelled {
      throw const AttachmentProcessingCancelledException();
    } on KnowledgeImportFailure catch (error) {
      final message = switch (error.kind) {
        KnowledgeImportErrorKind.permission => '请先登录后使用服务器 OCR，原输入已保留',
        KnowledgeImportErrorKind.timeout => '服务器 OCR 超时，请稍后重试或拆分文件；原输入已保留',
        KnowledgeImportErrorKind.busy => '服务器 OCR 繁忙或已达限额，请稍后重试；原输入已保留',
        KnowledgeImportErrorKind.tooLarge => '附件超过服务器 OCR 限额，请缩小或拆分后发送；原输入已保留',
        _ => '服务器 OCR 未完成，请稍后重试或更换文件；原输入已保留',
      };
      throw AttachmentOcrException(message);
    } finally {
      finished = true;
    }
  }

  Future<void> _verify() async {
    if (!isCurrent()) throw const AttachmentProcessingCancelledException();
    await verify();
    if (!isCurrent()) throw const AttachmentProcessingCancelledException();
  }
}
