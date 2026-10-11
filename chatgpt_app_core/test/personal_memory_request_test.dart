import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_context_planner.dart';
import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/fake_composer_chat.dart';
import 'support/personal_memory_test_support.dart';

class PayloadChat extends FakeComposerChat {
  bool firstTool = false;
  PayloadChat() : super(content: '合成回答');
  @override
  Future<String?> chat(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          Duration? timeout}) async =>
      (await chatWithUsage(
              prompt: prompt, history: history, attachments: attachments))
          .content;
  @override
  Stream<String> chatStream(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments}) async* {
    yield (await chat(
        prompt: prompt, history: history, attachments: attachments))!;
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: options);
    if (firstTool && calls == 1) {
      yield StreamEvent.toolCall(
          toolId: 'fixture-call', name: 'fixture', arguments: const {});
    } else {
      yield StreamEvent.text('合成回答');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late PersonalMemoryDao personal;
  late AssistantMemoryDao assistant;
  late PayloadChat chat;
  late PersonalMemoryTestAccount auth;
  Future<void> prefs(bool enabled) async {
    final old = await personal.preferences();
    await personal.setPreferences(
        revision: old.revision, enabled: enabled, suggestionsEnabled: false);
  }

  CompletionDao completion(
          {int cid = 1,
          int? assistantId,
          bool task = false,
          bool auxiliary = false,
          ChatContextPolicy? policy,
          Future<List<WebSearchResult>> Function(
                  String, List<Map<String, dynamic>>)?
              search}) =>
      CompletionDao(
          settings: AISettings.defaults(),
          chatService: chat,
          manageContext: true,
          contextPolicy: policy,
          webSearchRunner: search,
          memoryContextResolver: auxiliary
              ? null
              : ConversationMemoryContext(
                      storage: storage,
                      accountHash: 'a',
                      cid: cid,
                      assistantId: assistantId,
                      taskMode: task,
                      personal: personal,
                      assistant: assistant)
                  .resolve);
  String payload(int index) => jsonEncode(chat.histories[index]);
  setUp(() async {
    sqfliteFfiInit();
    auth = PersonalMemoryTestAccount('a')..install();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    final conversations = await ConversationListDao.create(storage);
    await conversations
        .saveConversation(ConversationModel(cid: 1, title: '一', icon: ''));
    await conversations
        .saveConversation(ConversationModel(cid: 2, title: '二', icon: ''));
    await MessageDao.create(storage, cid: 1);
    personal = await PersonalMemoryDao.create(storage, accountHash: 'a');
    assistant = await AssistantMemoryDao.create(storage);
    await personal.save('合成偏好：回答请简短');
    await prefs(true);
    chat = PayloadChat();
  });
  tearDown(() async {
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  test('非流式/流式/重生成每次读取；关闭/停用/删除后不带，历史原文不含记忆', () async {
    final dao = completion();
    await dao.createCompletionsWithSearch(prompt: '第一轮');
    expect(payload(0), contains('合成偏好'));
    dao.appendTurn(
        MessageModel(
            ownerType: OwnerType.sender, content: '第一轮', createdAt: 10),
        MessageModel(
            ownerType: OwnerType.receiver, content: '原文回答', createdAt: 11));
    dao.dropLastTurn();
    await prefs(false);
    await dao
        .streamCompletionEvents(prompt: '重生成', onProgress: (_) {})
        .toList();
    expect(payload(1), isNot(contains('合成偏好')));
    await prefs(true);
    await dao.streamCompletionEvents(prompt: '新轮', onProgress: (_) {}).toList();
    expect(payload(2), contains('合成偏好'));
    expect(jsonEncode(dao.lastProtocolMessages), isNot(contains('合成偏好')));
    await personal.setStatus(
        (await personal.list()).single, PersonalMemoryStatus.archived);
    await dao.createCompletions(prompt: '停用后');
    expect(payload(3), isNot(contains('合成偏好')));
    await personal.setStatus(
        (await personal.list()).single, PersonalMemoryStatus.active);
    await personal.delete((await personal.list()).single);
    await dao.createCompletions(prompt: '删除后');
    expect(payload(4), isNot(contains('合成偏好')));
    await File('/tmp/chatai-personal-memory-payload-evidence.json')
        .writeAsString(jsonEncode({
      'syntheticOnly': true,
      'requests': chat.histories,
      'protocolMessages': dao.lastProtocolMessages,
      'labels': [
        'nonstream-enabled',
        'regenerate-disabled',
        'stream-enabled',
        'archived',
        'deleted'
      ]
    }));
  });
  test('同账号另一cid带记忆，任务/预测/摘要/标题等无resolver路径不带', () async {
    await completion(cid: 2).createCompletions(prompt: '另一会话');
    expect(payload(0), contains('合成偏好'));
    await completion(task: true).createCompletions(prompt: '任务');
    expect(payload(1), isNot(contains('合成偏好')));
    for (final auxiliary in ['预测补全', '摘要', '标题', '故事房间']) {
      await completion(auxiliary: true).createCompletions(prompt: auxiliary);
      expect(payload(chat.calls - 1), isNot(contains('合成偏好')));
    }
  });
  test('联网意图无个人数据；搜索等待期间关闭后正式dispatch移除', () async {
    final gate = Completer<List<WebSearchResult>>();
    final started = Completer<void>();
    final dao = completion(search: (prompt, history) async {
      expect(jsonEncode(history), isNot(contains('合成偏好')));
      expect(history.where((m) => m['role'] == 'system'), isEmpty);
      started.complete();
      return gate.future;
    });
    final pending =
        dao.createCompletionsWithSearch(prompt: '查询合成资料', webSearch: true);
    await started.future;
    await prefs(false);
    gate.complete(const []);
    await pending;
    expect(chat.calls, 1);
    expect(payload(0), isNot(contains('合成偏好')));
  });
  test('工具多轮在工具等待后重新读取，原始tool协议保持且零自动提炼请求', () async {
    chat.firstTool = true;
    final tools = ToolRegistry([
      ChatTool(
          name: 'fixture',
          description: '离线工具',
          parameters: const {},
          execute: (_) async {
            await prefs(false);
            return const ToolOutcome(content: '真实合成结果');
          })
    ]);
    final dao = completion();
    await dao
        .streamCompletionEvents(
            prompt: '工具请求', tools: tools, onProgress: (_) {})
        .toList();
    expect(chat.calls, 2);
    expect(payload(0), contains('合成偏好'));
    expect(payload(1), isNot(contains('合成偏好')));
    expect(jsonEncode(dao.lastProtocolMessages), contains('真实合成结果'));
    expect(jsonEncode(dao.lastProtocolMessages), isNot(contains('合成偏好')));
  });
  test('助手/悬挂绑定绝不读个人记忆；助手记忆停用/删除后旧DAO动态失效', () async {
    final assistants = await AssistantDao.create(storage);
    final id = (await assistants.saveAssistant(AssistantModel(name: '合成角色')))!;
    await storage.db
        .update('tb_conversation_list', {'assistantId': id}, where: 'cid=1');
    final memory = AssistantMemoryModel(assistantId: id, content: '助手独有记忆');
    await assistant.saveMemory(memory);
    final dao = completion(assistantId: id);
    await dao.createCompletions(prompt: '角色提问');
    expect(payload(0), contains('助手独有记忆'));
    expect(payload(0), isNot(contains('合成偏好')));
    memory.status = AssistantMemoryStatus.archived;
    await assistant.saveMemory(memory);
    await dao.createCompletions(prompt: '停用后');
    expect(payload(1), isNot(contains('助手独有记忆')));
    memory.status = AssistantMemoryStatus.active;
    await assistant.saveMemory(memory);
    await assistant.deleteMemory(memory.id!);
    await dao.createCompletions(prompt: '删除后');
    expect(payload(2), isNot(contains('助手独有记忆')));
    await storage.db
        .update('tb_conversation_list', {'assistantId': 9999}, where: 'cid=1');
    await completion(assistantId: 9999).createCompletions(prompt: '悬挂助手');
    expect(payload(3), isNot(contains('合成偏好')));
  });
  test('记忆进入实际输入预算，空间不够舍弃记忆；已发请求无法撤回', () async {
    await personal.delete((await personal.list()).single);
    await personal.save('😀' * 400);
    await completion(policy: const ChatContextPolicy(inputBudgetTokens: 200))
        .createCompletions(prompt: '本轮短问题');
    expect(payload(0), isNot(contains('😀')));
    chat.pending = Completer();
    final pending = completion().createCompletionsWithSearch(prompt: '已发问题');
    for (var i = 0; i < 100 && chat.calls < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(payload(1), contains('😀'));
    await prefs(false);
    chat.pending!.complete(const ChatCompletionResult(content: '完成'));
    await pending;
    chat.pending = null;
    await completion().createCompletions(prompt: '下一问题');
    expect(payload(2), isNot(contains('😀')));
  });
  test('切换账号后旧resolver拒绝dispatch，不产生请求', () async {
    final dao = completion();
    auth.account = 'b';
    await expectLater(
        dao.createCompletions(prompt: '旧页面'), throwsA(isA<Exception>()));
    expect(chat.calls, 0);
  });
}
