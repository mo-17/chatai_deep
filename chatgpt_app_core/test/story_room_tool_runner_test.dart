import 'package:chatgpt_app_core/chat/application/story_room_tool_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late HiDBManager storage;
  late _RecordingChatService chatService;
  late StoryRoomToolRunner runner;

  setUp(() async {
    storage = HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
    );
    chatService = _RecordingChatService();
    runner = StoryRoomToolRunner(
      openStorage: () async => storage,
      chatServiceFactory: (_) => chatService,
    );
  });

  tearDown(() => storage.db.close());

  Future<int> saveAssistant({
    required List<String> toolIds,
    bool useTools = true,
  }) async {
    final dao = await AssistantDao.create(storage);
    return (await dao.saveAssistant(AssistantModel(
      name: '角色',
      prompt: '保持角色口吻。',
      useTools: useTools,
      toolIds: toolIds,
    )))!;
  }

  Future<void> runFor(int? assistantId, {AISettings? settings}) async {
    await runner
        .run(
          speakerAssistantId: assistantId,
          settings: settings ?? AISettings.defaults(),
          history: const [
            {'role': 'assistant', 'content': '前情'},
          ],
          prompt: '继续故事',
        )
        .toList();
  }

  test('绑定 knowledge_search 时注册 RAG 工具且保留房间上下文', () async {
    final assistantId = await saveAssistant(
      toolIds: const [ToolRegistry.knowledgeSearchId],
    );

    await runFor(assistantId);

    expect(chatService.lastTools, isNotNull);
    expect(_toolNames(chatService.lastTools), contains('knowledge_search'));
    expect(chatService.lastHistory!.single['content'], '前情');
    final tables = await storage.db.rawQuery(
      "select name from sqlite_master where type = 'table' and name = 'tb_kb_doc'",
    );
    expect(tables, isNotEmpty);
  });

  test('绑定 web_search 时仅在已配置搜索 key 后注册', () async {
    final assistantId = await saveAssistant(
      toolIds: const [ToolRegistry.webSearchId],
    );
    final settings = AISettings.defaults()..tavilyApiKey = 'tvly-test';

    await runFor(assistantId, settings: settings);

    expect(_toolNames(chatService.lastTools), contains('web_search'));
  });

  test('房间联网开关可在助手未显式绑定时强制注册 web_search', () async {
    final assistantId = await saveAssistant(toolIds: const []);
    final settings = AISettings.defaults()..tavilyApiKey = 'tvly-test';

    await runner
        .run(
          speakerAssistantId: assistantId,
          settings: settings,
          history: const [],
          prompt: '最新消息',
          forceWebSearch: true,
        )
        .toList();

    expect(_toolNames(chatService.lastTools), contains('web_search'));
  });

  test('仅注册助手绑定的 MCP 工具', () async {
    final assistantId = await saveAssistant(toolIds: const ['mcp__room__roll']);
    var discovered = false;
    runner = StoryRoomToolRunner(
      openStorage: () async => storage,
      chatServiceFactory: (_) => chatService,
      mcpDiscover: (_, {confirm, projectId}) async {
        discovered = true;
        return [
          ChatTool(
            name: 'mcp__room__roll',
            description: '掷骰',
            parameters: const {'type': 'object'},
            execute: (_) async => const ToolOutcome(content: '4'),
          ),
          ChatTool(
            name: 'mcp__room__unbound',
            description: '未绑定',
            parameters: const {'type': 'object'},
            execute: (_) async => const ToolOutcome(content: 'ignored'),
          ),
        ];
      },
    );
    final settings = AISettings.defaults()..mcpBackendEnabled = true;

    await runFor(assistantId, settings: settings);

    expect(discovered, isTrue);
    expect(_toolNames(chatService.lastTools), contains('mcp__room__roll'));
    expect(_toolNames(chatService.lastTools),
        isNot(contains('mcp__room__unbound')));
  });

  test('未绑定助手时安全退化为普通 ChatService 流', () async {
    var discovered = false;
    runner = StoryRoomToolRunner(
      openStorage: () async => storage,
      chatServiceFactory: (_) => chatService,
      mcpDiscover: (_, {confirm, projectId}) async {
        discovered = true;
        return const [];
      },
    );

    final events = await runner
        .run(
          speakerAssistantId: null,
          settings: AISettings.defaults()..mcpBackendEnabled = true,
          history: const [],
          prompt: '普通回复',
        )
        .toList();

    expect(events.single.delta, '普通回复');
    expect(chatService.lastTools, isNull);
    expect(discovered, isFalse);
  });

  test('未绑定助手时房间联网只授权 web_search', () async {
    final settings = AISettings.defaults()..tavilyApiKey = 'tvly-test';

    await runner
        .run(
          speakerAssistantId: null,
          settings: settings,
          history: const [],
          prompt: '最新消息',
          forceWebSearch: true,
        )
        .toList();

    expect(_toolNames(chatService.lastTools), [ToolRegistry.webSearchId]);
  });
}

Iterable<String> _toolNames(List<Map<String, dynamic>>? tools) => [
      for (final tool in tools ?? const <Map<String, dynamic>>[])
        ((tool['function'] as Map<String, dynamic>)['name'] as String),
    ];

class _RecordingChatService implements ChatService {
  List<Map<String, dynamic>>? lastTools;
  List<Map<String, dynamic>>? lastHistory;

  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) async =>
      null;

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async =>
      const ChatCompletionResult(content: null, estimated: true);

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      const Stream.empty();

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) async* {
    lastTools = tools;
    lastHistory = history;
    yield StreamEvent.text(prompt);
  }
}
