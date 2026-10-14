import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_role_context_preview.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';

/// 普通发送的角色上下文也由运行持有；异步世界书解析不再借用页面。
final class ConversationRolePreparation
    implements
        ConversationTurnPreparation,
        AcceptedConversationPreparation,
        UnacceptedConversationPreparation,
        SubmittedDraftOwnership,
        ConfigurationAwareConversationPreparation {
  final ConversationTurnPreparation delegate;
  final AssistantModel? assistant;
  final ConversationModel conversation;
  final List<String> recentMessages;
  ConversationRolePreparation(
      {required this.delegate,
      required ConversationModel conversation,
      AssistantModel? assistant,
      Iterable<String> recentMessages = const []})
      : conversation = ConversationModel.fromJson(
            jsonDecode(jsonEncode(conversation.toJson()))),
        assistant = assistant == null
            ? null
            : AssistantModel.fromJson(
                jsonDecode(jsonEncode(assistant.toJson()))),
        recentMessages = List.unmodifiable(recentMessages);

  @override
  Future<PreparedConversationTurn> prepare(
      ConversationGenerationRun run) async {
    await run.guard();
    final scan = ConversationRoleContextPreview.scanText(
        userInput: run.input.user.content, recentMessages: recentMessages);
    final role = await run.scope.wait(
        ConversationRoleContextPreview.buildSafely(
            assistant: assistant, conversation: conversation, userInput: scan),
        run.abortTrigger);
    await run.guard();
    final turn = await run.scope.wait(delegate.prepare(run), run.abortTrigger);
    run.verify();
    final prompt = [role, interactiveCardSystemPrompt]
        .where((s) => s.trim().isNotEmpty)
        .join('\n\n');
    final at = run.input.user.createdAt;
    final blocks = <MessageBlock>[...turn.userBlocks];
    if (role.trim().isNotEmpty) {
      final a = assistant;
      final hits = a == null
          ? const <AssistantMemoryEntryPreview>[]
          : await run.scope.wait(
              AssistantRoleCardService.matchMemoryEntriesSafely(
                  a.memoryBook, scan,
                  structuredJson: a.worldBookJson,
                  characterName: a.name,
                  characterDescription: a.prompt,
                  creatorNotes: a.description),
              run.abortTrigger);
      run.verify();
      final budget = a == null
          ? null
          : await run.scope.wait(
              AssistantMemoryBook.budgetContextSafely(a.memoryBook, scan,
                  structuredJson: a.worldBookJson,
                  characterName: a.name,
                  characterDescription: a.prompt,
                  creatorNotes: a.description),
              run.abortTrigger);
      run.verify();
      blocks.add(RoleContextBlock(
          id: '${run.runId}:role',
          messageId: chatMessageKey(at),
          createdAt: at,
          status: MessageBlockStatus.success,
          content: prompt,
          memoryBudget: budget?.affected == true ? budget : null,
          memoryHits: hits));
    }
    return PreparedConversationTurn(
        prompt: turn.prompt,
        systemPrompt: prompt,
        attachments: turn.attachments,
        tools: turn.tools,
        userBlocks: blocks);
  }

  @override
  void userAccepted() {
    if (delegate is AcceptedConversationPreparation) {
      (delegate as AcceptedConversationPreparation).userAccepted();
    }
  }

  @override
  Future<void> clearAcceptedDraft(ConversationGenerationRun run) async {
    if (delegate is AcceptedConversationPreparation) {
      await (delegate as AcceptedConversationPreparation)
          .clearAcceptedDraft(run);
    }
  }

  @override
  Future<void> verifyToolConfiguration() async {
    if (delegate is ConfigurationAwareConversationPreparation) {
      await (delegate as ConfigurationAwareConversationPreparation)
          .verifyToolConfiguration();
    }
  }

  @override
  Future<bool> ownsSubmission(DraftSubmissionToken token) async =>
      delegate is SubmittedDraftOwnership &&
      await (delegate as SubmittedDraftOwnership).ownsSubmission(token);

  @override
  Future<void> preserveUnacceptedDraft(ConversationGenerationRun run,
      ConversationGenerationScope writeScope) async {
    if (delegate is UnacceptedConversationPreparation) {
      await (delegate as UnacceptedConversationPreparation)
          .preserveUnacceptedDraft(run, writeScope);
    }
  }

  @override
  Future<void> release() => delegate.release();
}
