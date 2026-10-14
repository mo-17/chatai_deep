import 'dart:convert';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';

import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/agent_verification_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:sqflite/sqflite.dart';

class AgentWorkspaceTools {
  final int cid;
  final AgentWorkspaceService workspace;
  final AgentVerificationDao store;
  final Future<bool> Function(String title, String detail)? confirm;
  int? _userCreatedAt;
  bool Function()? _executionGuard;
  Future<void> Function(Transaction)? _readTransactionGuard;
  Future<void> Function(Future<void> Function())? _readStable;
  AgentTaskVerificationReport? lastReport;

  /// 执行器绑定固定 run；操作开始时捕获，不能跟随后续同对话任务换身份。
  void bindExecutionGuard(bool Function() guard) => _executionGuard = guard;
  void bindReadTransactionGuard(Future<void> Function(Transaction) guard,
      Future<void> Function(Future<void> Function()) stable) {
    _readTransactionGuard = guard;
    _readStable = stable;
  }

  AgentWorkspaceTools._(
      {required this.cid,
      required this.workspace,
      required this.store,
      this.confirm});

  static Future<AgentWorkspaceTools> create(HiDBManager manager,
          {required int cid,
          required AgentWorkspaceService workspace,
          Future<bool> Function(String title, String detail)? confirm}) async =>
      AgentWorkspaceTools._(
          cid: cid,
          workspace: workspace,
          store: await AgentVerificationDao.create(manager),
          confirm: confirm);

  Future<TaskAcceptanceCriteria> loadCriteria() async =>
      TaskAcceptanceCriteria.fromJson(
          await store.loadCriteria(cid) ?? const {});

  /// 只有用户界面调用；模型工具没有修改验收条件的入口。
  Future<void> saveCriteria(TaskAcceptanceCriteria criteria) async {
    criteria.validate();
    await store.saveCriteria(cid, criteria.toJson());
  }

  /// 首次请求即包含用户条件；恢复时沿用该轮快照，不受下一轮设置影响。
  Future<String> acceptancePrompt(
      {bool hasInputs = false, bool resume = false}) async {
    TaskAcceptanceCriteria criteria;
    if (resume) {
      final snapshot = _userCreatedAt == null
          ? await store.loadLatestTurn(cid)
          : await store.loadTurn(cid, _userCreatedAt!);
      criteria = snapshot == null
          ? const TaskAcceptanceCriteria()
          : TaskAcceptanceCriteria.fromJson(
              Map<String, dynamic>.from(snapshot['criteria'] as Map));
    } else if (hasInputs || await store.criteriaArmed(cid)) {
      criteria = await loadCriteria();
    } else {
      return '';
    }
    return '[用户客观验收条件]\n${jsonEncode(criteria.toJson())}\n'
        '这是用户设置，不能削弱或替换。expectedOutputNames 必须是本轮经确认 write_file 的实际输出；'
        '旧输出文件本身不代表本轮交付。全文覆盖仅计算本轮 read_file 的真实区间。';
  }

  Future<AgentTaskVerificationReport?> loadLatestReport(
      {int? userCreatedAt}) async {
    final value =
        await store.loadLatestReport(cid, userCreatedAt: userCreatedAt);
    final report =
        value == null ? null : AgentTaskVerificationReport.fromJson(value);
    lastReport = report == null ? null : await _withCurrentVersions(report);
    return lastReport;
  }

  /// 刷新仅派生当前有效性，不改写历史报告、旧检查版本或本轮写入记录。
  Future<AgentTaskVerificationReport?> refreshLatestReport() =>
      loadLatestReport();

