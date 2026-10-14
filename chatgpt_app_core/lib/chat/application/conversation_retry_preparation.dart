import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_run_tools.dart';
import 'package:chatgpt_app_core/chat/application/retry_attachment_restorer.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';

/// 重试仅使用点击时捕获的原用户行附件，不读取页面的当前草稿。
final class RetryGenerationPreparation
    implements
        ConversationTurnPreparation,
        ConfigurationAwareConversationPreparation {
  final ChatAttachments persisted;
  final List<FileMetadata> files;
  final List<MessageBlock> userBlocks;
  final ConversationRunTools? runTools;
  bool _released = false;
  RetryGenerationPreparation(
      {required ChatAttachments persisted,
      required List<MessageBlock> userBlocks,
      this.runTools})
      : persisted = ChatAttachments(
            images: List.unmodifiable(persisted.images),
            nativeFiles: List.unmodifiable(persisted.nativeFiles),
            extraText: persisted.extraText),
        userBlocks = List.unmodifiable(userBlocks.map(
            (b) => MessageBlock.fromJson(jsonDecode(jsonEncode(b.toJson()))))),
        files = List.unmodifiable(userBlocks.whereType<FileBlock>().map((b) =>
            FileMetadata.fromJson(jsonDecode(jsonEncode(b.file.toJson())))));

  @override
  Future<PreparedConversationTurn> prepare(
      ConversationGenerationRun run) async {
    if (_released ||
        run.input.existingUserRowId == null ||
        run.input.existingSourceRowHash == null) {
      throw const RetryAttachmentException('重试来源身份不完整，请重新打开原消息');
    }
    await run.guard();
    final restored = await const RetryAttachmentRestorer().restore(
        persisted: persisted,
        files: files,
        capabilities: ChatService.capabilitiesFor(run.profile.settings),
        limits: run.profile.settings.attachmentProcessingLimits,
        accountHash: run.scope.account,
        beforeRead: run.guard,
        abortTrigger: run.abortTrigger,
        isCancelled: () => !run.current);
    if (restored.hasWarnings &&
        !await run.confirm(
            '附件重试说明',
            restored.diagnostics
                .map((d) => '${d.filename}：${d.message}')
                .join('\n'))) {
      throw const RetryAttachmentException('附件说明尚未确认，原消息与回复已保留');
    }
    await run.guard();
    return PreparedConversationTurn(
        prompt: run.input.user.content,
        attachments: restored.attachments,
        userBlocks: userBlocks,
        tools: await runTools?.create(run));
  }

  @override
  Future<void> verifyToolConfiguration() async =>
      runTools?.verifyConfiguration();
  @override
  Future<void> release() async {
    _released = true;
    runTools?.release();
  }
}
