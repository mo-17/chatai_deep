import 'dart:convert';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/skill_script_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/model/skill_script.dart';
import 'package:chatgpt_app_core/skill/js_exec_result.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

/// 动作工具的运行上下文（L3）：提供「按当前账号打开数据库」+「写操作前确认」。
/// 只读工具（L3a）用 [openStorage]；写工具（L3b）执行前先 `await` [confirm]，
/// 由 UI 层弹框征得用户同意。两者都可注入便于单测。
class ToolActionContext {
  final Future<HiDBManager> Function() openStorage;

  /// 写操作前的人工确认回调：返回 true 放行、false 拒绝。
  /// **null = 无 UI**：写工具一律拒绝（安全兜底，防提示注入下的静默写入）。
  final Future<bool> Function(String title, String detail)? confirm;

  /// 当前会话绑定的助手 id（run_script 据此查该助手的技能脚本）。null = 无。
  final int? assistantId;

  /// 当前会话所属项目。知识库检索会优先使用项目绑定文档；null = 全局知识库。
  final int? projectId;

  /// JS 执行钩子（注入式）：避免工具层硬依赖原生引擎，便于单测与 OHOS 编译。
  /// null = 当前环境不支持执行脚本（run_script 会优雅跳过）。
  final Future<JsExecResult> Function(String code, String input)? runJs;

  const ToolActionContext({
    required this.openStorage,
    this.confirm,
    this.assistantId,
    this.projectId,
    this.runJs,
  });

  /// 默认实现：打开当前登录账号（或游客）的库。[confirm] / [runJs] 由 UI 层注入。
  factory ToolActionContext.forCurrentAccount({
    Future<bool> Function(String title, String detail)? confirm,
    int? assistantId,
    int? projectId,
    Future<JsExecResult> Function(String code, String input)? runJs,
  }) =>
      ToolActionContext(
        openStorage: () =>
            HiDBManager.instance(dbName: HiDBManager.getAccountHash()),
        confirm: confirm,
        assistantId: assistantId,
        projectId: projectId,
        runJs: runJs,
      );
}

/// L2 内置工具：无需配置、纯客户端执行的声明式工具（计算器 / 日期时间 / 抓取网页）。
/// 与 `web_search` 一样是 [ChatTool]，由助手通过 `toolIds` 绑定、模型自主调用。
class BuiltinTools {
  const BuiltinTools._();

