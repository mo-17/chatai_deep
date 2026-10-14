import 'dart:async';
import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conversation_generation_test.dart' as support;

class _ThinkingChat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  final String mode;
  final emitted = Completer<void>();
  int requests = 0;
  List<Map<String, dynamic>> lastHistory = [];
  _ThinkingChat(this.mode);
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    lastHistory = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    requests++;
    yield StreamEvent.reasoning('心理/动作：<<<抬手>>>，暂时等待。');
    yield StreamEvent.usage(promptTokens: 6, completionTokens: 4);
    emitted.complete();
    if (mode == 'stop') await options.abortTrigger;
    if (mode == 'error') {
      throw const ChatTransportException(
          safeCode: 'synthetic',
          safeMessage: '合成错误',
          failureKind: ChatFailureKind.transport);
    }
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    lastHistory = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    requests++;
    return const ChatCompletionResult(content: '下一轮开口');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  for (final mode in ['complete', 'stop', 'error', 'saveRetry', 'plain']) {
    test(
        'role continuation $mode: same saved/history snapshot, reopen no replay',
        () async {
      LoginDao.resetHooksForTest();
      support.GenerationTestAuth().install();
      final storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false)));
      final assistant = AssistantModel(
          name: '合成角色', prompt: '受控角色', emoji: '', useTools: false);
      final aid =
          await (await AssistantDao.create(storage)).saveAssistant(assistant);
      final rowId = await (await ConversationListDao.create(storage))
          .saveConversation(ConversationModel(
              cid: 1,
              title: '角色',
              icon: '',
              assistantId: mode == 'plain' ? null : aid));
      final dao = await ConversationGenerationDao.create(storage);
      final chat = _ThinkingChat(mode);
      final settings = support.generationSettings()..streamEnabled = true;
      final service = ConversationGenerationService(
          createChat: (_) => chat, createMemory: (_) async => null);
      try {
        if (mode == 'saveRetry') {
          await storage.db.execute(
              "create trigger fail_reply before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'disk'); end");
        }
        final run = service.start(
            scope: ConversationGenerationScope(account: 'a'),
            dao: dao,
            profile: ConversationGenerationProfile(settings, 'a',
                loadSettings: () async => settings),
            input: ConversationGenerationInput(
                cid: 1,
                conversationRowId: rowId,
                user: MessageModel(
                    ownerType: OwnerType.sender,
                    ownerName: '本人',
                    avatar: '',
                    content: '继续',
                    createdAt: 10),
                assistantId: mode == 'plain' ? null : aid,
                roleContinuationEnabled: mode != 'plain'),
            preparation:
                ReadyConversationTurn(PreparedConversationTurn(prompt: '继续')));
        await chat.emitted.future.timeout(const Duration(seconds: 3));
        if (mode == 'stop') await run.stop('明确停止');
        await run.finished.timeout(const Duration(seconds: 3));
        if (mode == 'saveRetry') {
          expect(run.persistencePending, true);
          expect(chat.requests, 1);
          final cached = MessageBlock.encodeList(run.replyBlocks);
          await storage.db.execute('drop trigger fail_reply');
          await Future.wait([run.retryPersistence(), run.retryPersistence()]);
          expect(MessageBlock.encodeList(run.replyBlocks), cached);
        }
        final rows = await storage.db.query('tb_messages',
            where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]);
        expect(rows, hasLength(1));
        final blocks =
            MessageBlock.decodeList(rows.single['blocks'] as String?);
        final roles = blocks.whereType<RoleContinuationBlock>().toList();
        expect(roles, mode == 'plain' ? isEmpty : hasLength(1));
        if (mode != 'plain') {
          expect(roles.single.modelId, settings.effectiveModel);
          expect(roles.single.content, contains('抬手'));
          expect(
              roles.single.content,
              mode == 'error'
                  ? startsWith('上一轮回复中断')
                  : startsWith('上一轮尚未正式开口'));
          expect(run.completion!.currentRoleContinuationHistory[run.receiverAt],
              roles.single.content);
        } else {
          expect(run.completion!.currentRoleContinuationHistory, isEmpty);
        }
        expect(await storage.db.query('tb_usage'), hasLength(1));
        expect(chat.requests, 1);
        final messages = await (await MessageDao.create(storage, cid: 1))
            .loadContextCandidates(includeStoredBlocks: true);
        final reloaded = CompletionDao(
            chatService: chat,
            settings: settings,
            messages: messages.messages,
            roleContinuationHistory: {
              if (roles.isNotEmpty) run.receiverAt: roles.single.content
            });
        await reloaded.createCompletionsWithSearch(
            prompt: '下一轮',
            webSearch: false,
            requestOptions: const ChatRequestOptions());
        expect(jsonEncode(chat.lastHistory),
            mode == 'plain' ? isNot(contains('抬手')) : contains('抬手'));
        expect(chat.requests, 2);
        expect(await storage.db.query('tb_usage'), hasLength(1));
      } finally {
        for (final r in service.runs.where((r) => r.busy)) {
          await r.retire('cleanup');
        }
        service.dispose();
        await storage.db.close();
        LoginDao.resetHooksForTest();
        LoginSdkConfig.reset();
      }
    });
  }
}
