import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';

class FakeComposerChat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService,
        OptionsAwareChatService {
  int calls = 0;
  final prompts = <String>[];
  final histories = <List<Map<String, dynamic>>>[];
  final requests = <ChatRequestOptions>[];
  final attachmentsReceived = <ChatAttachments?>[];
  String content;
  bool fail = false;
  Completer<ChatCompletionResult>? pending;

  FakeComposerChat({this.content = '{"suggestion":"请给一个具体例子。"}'});

  @override
  ModelCapabilities get capabilities => const ModelCapabilities();

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    final messages = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    calls++;
    prompts.add(prompt);
    histories.add(messages);
    requests.add(options);
    attachmentsReceived.add(attachments);
    if (fail) throw StateError('fake failure');
    if (pending != null) {
      return Future.any([
        pending!.future,
        if (options.abortTrigger != null)
          options.abortTrigger!.then<ChatCompletionResult>((_) =>
              throw const ChatTransportException(
                  safeCode: 'cancelled',
                  safeMessage: '已取消',
                  failureKind: ChatFailureKind.cancelled)),
      ]);
    }
    return ChatCompletionResult(
        content: content,
        promptTokens: 100,
        cachedPromptTokens: 20,
        completionTokens: 12);
  }

  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      chatWithUsageWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: const ChatRequestOptions());

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    final result = await chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: options);
    yield StreamEvent.text(result.content ?? '');
    yield StreamEvent.usage(promptTokens: 100, completionTokens: 12);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