  Future<AgentTaskVerificationReport> _withCurrentVersions(
      AgentTaskVerificationReport report) async {
    final checkedVersions = <int, Set<int>>{};
    for (final check in report.checks) {
      if (check.fileId != null && check.revision != null) {
        checkedVersions
            .putIfAbsent(check.fileId!, () => <int>{})
            .add(check.revision!);
      }
    }
    final staleChecks = <AgentVerificationCheck>[];
    for (final entry in checkedVersions.entries) {
      final current = await workspace.getFile(entry.key);
      if (current == null ||
          entry.value.any((revision) => revision != current.revision)) {
        staleChecks.add(AgentVerificationCheck(
            label: '成果已变化，需要重新验收',
            passed: false,
            fileId: entry.key,
            revision: current?.revision,
            detail: '文件 ${entry.key} 的历史验收版本：${entry.value.join('、')}；'
                '${current == null ? '当前文件已不存在' : '当前版本：${current.revision}'}。'
                '历史通过仅适用于旧版本；手动编辑或恢复不会自动通过当前版本。'));
      }
    }
    if (staleChecks.isEmpty) return report;
    return AgentTaskVerificationReport(
        cid: report.cid,
        userCreatedAt: report.userCreatedAt,
        createdAt: report.createdAt,
        verifiedSnapshot: report.verifiedSnapshot,
        checks: List.unmodifiable([...report.checks, ...staleChecks]));
  }

  Future<void> beginTurn(int userCreatedAt, List<int> inputIds,
      {bool resume = false,
      TaskAcceptanceCriteria? criteriaOverride,
      bool Function()? executionGuard,
      Future<void> Function(Transaction)? transactionGuard,
      Future<void> Function(Future<void> Function())? stableOperation}) async {
    // 在首次 await 前固定本次身份；旧普通调用仍清除上一轮 guard。
    _executionGuard = executionGuard;
    _readTransactionGuard = transactionGuard;
    _readStable = stableOperation;
    final guard = executionGuard;
    if (guard?.call() == false) throw StateError('任务已失效');
    if (userCreatedAt <= 0) throw const FormatException('本轮消息标识无效');
    final previous = resume ? await store.loadTurn(cid, userCreatedAt) : null;
    if (previous == null) {
      final ids = inputIds.toSet().toList();
      for (final id in ids) {
        if (await workspace.getFile(id) == null) {
          throw const FormatException('输入文件不在当前工作区');
        }
      }
      // 无附件且没有重新设置条件的纯聊天，不继承上一项文件任务的输出要求。
      final useSavedCriteria = ids.isNotEmpty || await store.criteriaArmed(cid);
      final criteria = criteriaOverride ??
          (useSavedCriteria
              ? await loadCriteria()
              : const TaskAcceptanceCriteria());
      criteria.validate();
      await store.beginTurn(
          cid,
          userCreatedAt,
          {
            'inputIds': ids,
            'outputs': <String, dynamic>{},
            'criteria': criteria.toJson(),
          },
          canCommit: guard,
          transactionGuard: transactionGuard,
          stableOperation: stableOperation);
    }
    if (guard?.call() == false) throw StateError('任务已失效');
    _userCreatedAt = userCreatedAt;
    lastReport = null;
    if (resume) await loadLatestReport(userCreatedAt: userCreatedAt);
  }

  int get _turn => _userCreatedAt ?? (throw StateError('本轮任务尚未开始'));

  Future<AgentTaskVerificationReport> verify(
      {bool Function()? canCommit}) async {
    final guard = canCommit ?? _executionGuard;
    final transactionGuard = _readTransactionGuard;
    final stable = _readStable;
    final turn = _turn;
    final snapshot = await store.loadTurn(cid, turn);
    if (snapshot == null) throw StateError('找不到本轮验收记录');
    final report =
        await AgentTaskVerifier(cid: cid, workspace: workspace, store: store)
            .verify(
      userCreatedAt: turn,
      inputIds: List<int>.from(snapshot['inputIds'] as List),
      outputRevisions: {
        for (final entry in (snapshot['outputs'] as Map).entries)
          int.parse(entry.key as String): entry.value as int,
      },
      criteria: TaskAcceptanceCriteria.fromJson(
          Map<String, dynamic>.from(snapshot['criteria'] as Map)),
      canCommit: guard,
      transactionGuard: transactionGuard,
      stableOperation: stable,
    );
    lastReport = report;
    return report;
  }

