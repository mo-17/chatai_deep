import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/search_orchestrator.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/ui/block_message_content.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 阶段五验收的可执行版本：智能联网搜索 / 意图编排（指南 §6）。
/// 覆盖核心不变量：
/// - 意图识别 JSON 解析的容错与 fallback（失败直接用原问题搜）；
/// - Tavily Provider：请求体、结果解析、contentLimit 截断、非 200 抛错；
/// - 多 query 并行聚合：URL 去重、单 query 失败不拖垮整体、总数截断；
/// - 编排端到端：需要搜→出结果；不需要搜→不触发 provider（验收第 3 条）；
/// - StreamDispatcher.onCitation：citation 事件 -> success 态 CitationBlock，
///   且块落在正文之后（消息底部）；
/// - AISettings 新字段 JSON 往返。
void main() {
  group('SearchIntent.parse 容错', () {
    test('标准 JSON：needSearch + queries', () {
      final i = SearchIntent.parse(
          '{"needSearch": true, "queries": ["今日新闻", "2026-06-12 时事"]}',
          fallbackQuery: 'q');
      expect(i.needSearch, isTrue);
      expect(i.queries, ['今日新闻', '2026-06-12 时事']);
    });

    test('代码围栏 / 前后混杂说明文字也能取出 JSON', () {
      final i = SearchIntent.parse(
          '好的，分析如下：\n```json\n{"needSearch": true, "queries": ["天气 北京"]}\n```\n以上。',
          fallbackQuery: 'q');
      expect(i.needSearch, isTrue);
      expect(i.queries, ['天气 北京']);
    });

    test('needSearch=false -> 不搜（验收：不需要搜的问题不触发）', () {
      final i = SearchIntent.parse('{"needSearch": false, "queries": []}',
          fallbackQuery: 'q');
      expect(i.needSearch, isFalse);
      expect(i.queries, isEmpty);
    });

    test('needSearch=true 但 queries 为空 -> 回退用原问题', () {
      final i = SearchIntent.parse('{"needSearch": true, "queries": []}',
          fallbackQuery: '今天的新闻');
      expect(i.queries, ['今天的新闻']);
    });

    test('完全不是 JSON -> fallback 直接搜原问题', () {
      final i = SearchIntent.parse('我觉得需要搜索', fallbackQuery: '今天的新闻');
      expect(i.needSearch, isTrue);
      expect(i.queries, ['今天的新闻']);
    });
  });

  group('TavilyWebSearchProvider', () {
    TavilyWebSearchProvider buildProvider(MockClient client,
            {WebSearchOptions options =
                const WebSearchOptions(searchWithTime: false)}) =>
        TavilyWebSearchProvider(
            apiKey: 'tvly-key', options: options, clientFactory: () => client);

    test('请求体带 query/max_results，Bearer 鉴权，解析 results', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
            jsonEncode({
              'results': [
                {'title': 'T1', 'url': 'https://a.com', 'content': 'C1'},
                {'title': 'T2', 'url': 'https://b.com', 'content': 'C2'},
              ]
            }),
            200,
            headers: {'content-type': 'application/json'});
      });
      final results = await buildProvider(client,
              options:
                  const WebSearchOptions(searchWithTime: false, maxResults: 3))
          .search('今日新闻');
      expect(captured.headers['Authorization'], 'Bearer tvly-key');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['query'], '今日新闻');
      expect(body['max_results'], 3);
      expect(results, hasLength(2));
      expect(results.first.title, 'T1');
      expect(results.first.url, 'https://a.com');
    });

    test('contentLimit 截断每条正文摘要', () async {
      final client = MockClient((_) async => http.Response(
          jsonEncode({
            'results': [
              {'title': 'T', 'url': 'https://a.com', 'content': 'x' * 100},
            ]
          }),
          200));
      final results = await buildProvider(client,
              options: const WebSearchOptions(
                  searchWithTime: false, contentLimit: 10))
          .search('q');
      expect(results.single.content.length, 10);
    });

    test('非 200 抛错（由编排层吞掉降级）', () {
      final client =
          MockClient((_) async => http.Response('unauthorized', 401));
      expect(buildProvider(client).search('q'), throwsException);
    });
  });

  group('SearchOrchestrator.searchAll 并行聚合', () {
    test('URL 去重合并；单 query 失败不影响其它', () async {
      final provider = _FakeSearchProvider({
        'q1': [
          const WebSearchResult(title: 'A', url: 'https://a.com'),
          const WebSearchResult(title: 'B', url: 'https://b.com'),
        ],
        'q2': [
          const WebSearchResult(title: 'A2', url: 'https://a.com'), // 重复 URL
          const WebSearchResult(title: 'C', url: 'https://c.com'),
        ],
      }, throwOn: {
        'q3'
      });
      final o = SearchOrchestrator(
          chatService: _FakeChatService((_) async => ''), provider: provider);
      final merged = await o.searchAll(['q1', 'q2', 'q3']);
      expect(merged.map((r) => r.url),
          ['https://a.com', 'https://b.com', 'https://c.com']);
    });

    test('合并总数截到 maxTotalResults', () async {
      final provider = _FakeSearchProvider({
        'q': [
          for (var i = 0; i < 20; i++)
            WebSearchResult(title: '$i', url: 'https://s$i.com'),
        ],
      });
      final o = SearchOrchestrator(
          chatService: _FakeChatService((_) async => ''), provider: provider);
      final merged = await o.searchAll(['q']);
      expect(merged, hasLength(SearchOrchestrator.maxTotalResults));
    });
  });

  group('SearchOrchestrator.run 端到端', () {
    test('意图说要搜 -> 用改写后的 query 搜出结果', () async {
      final provider = _FakeSearchProvider({
        '2026-06-12 新闻': [
          const WebSearchResult(title: 'N', url: 'https://news.com'),
        ],
      });
      final chat = _FakeChatService(
          (_) async => '{"needSearch": true, "queries": ["2026-06-12 新闻"]}');
      final o = SearchOrchestrator(chatService: chat, provider: provider);
      final results = await o.run(prompt: '今天的新闻', history: const []);
      expect(results.single.url, 'https://news.com');
    });

    test('意图说不用搜 -> 不触发 provider（验收第 3 条）', () async {
      final provider = _FakeSearchProvider({});
      final chat =
          _FakeChatService((_) async => '{"needSearch": false, "queries": []}');
      final o = SearchOrchestrator(chatService: chat, provider: provider);
      final results = await o.run(prompt: '1+1 等于几', history: const []);
      expect(results, isEmpty);
      expect(provider.calls, isEmpty);
    });

    test('意图调用抛错 -> fallback 直接用原问题搜', () async {
      final provider = _FakeSearchProvider({
        '今天的新闻': [const WebSearchResult(title: 'N', url: 'https://n.com')],
      });
      final chat = _FakeChatService((_) async => throw Exception('network'));
      final o = SearchOrchestrator(chatService: chat, provider: provider);
      final results = await o.run(prompt: '今天的新闻', history: const []);
      expect(provider.calls, ['今天的新闻']);
      expect(results, hasLength(1));
    });

    test('意图识别历史压成纯文本（多模态 content 只取 text 部分）', () {
      final history = [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '这是图里的问题'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,xxx'}
            },
          ],
        },
        {'role': 'assistant', 'content': '回答'},
      ];
      final out = SearchOrchestrator.recentTextHistory(history);
      expect(out[0]['content'], '这是图里的问题');
      expect(out[1]['content'], '回答');
    });
  });

  group('回填与块化展示', () {
    test('buildSearchContext 含编号 / 来源 URL / 引用指引', () {
      final ctx = SearchOrchestrator.buildSearchContext(const [
        WebSearchResult(title: 'T1', url: 'https://a.com', content: 'C1'),
        WebSearchResult(title: 'T2', url: 'https://b.com', content: 'C2'),
      ]);
      expect(ctx, contains('[1] T1'));
      expect(ctx, contains('来源：https://a.com'));
      expect(ctx, contains('[2] T2'));
      expect(ctx, contains('[编号]'));
      // 回填上下文须锚定今天日期，否则主 LLM 用训练截止日期理解时效问题。
      expect(ctx, contains('今天的日期是 ${SearchOrchestrator.today()}'));
    });

    test('搜索上下文走 extraText 通路，拼在当前轮 prompt 之后', () {
      final atts = const ChatAttachments().withExtraText('搜索结果上下文');
      final content = atts.buildUserContent('今天的新闻') as List;
      expect((content.first as Map)['text'], '今天的新闻\n\n搜索结果上下文');
    });

    test('onCitation：citation 事件 -> success 态 CitationBlock，且在正文之后', () {
      final store = ChatBlockStore();
      final dispatcher = StreamDispatcher(store, 'msg_1')..start();
      dispatcher.onTextChunk('正文');
      dispatcher.onCitation(const [
        WebSearchResult(title: 'T', url: 'https://a.com', content: 'C'),
      ]);
      dispatcher.finish();
      final blocks = store.blocksFor('msg_1');
      expect(blocks, hasLength(2));
      expect(blocks[0], isA<MainTextBlock>());
      final cite = blocks[1] as CitationBlock;
      expect(cite.status, MessageBlockStatus.success);
      expect(cite.webResults.single.url, 'https://a.com');
    });

    test('onCitation 空结果不建块', () {
      final store = ChatBlockStore();
      final dispatcher = StreamDispatcher(store, 'msg_2')..start();
      dispatcher.onTextChunk('正文');
      dispatcher.onCitation(const []);
      dispatcher.finish();
      expect(store.blocksFor('msg_2'), hasLength(1));
    });

    test('CitationBlock JSON 往返（落库恢复后来源仍可点）', () {
      const block = CitationBlock(
        id: 'b1',
        messageId: 'msg_3',
        createdAt: 1,
        status: MessageBlockStatus.success,
        webResults: [
          WebSearchResult(title: 'T', url: 'https://a.com', content: 'C'),
        ],
      );
      final restored = MessageBlock.decodeList(MessageBlock.encodeList([block]))
          .single as CitationBlock;
      expect(restored.webResults.single.title, 'T');
      expect(restored.webResults.single.url, 'https://a.com');
    });

    test('正文 [n] 标记按来源列表分段，并只让有效来源可点击', () {
      final segments = parseCitationTextSegments(
        content: '参考 [1] 和 [2]，无效 [3] 保持普通文本。',
        webResults: const [
          WebSearchResult(title: 'A', url: 'https://a.com', content: 'A'),
          WebSearchResult(title: 'B', url: '', content: 'B'),
        ],
      );

      expect(segments.map((e) => e.text), [
        '参考 ',
        '[1]',
        ' 和 ',
        '[2]',
        '，无效 ',
        '[3]',
        ' 保持普通文本。',
      ]);
      expect(segments[1].citationIndex, 1);
      expect(segments[1].url, 'https://a.com');
      expect(segments[3].citationIndex, 2);
      expect(segments[3].url, isNull);
      expect(segments[5].citationIndex, 3);
      expect(segments[5].url, isNull);
    });
  });

  group('AISettings 联网搜索字段', () {
    test('JSON 往返 + 默认值', () {
      final s = AISettings.defaults();
      expect(s.tavilyApiKey, isEmpty);
      expect(s.webSearchEnabled, isFalse);
      s.tavilyApiKey = 'tvly-x';
      s.webSearchEnabled = true;
      final restored = AISettings.fromJson(s.toJson());
      expect(restored.tavilyApiKey, 'tvly-x');
      expect(restored.webSearchEnabled, isTrue);
    });

    test('工厂：未配置 key 返回 null，配置后返回 Tavily', () {
      final s = AISettings.defaults();
      expect(WebSearchProvider.fromSettings(s), isNull);
      s.tavilyApiKey = 'tvly-x';
      expect(WebSearchProvider.fromSettings(s), isA<TavilyWebSearchProvider>());
    });

    test('clone 产生新实例且字段相等', () {
      final s = AISettings.defaults()..webSearchEnabled = true;
      final c = s.clone();
      expect(identical(s, c), isFalse);
      expect(c.webSearchEnabled, isTrue);
    });
  });
}

/// 假搜索服务商：按 query 返回预置结果，记录调用顺序，可指定抛错的 query。
class _FakeSearchProvider extends WebSearchProvider {
  final Map<String, List<WebSearchResult>> data;
  final Set<String> throwOn;
  final List<String> calls = [];

  _FakeSearchProvider(this.data, {this.throwOn = const {}})
      : super(apiKey: 'fake');

  @override
  Future<List<WebSearchResult>> search(String query) async {
    calls.add(query);
    if (throwOn.contains(query)) throw Exception('search failed');
    return data[query] ?? const [];
  }
}

/// 假会话服务：只实现意图识别用到的非流式 chat。
class _FakeChatService implements ChatService {
  final Future<String?> Function(String prompt) onChat;

  _FakeChatService(this.onChat);

  @override
  ModelCapabilities get capabilities => const ModelCapabilities.none();

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) =>
      onChat(prompt);

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async =>
      ChatCompletionResult(content: await onChat(prompt), estimated: true);

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
  }) =>
      const Stream.empty();
}
