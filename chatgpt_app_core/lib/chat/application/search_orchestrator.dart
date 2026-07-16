import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 意图识别结果：要不要联网 + 改写/拆解出的搜索 query 列表。
class SearchIntent {
  final bool needSearch;
  final List<String> queries;

  const SearchIntent({required this.needSearch, this.queries = const []});

  /// fallback：意图识别失败时直接用原问题搜（指南 §6 第 1 点）。
  factory SearchIntent.fallback(String prompt) =>
      SearchIntent(needSearch: true, queries: [prompt]);

  /// 从 LLM 输出里解析 JSON（比源项目的 XML 稳）。容错：
  /// - 允许 ```json 围栏 / JSON 前后混杂说明文字（取首个 `{` 到末个 `}`）；
  /// - needSearch=true 但 queries 为空时回退用原问题；
  /// - 任何解析失败都 fallback 为直接搜原问题。
  factory SearchIntent.parse(String raw, {required String fallbackQuery}) {
    try {
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) return SearchIntent.fallback(fallbackQuery);
      final json =
          jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      final need = json['needSearch'] as bool? ?? false;
      if (!need) return const SearchIntent(needSearch: false);
      final queries = ((json['queries'] as List?) ?? const [])
          .whereType<String>()
          .map((q) => q.trim())
          .where((q) => q.isNotEmpty)
          .toList();
      return SearchIntent(
        needSearch: true,
        queries: queries.isEmpty ? [fallbackQuery] : queries,
      );
    } catch (_) {
      return SearchIntent.fallback(fallbackQuery);
    }
  }
}

/// 搜索编排器（阶段五）。对应源项目 `searchOrchestrationPlugin` + `WebSearchService`：
/// 意图识别（轻量 LLM 调用）→ 多 query 并行搜索 → 合并去重 → 回填上下文。
class SearchOrchestrator {
  /// 每条 query 的结果数上限。
  static const int maxResultsPerQuery = 5;

  /// 单条结果正文摘要的字符上限（回填给主 LLM 时控制 token 量）。
  static const int contentLimit = 2000;

  /// 合并后的来源总数上限（多 query 去重后再截）。
  static const int maxTotalResults = 8;

  /// 意图识别时携带的最近历史条数（解决「那他多大了」类指代）。
  static const int intentHistoryDepth = 4;

  /// 用于意图识别的轻量 LLM 通道（与正式会话同一个服务，非流式调用）。
  final ChatService chatService;
  final WebSearchProvider provider;

  SearchOrchestrator({required this.chatService, required this.provider});

  /// 完整编排：意图识别 → 不需要搜则返回空 → 并行搜索聚合。
  /// 任何环节抛错都不应阻塞正式会话，调用方需自行 try/catch。
  Future<List<WebSearchResult>> run({
    required String prompt,
    required List<Map<String, dynamic>> history,
  }) async {
    final intent = await analyzeIntent(prompt: prompt, history: history);
    if (!intent.needSearch) return const [];
    AILogger.log('web search query count: ${intent.queries.length}');
    return searchAll(intent.queries);
  }

  /// 意图识别：发正式请求前用一次非流式调用判断要不要联网，
  /// 并把用户问题改写/拆解成 1~3 个 query。LLM 调用失败时 fallback 直接搜原问题。
  Future<SearchIntent> analyzeIntent({
    required String prompt,
    required List<Map<String, dynamic>> history,
  }) async {
    try {
      final raw = await chatService.chat(
        prompt: buildIntentPrompt(prompt),
        history: recentTextHistory(history),
      );
      return SearchIntent.parse(raw ?? '', fallbackQuery: prompt);
    } catch (e) {
      AILogger.log('intent analyze failed, fallback to raw query: $e');
      return SearchIntent.fallback(prompt);
    }
  }

  /// 多 query 并行搜索（Future.wait），按 URL 去重合并。每条 query 的条数与
  /// 正文截断由 provider 的 [WebSearchOptions]（用户设置）决定；合并总数
  /// 截到 max([maxTotalResults], 用户配置的单次条数)。
  /// 单条 query 失败不影响其它 query（吞掉错误返回空列表）。
  Future<List<WebSearchResult>> searchAll(List<String> queries) async {
    final lists = await Future.wait(queries.map(
      (q) => provider.search(q).catchError((Object e) {
        AILogger.log('search "$q" failed: $e');
        return <WebSearchResult>[];
      }),
    ));
    final totalCap = provider.options.maxResults > maxTotalResults
        ? provider.options.maxResults
        : maxTotalResults;
    final seen = <String>{};
    final merged = <WebSearchResult>[];
    for (final list in lists) {
      for (final r in list) {
        if (r.url.isEmpty || !seen.add(r.url)) continue;
        merged.add(r);
        if (merged.length >= totalCap) return merged;
      }
    }
    return merged;
  }

  /// 当前本地日期，格式 `yyyy-MM-dd`。意图改写与结果回填都用它锚定「今天」，
  /// 避免主 LLM 用训练截止日期理解时效问题。
  static String today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// 意图识别的指令模板。要求只输出 JSON（解析端仍带容错 + fallback）。
  static String buildIntentPrompt(String prompt) {
    return '''
你是联网搜索意图分析器。判断回答下面的「用户问题」是否需要检索互联网上的最新信息，并在需要时把问题改写成 1~3 个适合搜索引擎的查询词。
今天的日期：${today()}。
规则：
- 闲聊、写作、翻译、数学、代码等不依赖时效信息或外部事实的问题，不需要搜索；
- 新闻、时事、天气、价格、赛事比分、最新发布的产品/版本、具体人物或机构的近况等，需要搜索；
- 查询词应自包含（带上时间、主体等关键信息），不要使用代词；
- 只输出一行 JSON，不要输出任何其它文字或代码围栏：
{"needSearch": true 或 false, "queries": ["查询词1", "查询词2"]}

用户问题：
"""
$prompt
"""''';
  }

  /// 把最近 [intentHistoryDepth] 条历史压成纯文本（多模态 content 数组只取 text 部分），
  /// 供意图识别解指代，不把图片/文件等大负载重复发一遍。
  static List<Map<String, dynamic>> recentTextHistory(
      List<Map<String, dynamic>> history) {
    final tail = history.length > intentHistoryDepth
        ? history.sublist(history.length - intentHistoryDepth)
        : history;
    return [
      for (final m in tail)
        {'role': m['role'], 'content': _textOf(m['content'])},
    ];
  }

  static String _textOf(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .map((p) => p['text'] as String? ?? '')
          .join('\n');
    }
    return '';
  }

  /// 回填模板：把搜索结果编号排版成上下文，交给主 LLM 总结（拼进当前轮
  /// prompt 之后，走 [ChatAttachments.extraText] 同款通路）。
  static String buildSearchContext(List<WebSearchResult> results) {
    final buf = StringBuffer('今天的日期是 ${today()}，请以此理解用户问题中的「今天」「最近」等时间词。\n')
      ..write('以下是与用户问题相关的联网搜索结果：\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      buf
        ..writeln()
        ..writeln('[${i + 1}] ${r.title}')
        ..writeln('来源：${r.url}');
      if (r.content.isNotEmpty) buf.writeln(r.content);
    }
    buf
      ..writeln()
      ..write('请基于以上搜索结果回答用户问题；引用某条结果时在句末用 [编号] 标注；与问题无关的结果可忽略。');
    return buf.toString();
  }
}