  Future<String?> correctionForFinal(String answer) async {
    final canCommit = _executionGuard;
    final report = await verify(canCommit: canCommit);
    if (report.isPassed) return null;
    final details = report.checks
        .where((check) => !check.passed)
        .map((check) => '${check.label}：${check.detail}')
        .join('\n');
    return '${report.summary}\n$details\n'
        '请使用剩余工具轮次补齐实际读取或修正工作区输出，再 verify_task。'
        '已执行的写操作不要重播；覆盖/创建输出仍须用户确认。'
        '不能修改用户验收条件，不能只在回答中声称完成。';
  }

  String get systemPrompt =>
      '会话文件工作区：先 list_files 查看文件清单，沿 nextOffset 分页直到 null；用 read_file 分段阅读，'
      'offset 是 UTF-16、0 起始，endOffset 不包含末字符；沿 nextOffset 续读。'
      'file_search 仅定位，不算全文阅读。write_file 只写当前工作区 TXT/MD/CSV，'
      '需要引用原文时，使用 read_file 返回的 sourceMarker（[原文:sourceId]）放在对应结论后；'
      '只能使用实际读取结果中的标记，不编造文件、版本或位置。'
      '每次创建或覆盖均需用户确认，不自动发布成果。'
      '完成前 verify_task 检查本轮附件及实际读取输入的文字覆盖、实际输出和用户客观条件；'
      'PDF 仅验收可提取文字层，扫描图像未验收，空文字层需要 OCR 或替换为文本。'
      '检查通过只代表客观条件满足，不代表内容语义正确。';

