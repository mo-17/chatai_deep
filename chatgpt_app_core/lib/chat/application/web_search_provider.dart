import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:http/http.dart' as http;
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';

/// 联网搜索通用配置。对照源项目 `WebSearchState` 的三项：
/// searchWithTime / maxResults / contentLimit，由「AI 服务设置」配置。
class WebSearchOptions {
  /// 是否在搜索词前附带当前日期（源项目：`today is YYYY-MM-DD \r\n query`）。
  final bool searchWithTime;

  /// 单次搜索返回条数。
  final int maxResults;

  /// 每条结果正文的字符上限，0 = 不限制。
  final int contentLimit;

  const WebSearchOptions({
    this.searchWithTime = true,
    this.maxResults = 5,
    this.contentLimit = 2000,
  });

  factory WebSearchOptions.fromSettings(AISettings s) => WebSearchOptions(
        searchWithTime: s.searchWithTime,
        maxResults: s.searchMaxResults.clamp(1, 20),
        contentLimit: s.searchContentLimit < 0 ? 0 : s.searchContentLimit,
      );
}

/// 网络搜索服务商抽象（阶段五）。对应源项目 `BaseWebSearchProvider`。
///
/// 沿用 DAO「接口 + 实现同文件」的写法：抽象基类 + 各实现 + 工厂都收在这里。
/// 服务商清单与源项目 `WebSearchProviderFactory` 实际启用的一致：
/// Tavily / Exa / Bocha / 智谱（searxng 与本地浏览器型源项目也未启用）。
abstract class WebSearchProvider {
  final String apiKey;
  final WebSearchOptions options;

  /// 可注入的 http client（测试用 MockClient），默认每次新建。
  final http.Client Function() clientFactory;

  WebSearchProvider({
    required this.apiKey,
    this.options = const WebSearchOptions(),
    http.Client Function()? clientFactory,
  }) : clientFactory = clientFactory ?? http.Client.new;

  /// 执行一次搜索。条数 / 正文截断取 [options]（maxResults / contentLimit）。
  Future<List<WebSearchResult>> search(String query);

  static final _requestZone = Object();
  Future<List<WebSearchResult>> searchWithOptions(String query,
      {ChatRequestOptions? options}) {
    if (options == null) return search(query);
    return runZoned(() async {
      await options.beforeAttachmentUpload?.call();
      await _check(options);
      final result = await _race(search(query), options);
      await _check(options);
      return result;
    }, zoneValues: {_requestZone: options});
  }

  static Future<void> _check(ChatRequestOptions? options) async {
    var aborted = false;
    options?.abortTrigger?.then<void>((_) => aborted = true,
        onError: (Object _, StackTrace __) => aborted = true);
    await Future<void>.value();
    if (aborted || options?.dispatchIsCurrent?.call() == false) _cancel();
  }

  static Never _cancel() => throw const ChatTransportException(
      safeCode: 'cancelled',
      safeMessage: '搜索已停止',
      failureKind: ChatFailureKind.cancelled);
  static Future<T> _race<T>(Future<T> work, ChatRequestOptions? options) =>
      options?.abortTrigger == null
          ? work
          : Future.any([
              work,
              options!.abortTrigger!.then<T>((_) => _cancel(),
                  onError: (Object _, StackTrace __) => _cancel())
            ]);

  /// 工厂：按用户设置创建当前所选服务商；其 key 未配置时返回 null
  /// （调用方据此判断联网搜索是否可用，而不是抛异常）。
  static WebSearchProvider? fromSettings(AISettings s) {
    final key = s.activeSearchApiKey;
    if (key.isEmpty) return null;
    final options = WebSearchOptions.fromSettings(s);
    switch (s.webSearchProviderId) {
      case 'exa':
        return ExaWebSearchProvider(apiKey: key, options: options);
      case 'bocha':
        return BochaWebSearchProvider(apiKey: key, options: options);
      case 'zhipu':
        return ZhipuWebSearchProvider(apiKey: key, options: options);
      default:
        return TavilyWebSearchProvider(apiKey: key, options: options);
    }
  }

  /// 应用 searchWithTime：在搜索词前附带今天的日期（与源项目同款前缀）。
  String prepareQuery(String query) {
    if (!options.searchWithTime) return query;
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}'
        '-${now.day.toString().padLeft(2, '0')}';
    return 'today is $today\n$query';
  }

  /// POST JSON 并解析响应体；非 200 抛带服务商名的异常。
  Future<Map<String, dynamic>> postJson(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    required String providerName,
  }) async {
    final request = Zone.current[_requestZone] as ChatRequestOptions?;
    await request?.beforeAttachmentUpload?.call();
    await _check(request);
    final client = clientFactory();
    var closed = false;
    request?.abortTrigger?.then<void>((_) {
      if (!closed) client.close();
    }, onError: (Object _, StackTrace __) {
      if (!closed) client.close();
    });
    try {
      final response = await _race(
          client
              .post(uri,
                  headers: {'Content-Type': 'application/json', ...headers},
                  body: jsonEncode(body))
              .timeout(const Duration(seconds: 15)),
          request);
      await _check(request);
      if (response.statusCode != 200) {
        throw Exception('$providerName 搜索失败(${response.statusCode})');
      }
      final text = const Utf8Decoder().convert(response.bodyBytes);
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      closed = true;
      client.close();
    }
  }

  String truncate(String s) {
    final limit = options.contentLimit;
    return (limit > 0 && s.length > limit) ? s.substring(0, limit) : s;
  }
}

