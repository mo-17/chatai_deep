import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/tool_call_accumulator.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// 阶段六验收的可执行版本：工具调用 Tool Calling（指南 §7）。
/// 覆盖核心不变量：
/// - ToolCallAccumulator：arguments 分片累积、多 index 并行调用、坏 JSON 降级；
/// - ToolRegistry：function 声明形状、未注册/执行抛错转文本回灌（不中断会话）、
///   联网搜索工具复用 WebSearchProvider 且带出 webResults；
/// - ToolLoopRunner 端到端：toolCall → 执行 → role:tool 回灌 → 续写正文 →
///   citation 收尾；轮次上限（最后一轮不带 tools，强制终止）；
/// - StreamDispatcher：onToolCall 收尾正文块（text→tool→text 按序成块）、
///   onToolResult 按 toolId 填结果置 success —— 验收「ToolBlock 出现，调用完继续正文」。
void main() {
  group('ToolCallAccumulator 分片累积', () {
    test('id/name 首片到达，arguments 分片拼接成完整 JSON', () {
      final acc = ToolCallAccumulator();
      acc.feed(index: 0, id: 'call_1', name: 'web_search', argsDelta: '{"qu');
      acc.feed(index: 0, argsDelta: 'ery": "今日');
      acc.feed(index: 0, argsDelta: '新闻"}');
      final events = acc.flush();
      expect(events, hasLength(1));
      expect(events.single.type, StreamEventType.toolCall);
      expect(events.single.toolId, 'call_1');
      expect(events.single.toolName, 'web_search');
      expect(events.single.toolArguments, {'query': '今日新闻'});
    });

    test('多 index 并行调用按 index 排序输出', () {
      final acc = ToolCallAccumulator();
      acc.feed(index: 1, id: 'call_b', name: 'tool_b', argsDelta: '{}');
      acc.feed(index: 0, id: 'call_a', name: 'tool_a', argsDelta: '{}');
      final events = acc.flush();
      expect(events.map((e) => e.toolId), ['call_a', 'call_b']);
    });

    test('arguments 不是合法 JSON -> 降级为空 map；缺 id -> tool_<index>', () {
      final acc = ToolCallAccumulator();
      acc.feed(index: 0, name: 'broken', argsDelta: '{"q": ');
      final events = acc.flush();
      expect(events.single.toolArguments, isEmpty);
      expect(events.single.toolId, 'tool_0');
    });

    test('flush 后状态清空', () {
      final acc = ToolCallAccumulator();
      acc.feed(index: 0, id: 'x', name: 'y');
      acc.flush();
      expect(acc.isEmpty, isTrue);
      expect(acc.flush(), isEmpty);
    });
  });

  group('ToolRegistry', () {
    test('declarations 是 OpenAI function 形状', () {
      final reg = ToolRegistry([_echoTool()]);
      final d = reg.declarations.single;
      expect(d['type'], 'function');
      final fn = d['function'] as Map<String, dynamic>;
      expect(fn['name'], 'echo');
      expect(fn['parameters'], isA<Map<String, dynamic>>());
    });

    test('未注册的工具 -> 错误文本回灌（不抛）', () async {
      const reg = ToolRegistry([]);
      final out = await reg.execute('nope', const {});
      expect(out.content, contains('未注册'));
    });

    test('工具执行抛错 -> 失败文本回灌（不中断会话）', () async {
      final reg = ToolRegistry([
        ChatTool(
          name: 'boom',
          description: '',
          parameters: const {'type': 'object'},
          execute: (_) async => throw Exception('网络挂了'),
        ),
      ]);
      final out = await reg.execute('boom', const {});
      expect(out.content, contains('执行失败'));
    });

    test('工具执行抛错可按策略重试，并返回最终成功结果', () async {
      var calls = 0;
      final reg = ToolRegistry(
        [
          ChatTool(
            name: 'flaky',
            description: '',
            parameters: const {'type': 'object'},
            execute: (_) async {
              calls++;
              if (calls == 1) throw Exception('临时失败');
              return const ToolOutcome(content: 'ok');
            },
          ),
        ],
        retryPolicy: const ToolRetryPolicy(maxAttempts: 2),
      );

      final out = await reg.execute('flaky', const {});

      expect(out.content, 'ok');
      expect(calls, 2);
    });

    test('工具返回错误文本不会触发重试', () async {
      var calls = 0;
      final reg = ToolRegistry(
        [
          ChatTool(
            name: 'soft_error',
            description: '',
            parameters: const {'type': 'object'},
            execute: (_) async {
              calls++;
              return const ToolOutcome(content: '错误：缺少参数');
            },
          ),
        ],
        retryPolicy: const ToolRetryPolicy(maxAttempts: 3),
      );

      final out = await reg.execute('soft_error', const {});

      expect(out.content, contains('缺少参数'));
      expect(calls, 1);
    });

    test('联网搜索工具：结果回灌带编号 JSON，webResults 带出供 citation', () async {
      final tool = ToolRegistry.webSearchTool(_FakeSearchProvider({
        '北京 天气': [
          const WebSearchResult(
              title: 'T', url: 'https://w.com', content: 'sunny'),
        ],
      }));
      final out = await tool.execute({'query': '北京 天气'});
      final decoded = jsonDecode(out.content) as List;
      expect((decoded.single as Map)['index'], 1);
      expect((decoded.single as Map)['url'], 'https://w.com');
      expect(out.webResults.single.url, 'https://w.com');
    });

    test('联网搜索工具：缺 query -> 错误文本', () async {
      final tool = ToolRegistry.webSearchTool(_FakeSearchProvider({}));
      final out = await tool.execute(const {});
      expect(out.content, contains('缺少 query'));
      expect(out.webResults, isEmpty);
    });

    test('fromSettings：未配搜索 key -> 空注册表；配了 -> 有 web_search', () {
      final s = AISettings.defaults();
      expect(ToolRegistry.fromSettings(s).isEmpty, isTrue);
      s.tavilyApiKey = 'tvly-x';
      expect(ToolRegistry.fromSettings(s).byName('web_search'), isNotNull);
    });

    test('fromAssistant：动态工具默认启用一次失败重试', () async {
      var calls = 0;
      final reg = ToolRegistry.fromAssistant(
        AISettings.defaults(),
        const [],
        extraTools: [
          ChatTool(
            name: 'mcp_flaky',
            description: '',
            parameters: const {'type': 'object'},
            execute: (_) async {
              calls++;
              if (calls == 1) throw Exception('MCP timeout');
              return const ToolOutcome(content: 'done');
            },
          ),
        ],
      );

      final out = await reg.execute('mcp_flaky', const {});

      expect(out.content, 'done');
      expect(calls, 2);
    });
  });

  group('ToolLoopRunner 执行回路', () {
    test('toolCall -> 执行 -> 回灌 -> 续写正文 -> citation 收尾（验收主链路）', () async {
      final service = _ScriptedChatService([
        // 第 1 轮：模型决定调用 web_search
        [
          StreamEvent.text('我来查一下。'),
          StreamEvent.toolCall(
              toolId: 'call_1',
              name: 'web_search',
              arguments: {'query': '今日新闻'}),
        ],
        // 第 2 轮：模型基于工具结果续写正文
        [StreamEvent.text('根据搜索结果，今天… [1]')],
      ]);
      final registry = ToolRegistry([
        ChatTool(
          name: 'web_search',
          description: '',
          parameters: const {'type': 'object'},
          execute: (args) async => const ToolOutcome(
            content: 'X',
            webResults: [WebSearchResult(title: 'N', url: 'https://n.com')],
          ),
        ),
      ]);
      final events =
          await ToolLoopRunner(chatService: service, registry: registry)
              .run(prompt: '今天的新闻', history: const []).toList();

      // 事件顺序：正文 → toolCall → toolResult → 续写正文 → citation。
      expect(events.map((e) => e.type), [
        StreamEventType.text,
        StreamEventType.toolCall,
        StreamEventType.toolResult,
        StreamEventType.text,
        StreamEventType.citation,
      ]);
      expect(events[2].toolId, 'call_1');
      expect(events[2].toolContent, 'X');
      expect(events[4].webResults!.single.url, 'https://n.com');

      // 第 2 轮请求回灌：assistant(tool_calls，arguments 为 JSON 字符串) + role:tool。
      expect(service.capturedExtra, hasLength(2));
      expect(service.capturedExtra[0], isEmpty);
      final extra = service.capturedExtra[1];
      expect(extra[0]['role'], 'assistant');
      expect(extra[0]['content'], '我来查一下。');
      final toolCalls = extra[0]['tool_calls'] as List;
      expect(((toolCalls.single as Map)['function'] as Map)['arguments'],
          jsonEncode({'query': '今日新闻'}));
      expect(extra[1]['role'], 'tool');
      expect(extra[1]['tool_call_id'], 'call_1');
      expect(extra[1]['content'], 'X');
      // 两轮都带 tools 声明（未到上限）。
      expect(service.capturedTools[0], isNotNull);
      expect(service.capturedTools[1], isNotNull);
    });

    test('模型不调用工具 -> 单轮直出正文，无 citation', () async {
      final service = _ScriptedChatService([
        [StreamEvent.text('1+1=2')],
      ]);
      final events = await ToolLoopRunner(
              chatService: service, registry: ToolRegistry([_echoTool()]))
          .run(prompt: '1+1', history: const []).toList();
      expect(events.map((e) => e.type), [StreamEventType.text]);
      expect(service.capturedTools, hasLength(1));
    });

    test('流式 usage 事件穿透工具循环，供会话收尾记录真实 token', () async {
      final service = _ScriptedChatService([
        [
          StreamEvent.text('完成'),
          StreamEvent.usage(promptTokens: 12, completionTokens: 8),
        ],
      ]);

      final events = await ToolLoopRunner(
              chatService: service, registry: ToolRegistry([_echoTool()]))
          .run(prompt: 'q', history: const []).toList();

      expect(events.map((e) => e.type),
          [StreamEventType.text, StreamEventType.usage]);
      expect(events.last.promptTokens, 12);
      expect(events.last.completionTokens, 8);
    });

    test('轮次上限：收尾轮不带 tools 强制作答，绝不无限循环', () async {
      // 恶意脚本：只要带了 tools 就一直发起调用。
      final service = _ScriptedChatService.loop((tools) => [
            if (tools != null)
              StreamEvent.toolCall(toolId: 'c', name: 'echo', arguments: {})
            else
              StreamEvent.text('好吧，直接回答。'),
          ]);
      final events = await ToolLoopRunner(
              chatService: service, registry: ToolRegistry([_echoTool()]))
          .run(prompt: 'q', history: const []).toList();
      // 共 maxRounds 轮带 tools + 1 轮收尾不带 tools。
      expect(service.capturedTools, hasLength(ToolLoopRunner.maxRounds + 1));
      expect(service.capturedTools.last, isNull);
      expect(events.last.type, StreamEventType.text);
    });
  });

  group('StreamDispatcher 工具块', () {
    test('text→tool→text 按到达顺序成块；onToolResult 填结果置 success', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, 'msg_t1')..start();
      d.onTextChunk('我来查一下。');
      d.onToolCall(toolId: 'call_1', name: 'web_search', args: {'query': 'q'});
      d.onToolResult(toolId: 'call_1', content: 'X');
      d.onTextChunk('查到了。');
      d.finish();

      final blocks = store.blocksFor('msg_t1');
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<MainTextBlock>());
      expect(blocks[0].status, MessageBlockStatus.success); // 工具到达即收尾
      final tool = blocks[1] as ToolBlock;
      expect(tool.status, MessageBlockStatus.success);
      expect(tool.content, 'X');
      expect((blocks[2] as MainTextBlock).content, '查到了。');
      // 验收：调用完继续正文 —— mainText 聚合两段正文。
      expect(d.mainText, '我来查一下。查到了。');
    });

    test('占位块直接变身 ToolBlock（一个字都没说就调用工具）', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, 'msg_t2')..start();
      d.onToolCall(toolId: 'call_1', name: 'echo');
      final blocks = store.blocksFor('msg_t2');
      expect(blocks.single, isA<ToolBlock>());
      expect(blocks.single.status, MessageBlockStatus.processing);
    });

    test('onToolResult 找不到匹配 toolId 时静默忽略', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, 'msg_t3')..start();
      d.onToolResult(toolId: 'ghost', content: 'X'); // 不抛
      d.finish();
      expect(store.blocksFor('msg_t3'), isEmpty);
    });
  });
}