  // ── 计算器 ───────────────────────────────────────────────
  static ChatTool calculator() => ChatTool(
        name: ToolRegistry.calculatorId,
        description: '计算一个数学表达式（加减乘除、取模 %、乘方 ^、括号）。'
            '当问题涉及精确算术、避免心算出错时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'expression': {
              'type': 'string',
              'description': '要计算的算术表达式，如 "(3+4)*2^3/7"',
            },
          },
          'required': ['expression'],
        },
        execute: (args) async {
          final expr = (args['expression'] as String? ?? '').trim();
          if (expr.isEmpty) {
            return const ToolOutcome(content: '错误：缺少 expression 参数');
          }
          try {
            final value = Arithmetic.eval(expr);
            return ToolOutcome(content: '$expr = ${_fmtNum(value)}');
          } on FormatException catch (e) {
            return ToolOutcome(content: '无法计算「$expr」：${e.message}');
          }
        },
      );

  // ── 当前日期时间 ─────────────────────────────────────────
  static ChatTool dateTime() => ChatTool(
        name: ToolRegistry.dateTimeId,
        description: '获取用户设备当前的本地日期与时间。当问题涉及「现在/今天/此刻」'
            '的精确时间、星期几、或需要据此计算时调用。',
        parameters: const {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        execute: (args) async {
          final now = DateTime.now();
          const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
          String two(int n) => n.toString().padLeft(2, '0');
          final date = '${now.year}-${two(now.month)}-${two(now.day)}';
          final time = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
          return ToolOutcome(
            content: jsonEncode({
              'date': date,
              'time': time,
              'weekday': '星期${weekdays[now.weekday - 1]}',
              'iso': now.toIso8601String(),
              'note': '用户设备本地时间',
            }),
          );
        },
      );

  // ── 抓取网页正文 ─────────────────────────────────────────
  /// [client] 仅供测试注入；默认用 package:http。
  static ChatTool fetchUrl({http.Client? client}) => ChatTool(
        name: ToolRegistry.fetchUrlId,
        description: '抓取一个网页 URL 并返回其正文文本（已去除 HTML 标签）。'
            '当用户给出链接、要求阅读/总结某个页面时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': '要抓取的完整 URL（http/https）',
            },
          },
          'required': ['url'],
        },
        execute: (args) async {
          final url = (args['url'] as String? ?? '').trim();
          final uri = Uri.tryParse(url);
          if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
            return const ToolOutcome(content: '错误：url 不是有效的 http/https 地址');
          }
          final c = client ?? http.Client();
          try {
            final resp = await c.get(uri).timeout(const Duration(seconds: 15));
            if (resp.statusCode != 200) {
              return ToolOutcome(content: '抓取失败：HTTP ${resp.statusCode}');
            }
            final text = HtmlText.extract(resp.body);
            if (text.isEmpty) return const ToolOutcome(content: '页面没有可提取的正文');
            return ToolOutcome(content: _cap(text, 4000));
          } catch (e) {
            return ToolOutcome(content: '抓取失败：$e');
          } finally {
            if (client == null) c.close();
          }
        },
      );

  static String _fmtNum(num v) {
    if (v is int) return v.toString();
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return v.toString();
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…（已截断）';

  // ── L3a 只读上下文工具 ───────────────────────────────────
  // 让助手能「读」用户自己的本地数据（会话/消息/收藏），无副作用、无需确认。

  /// 限制 [raw] 到 [min, max] 区间的整数参数，缺省 [fallback]。
  static int _intArg(Object? raw, int fallback, {int min = 1, int max = 50}) {
    final n = raw is int ? raw : int.tryParse('${raw ?? ''}');
    if (n == null) return fallback;
    return n.clamp(min, max);
  }

  static int? _nullableIntArg(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  static Future<bool> _conversationHasProjectId(Database db) async {
    final rows = await db.rawQuery('pragma table_info(tb_conversation_list)');
    return rows.any((r) => (r['name'] ?? '').toString() == 'projectId');
  }

  /// 打开账号库并确保四张读表存在（懒建表，空账号也安全）。
  static Future<Database> _readyDb(ToolActionContext ctx) async {
    final storage = await ctx.openStorage();
    await ConversationListDao.create(storage);
    await MessageDao.create(storage, cid: 0);
    await FavoriteDao.create(storage);
    return storage.db;
  }

  /// 按关键词检索历史聊天消息（跨所有会话）。
  static ChatTool searchChatHistory(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.searchHistoryId,
        description: '在用户的历史聊天记录里按关键词检索消息。当用户提到「我之前聊过/'
            '问过」「找一下关于…的对话」等需要回顾历史时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '检索关键词'},
            'projectId': {
              'type': 'integer',
              'description': '按项目 ID 过滤（可选，不传则查全部）',
            },
            'limit': {'type': 'integer', 'description': '返回条数上限（默认 10，最多 50）'},
          },
          'required': ['query'],
        },
        execute: (args) async {
          final q = (args['query'] as String? ?? '').trim();
          if (q.isEmpty) return const ToolOutcome(content: '错误：缺少 query 参数');
          final limit = _intArg(args['limit'], 10);
          final db = await _readyDb(ctx);
          final hasProjectColumn = await _conversationHasProjectId(db);
          final projectId = _nullableIntArg(args['projectId']);
          final projectClause = hasProjectColumn && projectId != null
              ? ' and c.projectId = ?'
              : '';
          final projectSelect =
              hasProjectColumn ? ', c.projectId as projectId' : '';
          final rows = await db.rawQuery(
            'select m.cid as cid, m.content as content, m.createdAt as createdAt'
            ', m.ownerType as ownerType, c.title as title$projectSelect '
            'from tb_messages m '
            'left join tb_conversation_list c on c.cid = m.cid '
            'where m.content like ?$projectClause order by m.createdAt desc limit ?',
            [
              '%$q%',
              if (projectId != null && hasProjectColumn) projectId,
              limit
            ],
          );
          if (rows.isEmpty) {
            return ToolOutcome(content: '没有找到包含「$q」的历史消息');
          }
          return ToolOutcome(
            content: jsonEncode([
              for (final r in rows)
                {
                  'cid': r['cid'],
                  'conversation': r['title'] ?? '(未命名会话)',
                  'role': r['ownerType'] == 'sender' ? 'user' : 'assistant',
                  'snippet': _cap((r['content'] as String? ?? ''), 300),
                  if (hasProjectColumn) 'projectId': r['projectId'],
                },
            ]),
          );
        },
      );

  /// 列出最近的会话（概览）。
  static ChatTool listConversations(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.listConversationsId,
        description: '列出用户最近的会话（标题、消息数、最后更新）。当用户问'
            '「我最近聊了什么」「列一下我的会话」时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'description': '返回条数上限（默认 20，最多 50）'},
            'projectId': {
              'type': 'integer',
              'description': '按项目 ID 过滤（可选，不传则查全部）'
            },
          },
        },
        execute: (args) async {
          final limit = _intArg(args['limit'], 20);
          final db = await _readyDb(ctx);
          final hasProjectColumn = await _conversationHasProjectId(db);
          final projectId = _nullableIntArg(args['projectId']);
          final rows = await db.query('tb_conversation_list',
              columns: [
                'cid',
                'title',
                'messageCount',
                'updateAt',
                if (hasProjectColumn) 'projectId'
              ],
              where: hasProjectColumn && projectId != null
                  ? 'projectId = ?'
                  : null,
              whereArgs:
                  hasProjectColumn && projectId != null ? [projectId] : null,
              orderBy: 'updateAt desc',
              limit: limit);
          if (rows.isEmpty) return const ToolOutcome(content: '当前账号还没有任何会话');
          return ToolOutcome(
            content: jsonEncode([
              for (final r in rows)
                {
                  'cid': r['cid'],
                  'title': r['title'] ?? '(未命名会话)',
                  'messageCount': r['messageCount'] ?? 0,
                  if (hasProjectColumn) 'projectId': r['projectId'],
                },
            ]),
          );
        },
      );

  /// 列出收藏的消息。
  static ChatTool listFavorites(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.listFavoritesId,
        description: '列出用户收藏的消息内容。当用户问「我收藏了什么」「从我的收藏里找…」'
            '时调用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'description': '返回条数上限（默认 20，最多 50）'},
          },
        },
        execute: (args) async {
          final limit = _intArg(args['limit'], 20);
          final db = await _readyDb(ctx);
          final rows = await db.query('tb_favorite',
              columns: ['content', 'ownerName', 'createdAt'],
              orderBy: 'id desc',
              limit: limit);
          if (rows.isEmpty) return const ToolOutcome(content: '收藏夹是空的');
          return ToolOutcome(
            content: jsonEncode([
              for (final r in rows)
                {
                  'owner': r['ownerName'],
                  'content': _cap((r['content'] as String? ?? ''), 500),
                },
            ]),
          );
        },
      );

  /// 读取某个会话（按 cid）的消息正文。
  static ChatTool getConversationMessages(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.getConversationMessagesId,
        description: '读取指定会话（cid）的消息内容，用于总结/回顾某次对话。'
            'cid 可来自 search_chat_history 或 list_conversations 的结果。',
        parameters: const {
          'type': 'object',
          'properties': {
            'cid': {'type': 'integer', 'description': '会话 id（cid）'},
            'limit': {
              'type': 'integer',
              'description': '返回消息条数上限（默认 30，最多 50）'
            },
          },
          'required': ['cid'],
        },
        execute: (args) async {
          final cid = args['cid'] is int
              ? args['cid'] as int
              : int.tryParse('${args['cid'] ?? ''}');
          if (cid == null) return const ToolOutcome(content: '错误：缺少有效的 cid 参数');
          final limit = _intArg(args['limit'], 30);
          final db = await _readyDb(ctx);
          final rows = await db.query('tb_messages',
              columns: ['content', 'ownerType', 'ownerName', 'createdAt'],
              where: 'cid = ?',
              whereArgs: [cid],
              orderBy: 'id asc',
              limit: limit);
          if (rows.isEmpty) {
            return ToolOutcome(content: '会话 $cid 没有消息（可能已删除）');
          }
          return ToolOutcome(
            content: jsonEncode([
              for (final r in rows)
                {
                  'role': r['ownerType'] == 'sender' ? 'user' : 'assistant',
                  'content': _cap((r['content'] as String? ?? ''), 1000),
                },
            ]),
          );
        },
      );

  // ── L4a 知识库检索（只读）───────────────────────────────
  /// 在用户导入的知识库里按关键词检索相关片段（RAG 关键词版）。
  static ChatTool knowledgeSearch(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.knowledgeSearchId,
        description: '在用户导入的知识库（私有文档）里按关键词检索相关内容。'
            '当问题可能在用户的资料/文档里有答案时调用；回答时基于检索片段并注明来源标题。',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '检索关键词（可多词，空格分隔，均需命中）'},
            'limit': {'type': 'integer', 'description': '返回片段数上限（默认 6，最多 50）'},
          },
          'required': ['query'],
        },
        execute: (args) async {
          final q = (args['query'] as String? ?? '').trim();
          if (q.isEmpty) return const ToolOutcome(content: '错误：缺少 query 参数');
          final limit = _intArg(args['limit'], 6);
          final storage = await ctx.openStorage();
          final dao = await KnowledgeDao.create(storage);
          final hits =
              await dao.search(q, limit: limit, projectId: ctx.projectId);
          if (hits.isEmpty) {
            return ToolOutcome(content: '知识库里没有找到与「$q」相关的内容');
          }
          return ToolOutcome(
            content: jsonEncode([
              for (final h in hits)
                {'source': h.docTitle, 'content': _cap(h.content, 1000)},
            ]),
          );
        },
      );

  // ── L3b 追加写工具（需人工确认）─────────────────────────
  // 让助手能「写」用户数据，但每次写都先 await ctx.confirm 征得同意；
  // 缺 confirm（无 UI）一律拒绝，防提示注入下的静默写入。

  /// 写前确认：confirm 为 null（无 UI）时拒绝。
  static Future<bool> _confirm(
      ToolActionContext ctx, String title, String detail) async {
    final c = ctx.confirm;
    if (c == null) return false;
    return c(title, detail);
  }

  static const _denied = ToolOutcome(content: '用户拒绝了该操作，未做任何修改');

  /// 收藏一段文本到收藏夹。
  static ChatTool saveFavorite(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.saveFavoriteId,
        description: '把一段文本保存到用户的收藏夹。当用户说「收藏这段/记下来」时调用。'
            '执行前会请用户确认。',
        parameters: const {
          'type': 'object',
          'properties': {
            'content': {'type': 'string', 'description': '要收藏的文本内容'},
          },
          'required': ['content'],
        },
        execute: (args) async {
          final content = (args['content'] as String? ?? '').trim();
          if (content.isEmpty) {
            return const ToolOutcome(content: '错误：缺少 content 参数');
          }
          if (!await _confirm(
              ctx, '收藏内容', '助手想把以下内容存入收藏夹：\n${_cap(content, 200)}')) {
            return _denied;
          }
          final storage = await ctx.openStorage();
          final dao = await FavoriteDao.create(storage);
          await dao.addFavorite(FavoriteModel(
              ownerName: 'AI',
              content: content,
              createdAt: DateTime.now().millisecondsSinceEpoch));
          return const ToolOutcome(content: '已收藏');
        },
      );

  /// 新建一个（带标题的）会话。
  static ChatTool createConversation(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.createConversationId,
        description: '为用户新建一个会话（可带标题）。当用户说「新开一个话题/会话」时调用。'
            '执行前会请用户确认。',
        parameters: const {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': '新会话标题'},
          },
          'required': ['title'],
        },
        execute: (args) async {
          final title = (args['title'] as String? ?? '').trim();
          if (title.isEmpty) {
            return const ToolOutcome(content: '错误：缺少 title 参数');
          }
          if (!await _confirm(ctx, '新建会话', '助手想新建会话「$title」')) {
            return _denied;
          }
          final storage = await ctx.openStorage();
          final dao = await ConversationListDao.create(storage);
          final cid = DateTime.now().millisecondsSinceEpoch;
          await dao.saveConversation(ConversationModel(cid: cid, icon: '')
            ..title = title
            ..stickTime = 0
            ..messageCount = 0
            ..updateAt = cid);
          BackupService.restoreTick.value++; // 刷新会话列表
          return ToolOutcome(content: '已新建会话「$title」（cid=$cid）');
        },
      );

  /// 置顶 / 取消置顶一个会话。
  static ChatTool stickConversation(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.stickConversationId,
        description: '置顶或取消置顶指定会话（cid 来自 list_conversations）。'
            '执行前会请用户确认。',
        parameters: const {
          'type': 'object',
          'properties': {
            'cid': {'type': 'integer', 'description': '会话 id（cid）'},
            'stick': {
              'type': 'boolean',
              'description': 'true 置顶，false 取消置顶（默认 true）'
            },
          },
          'required': ['cid'],
        },
        execute: (args) async {
          final cid = args['cid'] is int
              ? args['cid'] as int
              : int.tryParse('${args['cid'] ?? ''}');
          if (cid == null) return const ToolOutcome(content: '错误：缺少有效的 cid 参数');
          final stick = args['stick'] is bool ? args['stick'] as bool : true;
          final action = stick ? '置顶' : '取消置顶';
          if (!await _confirm(ctx, '$action会话', '助手想$action会话 #$cid')) {
            return _denied;
          }
          final storage = await ctx.openStorage();
          await ConversationListDao.create(storage); // 确保表存在
          final count = await storage.db.update(
            'tb_conversation_list',
            {'stickTime': stick ? DateTime.now().millisecondsSinceEpoch : 0},
            where: 'cid = ?',
            whereArgs: [cid],
          );
          if (count == 0) return ToolOutcome(content: '没有找到会话 #$cid');
          BackupService.restoreTick.value++;
          return ToolOutcome(content: '已$action会话 #$cid');
        },
      );

  // ── 运行技能脚本（run_script）─────────────────────────────
  // 执行技能随包导入的 scripts/*.js。安全分三层：QuickJS 沙箱（无文件/网络）兜底、
  // 导入时的 AI 审计结论、执行前展示审计+代码预览并 await confirm（缺 confirm 一律拒绝）。
  static ChatTool runScript(ToolActionContext ctx) => ChatTool(
        name: ToolRegistry.runScriptId,
        description: '运行当前技能随包的脚本（scripts 里的 .js），用于确定性的文本/数据处理。'
            '按脚本文件名调用；input 为传给脚本的文本（脚本里以全局 INPUT 读取）。'
            '执行前会请用户确认。',
        parameters: const {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': '脚本文件名，如 normalize-punctuation.js',
            },
            'input': {'type': 'string', 'description': '传给脚本的输入文本（可选）'},
          },
          'required': ['name'],
        },
        execute: (args) async {
          final name = (args['name'] as String? ?? '').trim();
          final input = args['input'] as String? ?? '';
          if (name.isEmpty) return const ToolOutcome(content: '错误：缺少 name 参数');
          final aid = ctx.assistantId;
          if (aid == null) {
            return const ToolOutcome(content: '当前会话未绑定技能助手，无法运行脚本');
          }
          final storage = await ctx.openStorage();
          final dao = await SkillScriptDao.create(storage);
          final script = await dao.getScript(aid, name);
          if (script == null) return ToolOutcome(content: '未找到脚本「$name」');
          if (ctx.runJs == null) {
            return const ToolOutcome(content: '当前环境不支持执行脚本（已跳过），请用文字方式近似完成');
          }
          final summary =
              script.auditSummary.isNotEmpty ? '（${script.auditSummary}）' : '';
          final detail = '安全审计：${_auditLabel(script.auditLevel)}$summary\n'
              '代码预览：\n${_cap(script.code, 400)}';
          if (!await _confirm(ctx, '运行脚本「$name」', detail)) return _denied;
          final r = await ctx.runJs!(script.code, input);
          if (!r.ok) return ToolOutcome(content: '脚本执行失败：${r.error}');
          return ToolOutcome(content: r.output.isEmpty ? '(脚本无输出)' : r.output);
        },
      );

  /// 审计等级 → 中文标签（确认框展示用）。
  static String _auditLabel(String level) {
    switch (level) {
      case SkillScript.levelSafe:
        return '安全';
      case SkillScript.levelWarn:
        return '可疑';
      case SkillScript.levelDanger:
        return '危险';
      case SkillScript.levelPending:
        return '未审计';
      default:
        return '未知';
    }
  }
}

