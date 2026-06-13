import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 多服务商联网搜索（对照源项目 Tavily/Exa/Bocha/Zhipu Provider）+
/// 三项通用配置（searchWithTime / maxResults / contentLimit）+
/// 最大输出 token 设置的验收测试。
void main() {
  group('AISettings 新字段', () {
    test('toJson/fromJson 往返（搜索配置 + maxOutputTokens）', () {
      final s = AISettings.defaults()
        ..webSearchProviderId = 'bocha'
        ..exaApiKey = 'ek'
        ..bochaApiKey = 'bk'
        ..zhipuApiKey = 'zk'
        ..searchWithTime = false
        ..searchMaxResults = 8
        ..searchContentLimit = 0
        ..maxOutputTokens = 4096;
      final r = AISettings.fromJson(s.toJson());
      expect(r.webSearchProviderId, 'bocha');
      expect(r.exaApiKey, 'ek');
      expect(r.bochaApiKey, 'bk');
      expect(r.zhipuApiKey, 'zk');
      expect(r.searchWithTime, isFalse);
      expect(r.searchMaxResults, 8);
      expect(r.searchContentLimit, 0);
      expect(r.maxOutputTokens, 4096);
    });

    test('缺省值：maxOutputTokens=0（不限制）、tavily、searchWithTime 开', () {
      final s = AISettings.fromJson({});
      expect(s.maxOutputTokens, 0);
      expect(s.webSearchProviderId, 'tavily');
      expect(s.searchWithTime, isTrue);
      expect(s.searchMaxResults, 5);
      expect(s.searchContentLimit, 2000);
    });

    test('activeSearchApiKey / webSearchConfigured 跟随所选服务商', () {
      final s = AISettings.defaults()
        ..tavilyApiKey = 'tk'
        ..webSearchProviderId = 'exa';
      expect(s.activeSearchApiKey, '');
      expect(s.webSearchConfigured, isFalse, reason: 'Exa 没配 key，即使 Tavily 有');
      s.exaApiKey = 'ek';
      expect(s.activeSearchApiKey, 'ek');
      expect(s.webSearchConfigured, isTrue);
    });
  });

  group('WebSearchProvider.fromSettings 分流', () {
    test('按 webSearchProviderId 创建对应实现，key 未配置返回 null', () {
      final s = AISettings.defaults();
      expect(WebSearchProvider.fromSettings(s), isNull);

      s.tavilyApiKey = 'tk';
      expect(WebSearchProvider.fromSettings(s), isA<TavilyWebSearchProvider>());

      s.webSearchProviderId = 'exa';
      expect(WebSearchProvider.fromSettings(s), isNull);
      s.exaApiKey = 'ek';
      expect(WebSearchProvider.fromSettings(s), isA<ExaWebSearchProvider>());

      s.webSearchProviderId = 'bocha';
      s.bochaApiKey = 'bk';
      expect(WebSearchProvider.fromSettings(s), isA<BochaWebSearchProvider>());

      s.webSearchProviderId = 'zhipu';
      s.zhipuApiKey = 'zk';
      expect(WebSearchProvider.fromSettings(s), isA<ZhipuWebSearchProvider>());
    });

    test('通用配置透传到 provider.options', () {
      final s = AISettings.defaults()
        ..tavilyApiKey = 'tk'
        ..searchWithTime = false
        ..searchMaxResults = 7
        ..searchContentLimit = 300;
      final p = WebSearchProvider.fromSettings(s)!;
      expect(p.options.searchWithTime, isFalse);
      expect(p.options.maxResults, 7);
      expect(p.options.contentLimit, 300);
    });
  });

  group('searchWithTime（查询词附带日期）', () {
    test('开启时 Tavily 的 query 带 today is 前缀，关闭时原样', () async {
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'results': []}), 200);
      });
      await TavilyWebSearchProvider(
        apiKey: 'k',
        options: const WebSearchOptions(searchWithTime: true),
        clientFactory: () => client,
      ).search('明天天气');
      expect(body['query'], startsWith('today is '));
      expect(body['query'], contains('明天天气'));

      await TavilyWebSearchProvider(
        apiKey: 'k',
        options: const WebSearchOptions(searchWithTime: false),
        clientFactory: () => client,
      ).search('明天天气');
      expect(body['query'], '明天天气');
    });
  });

  group('ExaWebSearchProvider', () {
    test('x-api-key 鉴权，numResults/text 请求体，解析 text 字段', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
            jsonEncode({
              'autopromptString': 'rewritten',
              'results': [
                {'title': 'E1', 'url': 'https://e.com', 'text': 'body' * 100},
              ],
            }),
            200);
      });
      final results = await ExaWebSearchProvider(
        apiKey: 'exa-key',
        options: const WebSearchOptions(
            searchWithTime: false, maxResults: 4, contentLimit: 10),
        clientFactory: () => client,
      ).search('q');
      expect(captured.headers['x-api-key'], 'exa-key');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['numResults'], 4);
      expect(body['text'], isTrue);
      expect(results.single.title, 'E1');
      expect(results.single.content.length, 10, reason: 'contentLimit 截断');
    });
  });

  group('BochaWebSearchProvider', () {
    test('Bearer 鉴权，freshness 随 searchWithTime，解析 webPages.value', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'queryContext': {'originalQuery': 'q'},
                'webPages': {
                  'value': [
                    {
                      'name': 'B1',
                      'url': 'https://b.com',
                      'summary': 'sum',
                      'snippet': 'snip',
                    },
                    {'name': 'B2', 'url': 'https://b2.com', 'snippet': 'snip2'},
                  ],
                },
              },
            }),
            200);
      });
      final results = await BochaWebSearchProvider(
        apiKey: 'bocha-key',
        options: const WebSearchOptions(searchWithTime: true, maxResults: 6),
        clientFactory: () => client,
      ).search('q');
      expect(captured.headers['Authorization'], 'Bearer bocha-key');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['count'], 6);
      expect(body['freshness'], 'oneDay', reason: 'searchWithTime 开启');
      expect(body['summary'], isTrue);
      expect(results, hasLength(2));
      expect(results.first.content, 'sum', reason: 'summary 优先于 snippet');
      expect(results.last.content, 'snip2');
    });

    test('code != 200 抛业务错误', () {
      final client = MockClient((_) async => http.Response(
          jsonEncode({'code': 403, 'msg': 'quota exceeded'}), 200));
      final p = BochaWebSearchProvider(
          apiKey: 'k',
          options: const WebSearchOptions(searchWithTime: false),
          clientFactory: () => client);
      expect(p.search('q'), throwsException);
    });
  });

  group('ZhipuWebSearchProvider', () {
    test('search_query/search_std 请求体，解析 search_result 的 link 字段', () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
            jsonEncode({
              'search_result': [
                {'title': 'Z1', 'link': 'https://z.com', 'content': 'c1'},
                {'title': 'Z2', 'link': 'https://z2.com', 'content': 'c2'},
                {'title': 'Z3', 'link': 'https://z3.com', 'content': 'c3'},
              ],
            }),
            200);
      });
      final results = await ZhipuWebSearchProvider(
        apiKey: 'zhipu-key',
        options: const WebSearchOptions(searchWithTime: false, maxResults: 2),
        clientFactory: () => client,
      ).search('q');
      expect(captured.headers['Authorization'], 'Bearer zhipu-key');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['search_query'], 'q');
      expect(body['search_engine'], 'search_std');
      expect(results, hasLength(2), reason: 'maxResults 客户端截断');
      expect(results.first.url, 'https://z.com');
    });
  });
}
