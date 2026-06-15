import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

/// 一次工具执行的产物：回灌给模型的 content + 可选的引用来源。
/// [webResults] 由联网搜索工具填充，ToolLoopRunner 汇总后发 citation 事件，
/// 让工具调用路径与阶段五的意图编排路径有一致的「可点来源」体验。
class ToolOutcome {
  final String content;
  final List<WebSearchResult> webResults;

  const ToolOutcome({required this.content, this.webResults = const []});
}

/// 一个可供模型调用的工具：OpenAI function 声明 + 客户端执行函数。
class ChatTool {
  final String name;
  final String description;

  /// 参数的 JSON Schema（OpenAI function parameters）。
  final Map<String, dynamic> parameters;
  final Future<ToolOutcome> Function(Map<String, dynamic> args) execute;

  const ChatTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  /// OpenAI Chat Completions 的 tools 数组元素。
  Map<String, dynamic> toFunctionJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// 一个可绑定工具的元信息（L1）。供助手编辑页展示「可选工具清单」用，
/// 与实际执行体 [ChatTool] 解耦（执行体在 [ToolRegistry] 工厂里按需构造）。
class ToolDescriptor {
  /// 工具 id（与 [ChatTool.name] 一致，也是助手 `toolIds` 里存的值）。
  final String id;
  final String label;
  final String description;

  /// 是否依赖已配置的联网搜索 key（未配置时 UI 应置灰）。
  final bool requiresSearchKey;

  /// 是否会修改用户数据（L3b 写工具）。UI 据此标注「会修改数据」，
  /// 运行时这类工具执行前会弹确认框。
  final bool sideEffect;

  const ToolDescriptor({
    required this.id,
    required this.label,
    required this.description,
    this.requiresSearchKey = false,
    this.sideEffect = false,
  });
}

/// 工具注册表（阶段六）。对应源项目 `src/aiCore/tools/`：
/// 把「联网搜索」「知识库检索」等注册成工具，由模型决定调用。
class ToolRegistry {
  /// 工具 id。
  static const webSearchId = 'web_search';
  static const calculatorId = 'calculator';
  static const dateTimeId = 'datetime';
  static const fetchUrlId = 'fetch_url';
  // L3a 只读上下文工具。
  static const searchHistoryId = 'search_chat_history';
  static const listConversationsId = 'list_conversations';
  static const listFavoritesId = 'list_favorites';
  static const getConversationMessagesId = 'get_conversation_messages';
  // L3b 追加写工具（需确认）。
  static const saveFavoriteId = 'save_favorite';
  static const createConversationId = 'create_conversation';
  static const stickConversationId = 'stick_conversation';

  /// 需要账号数据访问（[ToolActionContext]）的工具 id（L3a 只读 + L3b 写）。
  static const Set<String> _dataToolIds = {
    searchHistoryId,
    listConversationsId,
    listFavoritesId,
    getConversationMessagesId,
    saveFavoriteId,
    createConversationId,
    stickConversationId,
  };

  /// 可绑定工具清单（L1/L2/L3a）。助手编辑页据此渲染多选；新增工具在此登记。
  static const List<ToolDescriptor> catalog = [
    ToolDescriptor(
      id: webSearchId,
      label: '联网搜索',
      description: '让助手能检索互联网最新信息（需已配置搜索 key）',
      requiresSearchKey: true,
    ),
    ToolDescriptor(
      id: calculatorId,
      label: '计算器',
      description: '精确计算数学表达式（加减乘除、取模、乘方、括号）',
    ),
    ToolDescriptor(
      id: dateTimeId,
      label: '日期时间',
      description: '获取设备当前的本地日期、时间与星期',
    ),
    ToolDescriptor(
      id: fetchUrlId,
      label: '网页抓取',
      description: '抓取一个网页 URL 并返回其正文文本',
    ),
    ToolDescriptor(
      id: searchHistoryId,
      label: '搜索聊天记录',
      description: '让助手按关键词检索你的历史聊天消息（只读）',
    ),
    ToolDescriptor(
      id: listConversationsId,
      label: '列出会话',
      description: '让助手列出你最近的会话概览（只读）',
    ),
    ToolDescriptor(
      id: listFavoritesId,
      label: '读取收藏',
      description: '让助手读取你收藏的消息（只读）',
    ),
    ToolDescriptor(
      id: getConversationMessagesId,
      label: '读取会话内容',
      description: '让助手读取指定会话的消息，用于总结/回顾（只读）',
    ),
    ToolDescriptor(
      id: saveFavoriteId,
      label: '收藏内容',
      description: '让助手把文本存入你的收藏夹（会修改数据，执行前需你确认）',
      sideEffect: true,
    ),
    ToolDescriptor(
      id: createConversationId,
      label: '新建会话',
      description: '让助手为你新建一个会话（会修改数据，执行前需你确认）',
      sideEffect: true,
    ),
    ToolDescriptor(
      id: stickConversationId,
      label: '置顶会话',
      description: '让助手置顶/取消置顶会话（会修改数据，执行前需你确认）',
      sideEffect: true,
    ),
  ];