/// 极简算术求值（递归下降）。支持：整数/小数、`+ - * / %`、乘方 `^`（右结合）、
/// 一元正负、括号。非法输入抛 [FormatException]。无任何第三方依赖，便于单测。
class Arithmetic {
  static num eval(String input) {
    final parser = _Parser(_tokenize(input));
    final value = parser._parseExpr();
    parser._expectEnd();
    return value;
  }

  static List<String> _tokenize(String s) {
    final tokens = <String>[];
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t') {
        i++;
        continue;
      }
      if ('+-*/%^()'.contains(ch)) {
        tokens.add(ch);
        i++;
        continue;
      }
      if (_isDigit(ch) || ch == '.') {
        final start = i;
        var dot = false;
        while (i < s.length && (_isDigit(s[i]) || s[i] == '.')) {
          if (s[i] == '.') {
            if (dot) throw const FormatException('数字格式错误');
            dot = true;
          }
          i++;
        }
        tokens.add(s.substring(start, i));
        continue;
      }
      throw FormatException('无法识别的字符 "$ch"');
    }
    return tokens;
  }

  static bool _isDigit(String ch) {
    final c = ch.codeUnitAt(0);
    return c >= 0x30 && c <= 0x39;
  }
}

class _Parser {
  _Parser(this._tokens);
  final List<String> _tokens;
  int _pos = 0;