ChatTool _echoTool() => ChatTool(
      name: 'echo',
      description: 'echo',
      parameters: const {'type': 'object', 'properties': {}},
      execute: (args) async => ToolOutcome(content: jsonEncode(args)),
    );

/// 假搜索服务商（与 web_search_test 同款，独立副本避免测试间耦合）。
class _FakeSearchProvider extends WebSearchProvider {
  final Map<String, List<WebSearchResult>> data;
  _FakeSearchProvider(this.data) : super(apiKey: 'fake');

  @override
  Future<List<WebSearchResult>> search(String query) async =>
      data[query] ?? const [];
}

/// 按轮次出预置事件的假会话服务，记录每轮收到的 tools / extraMessages。
class _ScriptedChatService implements ChatService {
  final List<List<StreamEvent>>? rounds;
  final List<StreamEvent> Function(List<Map<String, dynamic>>? tools)? script;
  final capturedTools = <List<Map<String, dynamic>>?>[];
  final capturedExtra = <List<Map<String, dynamic>>>[];
  int _round = 0;

  _ScriptedChatService(this.rounds) : script = null;

  /// 按「本轮是否带 tools」动态出事件（测轮次上限用）。
  _ScriptedChatService.loop(this.script) : rounds = null;

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
    capturedTools.add(tools);
    capturedExtra.add(List.of(extraMessages));
    final events = script != null
        ? script!(tools)
        : rounds![_round < rounds!.length ? _round : rounds!.length - 1];
    _round++;
    for (final e in events) {
      yield e;
    }
  }
}