  /// 某工具在当前设置下是否可用（依赖条件已满足）。
  /// 仅 web_search 依赖搜索 key；其余 L2 工具无需配置，恒可用。
  static bool isAvailable(AISettings s, String id) {
    if (id == webSearchId) return s.webSearchConfigured;
    return catalog.any((d) => d.id == id);
  }

  final List<ChatTool> tools;

  const ToolRegistry(this.tools);

  bool get isEmpty => tools.isEmpty;

  /// 发给模型的 function declarations。
  List<Map<String, dynamic>> get declarations =>
      [for (final t in tools) t.toFunctionJson()];

  ChatTool? byName(String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// 执行一个调用。未注册 / 执行抛错都转成文本回灌给模型（模型可自行恢复），
  /// 不向上抛 —— 工具失败绝不中断会话流。
  Future<ToolOutcome> execute(String name, Map<String, dynamic> args) async {
    final tool = byName(name);
    if (tool == null) {
      return ToolOutcome(content: '错误：未注册的工具 "$name"');
    }
    try {
      return await tool.execute(args);
    } catch (e) {
      return ToolOutcome(content: '工具 "$name" 执行失败：$e');
    }
  }

  /// 工厂：按用户设置组装可用工具。目前只有联网搜索（配置了搜索 key 且
  /// 用户开了联网开关时注册）；「知识库检索」等后续在此追加。
  static ToolRegistry fromSettings(AISettings s) {
    final provider = WebSearchProvider.fromSettings(s);
    return ToolRegistry([
      if (provider != null) webSearchTool(provider),
    ]);
  }

  /// 工厂（L1/L2/L3a）：按助手绑定的 [toolIds] + 当前设置组装注册表。
  /// - [toolIds] 为 null/空 = 助手未绑定任何工具；
  /// - [forceWebSearch] = 会话页联网开关打开时强制纳入 web_search（保持旧行为）；
  /// - 只纳入「依赖条件已满足」的工具（如 web_search 需已配置搜索 key）；
  /// - [actions]（L3a）= 只读上下文工具的运行上下文；为 null 时这些工具不装配。
  static ToolRegistry fromAssistant(
    AISettings s,
    List<String>? toolIds, {
    bool forceWebSearch = false,
    ToolActionContext? actions,
  }) {
    final selected = <String>{...?toolIds};
    if (forceWebSearch) selected.add(webSearchId);

    final tools = <ChatTool>[];
    if (selected.contains(webSearchId)) {
      final provider = WebSearchProvider.fromSettings(s);
      if (provider != null) tools.add(webSearchTool(provider));
    }
    if (selected.contains(calculatorId)) tools.add(BuiltinTools.calculator());
    if (selected.contains(dateTimeId)) tools.add(BuiltinTools.dateTime());
    if (selected.contains(fetchUrlId)) tools.add(BuiltinTools.fetchUrl());

    // L3a 只读上下文工具：需要账号数据访问，缺 actions 则跳过。
    if (actions != null && selected.any(_dataToolIds.contains)) {
      if (selected.contains(searchHistoryId)) {
        tools.add(BuiltinTools.searchChatHistory(actions));
      }
      if (selected.contains(listConversationsId)) {
        tools.add(BuiltinTools.listConversations(actions));
      }
      if (selected.contains(listFavoritesId)) {
        tools.add(BuiltinTools.listFavorites(actions));
      }
      if (selected.contains(getConversationMessagesId)) {
        tools.add(BuiltinTools.getConversationMessages(actions));
      }
      // L3b 写工具（执行前 await confirm）。
      if (selected.contains(saveFavoriteId)) {
        tools.add(BuiltinTools.saveFavorite(actions));
      }
      if (selected.contains(createConversationId)) {
        tools.add(BuiltinTools.createConversation(actions));
      }
      if (selected.contains(stickConversationId)) {
        tools.add(BuiltinTools.stickConversation(actions));
      }
    }
    return ToolRegistry(tools);
  }

  /// 联网搜索工具：复用阶段五的 [WebSearchProvider]（Tavily 等）。
  /// 与意图编排路径互斥使用（见 CompletionDao 的选路决策）。
  static ChatTool webSearchTool(WebSearchProvider provider) => ChatTool(
        name: 'web_search',
        description: '搜索互联网获取最新信息。当问题涉及新闻、时事、天气、'
            '价格、赛事、最新发布的产品/版本等需要时效性或外部事实的内容时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': '自包含的搜索查询词（带上时间、主体等关键信息，不要用代词）',
            },
          },
          'required': ['query'],
        },
        execute: (args) async {
          final query = (args['query'] as String? ?? '').trim();
          if (query.isEmpty) {
            return const ToolOutcome(content: '错误：缺少 query 参数');
          }
          // 条数 / 正文截断 / 日期前缀由 provider 的用户配置决定。
          final results = await provider.search(query);
          if (results.isEmpty) {
            return const ToolOutcome(content: '没有搜到相关结果');
          }
          // 回灌 JSON（带编号），并把来源带出去供 CitationBlock 展示。
          return ToolOutcome(
            content: jsonEncode([
              for (var i = 0; i < results.length; i++)
                {
                  'index': i + 1,
                  'title': results[i].title,
                  'url': results[i].url,
                  'content': results[i].content,
                },
            ]),
            webResults: results,
          );
        },
      );
}