  String? get _peek => _pos < _tokens.length ? _tokens[_pos] : null;
  String _next() => _tokens[_pos++];

  void _expectEnd() {
    if (_pos != _tokens.length) {
      throw FormatException('多余的内容 "$_peek"');
    }
  }

  // expr := term (('+'|'-') term)*
  num _parseExpr() {
    var value = _parseTerm();
    while (_peek == '+' || _peek == '-') {
      final op = _next();
      final rhs = _parseTerm();
      value = op == '+' ? value + rhs : value - rhs;
    }
    return value;
  }

  // term := unary (('*'|'/'|'%') unary)*
  num _parseTerm() {
    var value = _parseUnary();
    while (_peek == '*' || _peek == '/' || _peek == '%') {
      final op = _next();
      final rhs = _parseUnary();
      if (op == '*') {
        value = value * rhs;
      } else if (op == '/') {
        if (rhs == 0) throw const FormatException('除数不能为 0');
        value = value / rhs;
      } else {
        if (rhs == 0) throw const FormatException('取模的除数不能为 0');
        value = value % rhs;
      }
    }
    return value;
  }

  // unary := ('+'|'-') unary | power
  num _parseUnary() {
    if (_peek == '+') {
      _next();
      return _parseUnary();
    }
    if (_peek == '-') {
      _next();
      return -_parseUnary();
    }
    return _parsePower();
  }