/// Tavily（POST https://api.tavily.com/search，Bearer key）。
class TavilyWebSearchProvider extends WebSearchProvider {
  static const _endpoint = 'https://api.tavily.com/search';

  TavilyWebSearchProvider({
    required super.apiKey,
    super.options,
    super.clientFactory,
  });

  @override
  Future<List<WebSearchResult>> search(String query) async {
    final json = await postJson(
      Uri.parse(_endpoint),
      {'Authorization': 'Bearer $apiKey'},
      {
        'query': prepareQuery(query),
        'max_results': options.maxResults,
      },
      providerName: 'Tavily',
    );
    final raw = (json['results'] as List?) ?? const [];
    return [
      for (final e in raw.whereType<Map>())
        WebSearchResult(
          title: e['title'] as String? ?? '',
          url: e['url'] as String? ?? '',
          content: truncate(e['content'] as String? ?? ''),
        ),
    ];
  }
}

/// Exa（POST https://api.exa.ai/search，x-api-key 头）。
/// 对应源项目 ExaProvider：numResults + useAutoprompt + text，内容字段是 `text`。
class ExaWebSearchProvider extends WebSearchProvider {
  static const _endpoint = 'https://api.exa.ai/search';

  ExaWebSearchProvider({
    required super.apiKey,
    super.options,
    super.clientFactory,
  });

  @override
  Future<List<WebSearchResult>> search(String query) async {
    final json = await postJson(
      Uri.parse(_endpoint),
      {'x-api-key': apiKey},
      {
        'query': prepareQuery(query),
        'numResults': options.maxResults,
        'useAutoprompt': true,
        'text': true,
      },
      providerName: 'Exa',
    );
    final raw = (json['results'] as List?) ?? const [];
    return [
      for (final e in raw.whereType<Map>().take(options.maxResults))
        WebSearchResult(
          title: e['title'] as String? ?? '',
          url: e['url'] as String? ?? '',
          content: truncate(e['text'] as String? ?? ''),
        ),
    ];
  }
}

/// 博查 Bocha（POST https://api.bochaai.com/v1/web-search，Bearer key）。
/// 对应源项目 BochaProvider：searchWithTime 走 freshness=oneDay（而非改写
/// 查询词），结果在 data.webPages.value，summary 优先于 snippet。
class BochaWebSearchProvider extends WebSearchProvider {
  static const _endpoint = 'https://api.bochaai.com/v1/web-search';

  BochaWebSearchProvider({
    required super.apiKey,
    super.options,
    super.clientFactory,
  });

  @override
  Future<List<WebSearchResult>> search(String query) async {
    final json = await postJson(
      Uri.parse(_endpoint),
      {'Authorization': 'Bearer $apiKey'},
      {
        'query': query,
        'count': options.maxResults,
        'freshness': options.searchWithTime ? 'oneDay' : 'noLimit',
        'summary': true,
        'page': 1,
      },
      providerName: 'Bocha',
    );
    if (json['code'] != 200) {
      throw Exception('Bocha 搜索失败：${json['msg']}');
    }
    final raw =
        ((json['data'] as Map?)?['webPages'] as Map?)?['value'] as List? ??
            const [];
    return [
      for (final e in raw.whereType<Map>())
        WebSearchResult(
          title: e['name'] as String? ?? '',
          url: e['url'] as String? ?? '',
          content: truncate(
              (e['summary'] as String?) ?? (e['snippet'] as String?) ?? ''),
        ),
    ];
  }
}

/// 智谱（POST https://open.bigmodel.cn/api/paas/v4/web_search，Bearer key）。
/// 对应源项目 ZhipuProvider：search_engine=search_std，结果在 search_result，
/// 链接字段是 `link`。
class ZhipuWebSearchProvider extends WebSearchProvider {
  static const _endpoint = 'https://open.bigmodel.cn/api/paas/v4/web_search';

  ZhipuWebSearchProvider({
    required super.apiKey,
    super.options,
    super.clientFactory,
  });

  @override
  Future<List<WebSearchResult>> search(String query) async {
    final json = await postJson(
      Uri.parse(_endpoint),
      {'Authorization': 'Bearer $apiKey'},
      {
        'search_query': prepareQuery(query),
        'search_engine': 'search_std',
        'search_intent': false,
      },
      providerName: '智谱',
    );
    final raw = (json['search_result'] as List?) ?? const [];
    return [
      for (final e in raw.whereType<Map>().take(options.maxResults))
        WebSearchResult(
          title: e['title'] as String? ?? '',
          url: e['link'] as String? ?? '',
          content: truncate(e['content'] as String? ?? ''),
        ),
    ];
  }
}