  List<ChatTool> get tools => [
        ChatTool(
            name: 'list_files',
            description: '分页列出当前会话工作区的输入、输出及版本，不返回全文。沿 nextOffset 继续，直到 null。',
            parameters: const {
              'type': 'object',
              'properties': {
                'offset': {'type': 'integer', 'minimum': 0},
                'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
              },
              'additionalProperties': false
            },
            execute: (args) async {
              final offset = _optionalInt(args, 'offset') ?? 0;
              final limit = _optionalInt(args, 'limit') ?? 50;
              if (offset < 0 || limit < 1 || limit > 50) {
                throw const FormatException('offset 须非负，limit 须在 1 到 50 之间');
              }
              final files = await workspace.listFiles();
              final page = files.skip(offset).take(limit).map((file) {
                final metadata = file.toJson();
                metadata['sections'] = file.sections.take(10).map((section) {
                  final value = Map<String, dynamic>.from(section);
                  final title = value['title'] as String?;
                  if (title != null && title.length > 80) {
                    value['title'] = title.substring(0, 80);
                  }
                  return value;
                }).toList();
                return metadata;
              }).toList();
              final next = offset + page.length;
              return ToolOutcome(
                  content: jsonEncode({
                'files': page,
                'totalFiles': files.length,
                'nextOffset': next < files.length ? next : null,
              }));
            }),
        ChatTool(
            name: 'read_file',
            description: '分段读取当前工作区文件；按 nextOffset 续读。仅实际返回的区间计入本轮全文阅读证据。',
            parameters: const {
              'type': 'object',
              'properties': {
                'file_id': {'type': 'integer'},
                'offset': {'type': 'integer', 'minimum': 0},
                'max_chars': {
                  'type': 'integer',
                  'minimum': 1,
                  'maximum': 12000
                },
                'start_line': {'type': 'integer', 'minimum': 1},
                'end_line': {'type': 'integer', 'minimum': 1},
                'page': {'type': 'integer', 'minimum': 1},
                'section': {'type': 'string'},
                'tail': {'type': 'boolean'},
              },
              'required': ['file_id'],
              'additionalProperties': false
            },
            execute: (args) async {
              final turn = _turn;
              final canCommit = _executionGuard;
              final result = await workspace.readFile(_id(args),
                  offset: _optionalInt(args, 'offset') ?? 0,
                  maxChars: _optionalInt(args, 'max_chars') ?? 12000,
                  startLine: _optionalInt(args, 'start_line'),
                  endLine: _optionalInt(args, 'end_line'),
                  page: _optionalInt(args, 'page'),
                  section: args['section'] as String?,
                  tail: args['tail'] == true);
              Future<void> record() => store.recordRead(
                  cid,
                  turn,
                  _id(args),
                  result['revision'] as int,
                  result['startOffset'] as int,
                  result['endOffset'] as int,
                  result['totalChars'] as int,
                  includeInput: result['kind'] == 'input',
                  canCommit: canCommit,
                  transactionGuard: _readTransactionGuard);
              if (_readStable != null) {
                await _readStable!(record);
              } else {
                await record();
              }
              lastReport = null;
              final source = LocalSourceCitation.fromToolResult(
                  toolName: 'read_file', content: result, expectedCid: cid);
              return ToolOutcome(
                  content: jsonEncode(result),
                  localSources: source == null ? const [] : [source]);
            }),
        ChatTool(
            name: 'file_search',
            description: '在当前工作区文件中查找文字并返回偏移定位；不计入全文阅读。',
            parameters: const {
              'type': 'object',
              'properties': {
                'file_id': {'type': 'integer'},
                'query': {'type': 'string'},
                'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 20}
              },
              'required': ['file_id', 'query'],
              'additionalProperties': false
            },
            execute: (args) async {
              final query = args['query'];
              if (query is! String || query.isEmpty) {
                throw const FormatException('搜索文字不能为空');
              }
              final result = await workspace.searchFile(_id(args), query,
                  maxResults: _optionalInt(args, 'max_results') ?? 20);
              return ToolOutcome(content: jsonEncode(result));
            }),
        ChatTool(
            name: 'write_file',
            description:
                '经用户确认创建/更新当前工作区 TXT/MD/CSV 输出，同名覆盖产生新版本；禁止写任意系统路径或输入文件。',
            parameters: const {
              'type': 'object',
              'properties': {
                'file_id': {'type': 'integer'},
                'name': {'type': 'string'},
                'content': {'type': 'string'},
                'note': {'type': 'string'},
              },
              'required': ['name', 'content'],
              'additionalProperties': false
            },
            execute: (args) async {
              final turn = _turn;
              final canCommit = _executionGuard;
              final name = args['name'], content = args['content'];
              if (name is! String ||
                  content is! String ||
                  name.trim().isEmpty ||
                  name.contains('/') ||
                  name.contains('\\') ||
                  !const ['txt', 'md', 'csv']
                      .contains(name.split('.').last.toLowerCase())) {
                throw const FormatException('请提供 TXT/MD/CSV 文件名和内容，不可使用路径');
              }
              final id = _optionalInt(args, 'file_id');
              if (id != null) {
                final existing = await workspace.getFile(id);
                if (existing == null || existing.kind != 'output') {
                  throw const FormatException('只能更新本工作区输出文件');
                }
              }
              if (confirm == null ||
                  !await confirm!(
                      '写入工作区输出：$name',
                      '文件：$name\n内容：${content.length} 字符\n'
                          '内容变化时，同名输出保存新版本。\n\n${content.length > 2000 ? '${content.substring(0, 2000)}\n…（预览截断）' : content}')) {
                return const ToolOutcome(content: '用户未批准写入，文件未修改。');
              }
              final file = await workspace.writeFile(
                  fileId: id,
                  name: name,
                  content: content,
                  note: args['note'] as String? ?? '',
                  canCommit: canCommit);
              await store.saveOutput(cid, turn, file.id, file.revision,
                  canCommit: canCommit);
              lastReport = null;
              return ToolOutcome(content: jsonEncode(file.toJson()));
            }),
        ChatTool(
            name: 'verify_task',
            description: '客观核对本轮阅读覆盖、真实输出、格式与用户条件；不检查语义，不修改条件或文件。',
            parameters: const {
              'type': 'object',
              'properties': <String, dynamic>{},
              'additionalProperties': false
            },
            execute: (_) async {
              final canCommit = _executionGuard;
              return ToolOutcome(
                  content: jsonEncode(
                      (await verify(canCommit: canCommit)).toJson()));
            }),
      ];

  static int _id(Map<String, dynamic> args) =>
      _optionalInt(args, 'file_id') ??
      (throw const FormatException('缺少 file_id'));
  static int? _optionalInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is! int) throw FormatException('$key 必须为整数');
    return value;
  }
}