  // power := primary ('^' unary)?   // 右结合，且指数侧允许一元负号
  num _parsePower() {
    final base = _parsePrimary();
    if (_peek == '^') {
      _next();
      final exp = _parseUnary();
      return _pow(base, exp);
    }
    return base;
  }

  num _parsePrimary() {
    final tok = _peek;
    if (tok == null) throw const FormatException('表达式不完整');
    if (tok == '(') {
      _next();
      final value = _parseExpr();
      if (_peek != ')') throw const FormatException('括号不匹配');
      _next();
      return value;
    }
    final n = num.tryParse(tok);
    if (n == null) throw FormatException('期望数字，得到 "$tok"');
    _next();
    return n;
  }

  num _pow(num base, num exp) {
    final r = _powDouble(base.toDouble(), exp.toDouble());
    if (!r.isFinite) throw const FormatException('乘方结果无效');
    // 整数底 + 非负整数指数 -> 返回整数，结果更干净。
    if (base is int && exp is int && exp >= 0 && r == r.roundToDouble()) {
      return r.toInt();
    }
    if (base == base.roundToDouble() &&
        exp == exp.roundToDouble() &&
        exp >= 0 &&
        r == r.roundToDouble() &&
        r.abs() < 1e15) {
      return r.toInt();
    }
    return r;
  }

  static double _powDouble(double a, double b) {
    // 避免引入 dart:math 只为 pow——整数指数用快速幂，其余回退。
    if (b == b.roundToDouble() && b.abs() < 1000) {
      var n = b.toInt();
      final neg = n < 0;
      n = n.abs();
      var result = 1.0;
      var p = a;
      while (n > 0) {
        if (n & 1 == 1) result *= p;
        p *= p;
        n >>= 1;
      }
      return neg ? 1.0 / result : result;
    }
    // 非整数指数：用 exp/ln 近似（极少用到）。
    return _expApprox(b * _lnApprox(a));
  }

  static double _lnApprox(double x) {
    if (x <= 0) return double.nan;
    // 自然对数级数（够用即可）。
    final y = (x - 1) / (x + 1);
    final y2 = y * y;
    var term = y;
    var sum = 0.0;
    for (var k = 1; k <= 99; k += 2) {
      sum += term / k;
      term *= y2;
    }
    return 2 * sum;
  }

  static double _expApprox(double x) {
    var sum = 1.0;
    var term = 1.0;
    for (var k = 1; k <= 50; k++) {
      term *= x / k;
      sum += term;
    }
    return sum;
  }
}

/// 把 HTML 粗提取为纯文本：剔除 script/style、去标签、解码常见实体、压缩空白。
class HtmlText {
  const HtmlText._();

  static String extract(String html) {
    var s = html;
    s = s.replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        ' ');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(
        RegExp(r'</(p|div|li|h[1-6]|tr)>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = _decodeEntities(s);
    // 压缩空白：行内多空格 -> 单空格；多空行 -> 单空行。
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r' *\n *'), '\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
}
