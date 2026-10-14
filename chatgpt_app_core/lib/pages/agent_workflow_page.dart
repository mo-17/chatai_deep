import 'dart:async';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workspace_file.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:chatgpt_app_core/pages/cloud_workflow_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/dao/login_dao.dart';

String workflowRoleLabel(WorkflowRole r) => switch (r) {
      WorkflowRole.analysis => '分析',
      WorkflowRole.writing => '撰写',
      WorkflowRole.review => '审阅',
    };
String workflowStateLabel(WorkflowState s) => switch (s) {
      WorkflowState.queued => '排队',
      WorkflowState.running => '执行中',
      WorkflowState.paused => '已暂停',
      WorkflowState.waitingConfirmation => '等待处理',
      WorkflowState.budgetExhausted => '预算已用尽',
      WorkflowState.needsConfiguration => '需要模型配置',
      WorkflowState.failed => '失败',
      WorkflowState.complete => '节点已完成',
      WorkflowState.cancelled => '已取消',
    };

/// 页面只观察应用级协调器，不将 State/Context 保留在运行对象里。
class AgentWorkflowPage extends StatefulWidget {
  final ConversationModel? conversation;
  final String initialTask;
  final String? parentId, expectedAccountHash;
  final HiDBManager? storage;
  final AgentWorkflowCoordinator? coordinator;
  final AgentWorkflowScope? scope;
  final Future<AISettings> Function()? loadSettings;
  const AgentWorkflowPage(
      {super.key,
      this.conversation,
      this.initialTask = '',
      this.parentId,
      this.expectedAccountHash,
      this.storage,
      this.coordinator,
      this.scope,
      this.loadSettings});
  @override
  State<AgentWorkflowPage> createState() => _AgentWorkflowPageState();
}

class _AgentWorkflowPageState extends State<AgentWorkflowPage> {
  AgentWorkflowScope? _scope;
  AgentWorkflowDao? _dao;
  AgentWorkspaceService? _workspace;
  AgentWorkspaceTools? _tools;
  late final AgentWorkflowCoordinator _coordinator;
  late final TextEditingController _task;
  Timer? _timer;
  bool _enabled = false,
      _background = true,
      _busy = true,
      _acting = false,
      _reloadNeeded = false,
      _hasMore = false;
  bool _configurationLoaded = false;
  bool _criteriaArmed = false;
  int _generation = 0, _offset = 0;
  String? _error, _parentId, _conversationFingerprint;
  List<AgentWorkflow> _rows = [];
  AgentWorkflow? _detail;
  List<WorkflowStep> _nodes = [];
  List<WorkflowModelChoice> _choices = [];
  final _profiles = <WorkflowRole, WorkflowModelProfile>{};
  final _selected = <int>{};
  final _refs = <int, WorkflowInputRef>{};
  List<AgentWorkspaceFile> _files = [];
  TaskAcceptanceCriteria _criteria = const TaskAcceptanceCriteria();
  bool get _current => mounted && _scope?.isCurrent == true;
  bool get _running =>
      _detail != null &&
      _scope != null &&
      _coordinator.busy(_scope!.accountHash, _detail!.id);
  @override
  void initState() {
    super.initState();
    final account = widget.expectedAccountHash ?? LoginDao.getAccountHash();
    if (account != null) {
      _scope = widget.scope ?? AgentWorkflowScope(accountHash: account);
    }
    _task = TextEditingController(text: widget.initialTask);
    _parentId = widget.parentId;
    _coordinator = widget.coordinator ?? AgentWorkflowCoordinator.instance;
    _coordinator.addListener(_changed);
    BackupService.restoreTick.addListener(_changed);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_current) {
        setState(() => _error = '账号、登录或恢复状态已变化，请返回后重新打开');
        return;
      }
      if (_reloadNeeded &&
          !_busy &&
          !_acting &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _reloadNeeded = false;
        unawaited(_load());
      }
    });
    unawaited(_load());
  }

  void _changed() => _reloadNeeded = true;
  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _task.dispose();
    _coordinator.removeListener(_changed);
    BackupService.restoreTick.removeListener(_changed);
    super.dispose();
  }

  void _check() {
    if (!_current) throw const WorkflowStale('页面已过期，请重新打开');
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      _check();
      if (_dao == null) {
        final storage = widget.storage ??
            await HiDBManager.instance(dbName: _scope!.accountHash);
        _check();
        _dao = await AgentWorkflowDao.create(storage,
            accountHash: _scope!.accountHash);
        _check();
      }
      if (widget.conversation != null && !_configurationLoaded) {
        final storage = _dao!.storage;
        _conversationFingerprint =
            await _dao!.captureConversation(_scope!, widget.conversation!.cid);
        _workspace = await AgentWorkspaceService.create(storage,
            cid: widget.conversation!.cid);
        _tools = await AgentWorkspaceTools.create(storage,
            cid: widget.conversation!.cid, workspace: _workspace!);
        _check();
        final settings = await (widget.loadSettings?.call() ??
            AISettingsDao.loadForAsync(_scope!.accountHash));
        _check();
        _choices = AgentWorkflowModels.choices(settings);
        for (final r in WorkflowRole.values) {
          if (_choices.isNotEmpty) _profiles[r] = _choices.first.profile;
        }
        _criteria = await _tools!.loadCriteria();
        _criteriaArmed =
            await _tools!.store.criteriaArmed(widget.conversation!.cid);
        _check();
        _files = (await _workspace!.listFiles())
            .where((f) =>
                f.isInput &&
                RegExp(r'\.(txt|md|csv|json|yaml|yml|log)$',
                        caseSensitive: false)
                    .hasMatch(f.name))
            .take(200)
            .toList();
        _configurationLoaded = true;
      }
      final offset = more ? _offset : 0;
      final rows =
          await _dao!.list(widget.conversation?.cid, limit: 30, offset: offset);
      _check();
      final recovered = <AgentWorkflow>[];
      for (final r in rows) {
        recovered.add(await _coordinator.recover(_dao!, _scope!, r));
        _check();
      }
      final detail = _parentId == null ? null : await _dao!.read(_parentId!);
      _check();
      final nodes =
          detail == null ? <WorkflowStep>[] : await _dao!.steps(detail.id);
      _check();
      if (generation != _generation) return;
      setState(() {
        _rows = more ? [..._rows, ...recovered] : recovered;
        _offset = offset + rows.length;
        _hasMore = rows.length == 30;
        _detail = detail;
        _nodes = nodes;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(
            () => _error = e is WorkflowStale ? e.reason : '记录或配置未能读取，请重试');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_acting || !_current) return;
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action();
      _check();
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is WorkflowStale
            ? e.reason
            : e is FormatException
                ? e.message
                : '操作未保存，请刷新后重试');
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  void _launch(AgentWorkflow task) {
    unawaited(_coordinator.start(_dao!, _scope!, task).then((_) async {
      if (_current) await _load();
    }));
  }

  Future<void> _submit() => _action(() async {
        _check();
        if (!_enabled || _profiles.length != 3 || _task.text.trim().isEmpty) {
          throw const FormatException('请启用本次协作、填写任务并选择三个模型');
        }
        final models =
            AgentWorkflowModels(_scope!, settings: widget.loadSettings);
        var canReadInputs = false;
        for (final p in _profiles.values) {
          if (!await models.available(p)) {
            throw const FormatException('所选模型不可用，请先配置服务');
          }
          _check();
          canReadInputs =
              (await models.service(p)).capabilities.tool || canReadInputs;
        }
        final acceptance = _selected.isEmpty && !_criteriaArmed
            ? const TaskAcceptanceCriteria(requireFullRead: false)
            : _criteria;
        AgentWorkflowDao.validateAcceptance(acceptance,
            inputCount: _selected.length, canReadInputs: canReadInputs);
        final w = await _dao!.createFromSource(_scope!,
            cid: widget.conversation!.cid,
            newTask: _task.text,
            newUserCreatedAt: DateTime.now().microsecondsSinceEpoch ~/ 1000,
            conversationIfMissing:
                ConversationModel.fromJson(widget.conversation!.toJson()),
            expectedConversationFingerprint: _conversationFingerprint,
            backgroundEnabled: _background,
            profiles: Map.from(_profiles),
            inputFileIds: _selected.toList(),
            expectedInputs: [for (final id in _selected) _refs[id]!],
            acceptance: acceptance,
            canReadInputs: canReadInputs,
            grantedTools:
                _selected.isEmpty ? {} : AgentWorkflowDao.readOnlyTools);
        _check();
        _parentId = w.id;
        _launch(w);
      });

  Future<void> _select(AgentWorkspaceFile file, bool selected) =>
      _action(() async {
        if (!selected) {
          _selected.remove(file.id);
          _refs.remove(file.id);
          return;
        }
        if (_selected.length >= 4) throw const FormatException('最多选择4个输入');
        final version =
            await _workspace!.getRevision(file.id, revision: file.revision);
        _check();
        _refs[file.id] = WorkflowInputRef(file.id, file.revision,
            file.contentHash, workflowHash(version.content));
        _selected.add(file.id);
      });
  Future<void> _addBudget() async {
    final task = _detail!;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('追加预算并继续'),
                content: const Text(
                    '追加2次请求、8000估算Token和10分钟。已用预算不返还，可能增加模型费用；估算不是供应商账单上限。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('追加并继续'))
                ]));
    if (ok != true || !_current) return;
    await _action(() async {
      final w = await _dao!.addBudget(_scope!, task.id, task.revision,
          dispatches: 2, estimatedTokens: 8000, milliseconds: 600000);
      _check();
      _launch(w);
    });
  }

  Future<void> _saveResult() async {
    final task = _detail!;
    try {
      final workspace =
          await AgentWorkspaceService.create(_dao!.storage, cid: task.cid);
      _check();
      if (!mounted) return;
      final names = task.acceptance['expectedOutputNames'] as List? ?? [];
      final controller = TextEditingController(
          text: names.isNotEmpty
              ? names.first as String
              : '协作成果_${task.id.substring(0, 8)}.md');
      final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('确认保存成果'),
                  content: TextField(
                      controller: controller,
                      decoration:
                          const InputDecoration(labelText: 'TXT/MD/CSV 文件名')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, controller.text),
                        child: const Text('确认保存'))
                  ]));
      controller.dispose();
      if (name == null || !_current) return;
      final targets = (await workspace.listFiles())
          .where((f) => !f.isInput && f.name == name)
          .toList();
      _check();
      final target = targets.isEmpty ? null : targets.single;
      if (!mounted) return;
      if (target != null) {
        final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('覆盖已有成果？'),
                    content: Text('保存 $name 新版本；现有版本 ${target.revision} 会保留。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('确认覆盖'))
                    ]));
        if (ok != true || !_current) return;
      }
      await _action(() async {
        await _dao!.publishOutputOnce(_scope!, task,
            name: name,
            expectedFileId: target?.id,
            expectedRevision: target?.revision);
        _check();
        await _recheck(task);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is WorkflowStale ? e.reason : '成果未保存，请刷新后重试');
      }
    }
  }

  Future<void> _recheck(AgentWorkflow task) async {
    final tools = await AgentWorkspaceTools.create(_dao!.storage,
        cid: task.cid,
        workspace:
            await AgentWorkspaceService.create(_dao!.storage, cid: task.cid));
    _check();
    await tools.beginTurn(await _dao!.sourceCreatedAt(_scope!, task.id),
        task.inputs.map((i) => i.fileId).toList(),
        resume: true,
        criteriaOverride: TaskAcceptanceCriteria.fromJson(task.acceptance),
        executionGuard: () => _current,
        transactionGuard: (tx) =>
            _dao!.verifySnapshotTransaction(_scope!, task, tx),
        stableOperation: (action) => _scope!.stable(action));
    final report = await tools.verify(canCommit: () => _current);
    _check();
    final updated = await _dao!.acceptVerification(_scope!, task, report);
    _check();
    if (updated.state == WorkflowState.complete) {
      await _coordinator.publishReply(_dao!, _scope!, updated);
    }
  }

  Widget _configuration() => AppVisualSurface(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('本次启用三Agent协作'),
            subtitle: const Text('分析 → 撰写 → 审阅，独立请求、顺序执行。普通和单Agent模式不变。'),
            value: _enabled,
            onChanged: _acting ? null : (v) => setState(() => _enabled = v)),
        TextField(
            key: const ValueKey('workflow-task'),
            controller: _task,
            enabled: !_acting,
            minLines: 3,
            maxLines: 8,
            maxLength: 12000,
            decoration: const InputDecoration(
                labelText: '本次任务', border: OutlineInputBorder())),
        for (final r in WorkflowRole.values)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: DropdownButtonFormField<String>(
                  key: ValueKey('workflow-profile-${r.name}'),
                  initialValue: _profiles[r] == null
                      ? null
                      : '${_profiles[r]!.mode}:${_profiles[r]!.providerId}:${_profiles[r]!.modelId}',
                  isExpanded: true,
                  decoration:
                      InputDecoration(labelText: '${workflowRoleLabel(r)}模型'),
                  items: [
                    for (final c in _choices)
                      DropdownMenuItem(
                          value: c.key,
                          child: Text(c.label, overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: _acting
                      ? null
                      : (v) => setState(() => _profiles[r] =
                          _choices.singleWhere((c) => c.key == v).profile))),
        const Text('只使用本次正文与勾选的文本输入。不会读取其他对话、个人/助手记忆或角色卡元数据；不授权网络、MCP或写工具。'),
        if (_criteriaArmed || _selected.isNotEmpty)
          Text(
              '本次文件验收：${_criteria.requireFullRead ? '完整读取选中文本；' : ''}预期输出 ${_criteria.expectedOutputNames.isEmpty ? '无' : _criteria.expectedOutputNames.join('、')}；格式 ${_criteria.format ?? '按文件名'}；字符 ${_criteria.minChars ?? 0}–${_criteria.maxChars ?? 12000}；必须包含 ${_criteria.requiredTerms.isEmpty ? '无' : _criteria.requiredTerms.join('、')}'),
        for (final f in _files)
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(f.name),
              subtitle: Text('版本 ${f.revision} · ${f.characterCount} 字符'),
              value: _selected.contains(f.id),
              onChanged: _acting ? null : (v) => _select(f, v == true)),
        const Text('最多4个文本工作区输入；新文件请先在工作区导入。'),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许本机后台继续'),
            subtitle: const Text('仅延续获准的当前任务；系统可中断。退出或杀进程后需明确继续，不能全天托管。'),
            value: _background,
            onChanged: _acting ? null : (v) => setState(() => _background = v)),
        const Text(
            '最多8次实际请求（含工具续写和返工），每节点2轮工具、每次输出2048Token；累计32000估算Token、10分钟、一次返工。无配置价格时费用未知，估算不是账单硬上限。'),
        const SizedBox(height: 12),
        FilledButton(
            key: const ValueKey('workflow-start'),
            onPressed: _enabled && !_acting && _current ? _submit : null,
            child: const Text('开始协作')),
      ]));
  Widget _detailView() {
    final w = _detail!;
    final runner = _coordinator.lookup(_scope!.accountHash, w.id);
    final report = w.verification == null
        ? null
        : AgentTaskVerificationReport.fromJson(w.verification!);
    return AppVisualSurface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('任务：${workflowStateLabel(w.state)}',
          style: Theme.of(context).textTheme.titleLarge),
      SelectableText(w.task),
      if (w.reason != null) Text(w.reason!),
      if (_running) Text(runner?.stage ?? '等待执行'),
      if (runner?.backgroundNotice != null) Text(runner!.backgroundNotice!),
      Text(
          '实际请求 ${w.dispatches}/${w.maxDispatches} · 累计估算 ${w.reservedTokens}/${w.estimatedTokenLimit} Token'),
      Text(
          '已报用量：输入 ${w.actualInputTokens} / 输出 ${w.actualOutputTokens}${w.usageUnknown ? '，部分未知' : ''} · ${w.estimatedCost == null ? '费用未知' : '费用估算 ${w.estimatedCost}'}'),
      const Text('节点审阅只是模型意见；客观验收基于文件版本、实际读取与用户条件。'),
      for (final n in _nodes)
        ExpansionTile(
            key: ValueKey('workflow-node-${n.role.name}'),
            tilePadding: EdgeInsets.zero,
            title: Text(
                '${workflowRoleLabel(n.role)} · ${workflowStateLabel(n.state)}'),
            subtitle: Text('${n.profile.modelId} · 工具轮数 ${n.toolRounds}/2'),
            children: [
              SelectableText(n.result.isEmpty ? '尚无已提交结果' : n.result)
            ]),
      if (report != null) ...[
        Text(report.summary),
        for (final c in report.checks)
          Text('${c.passed ? '✓' : '待处理'} ${c.label}：${c.detail}')
      ],
      if (_coordinator
              .notices[AgentWorkflowCoordinator.key(_scope!.accountHash, w.id)]
          case final notice?)
        Text(notice),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (_running || w.state == WorkflowState.queued)
          OutlinedButton(
              onPressed: _acting || !_current
                  ? null
                  : () => _action(() => _coordinator.stop(_dao!, _scope!, w)),
              child: const Text('停止任务')),
        if (!_running &&
            const [WorkflowState.paused, WorkflowState.needsConfiguration]
                .contains(w.state))
          FilledButton(
              onPressed: _acting || !_current
                  ? null
                  : () => _action(() async {
                        _launch(w);
                      }),
              child: const Text('明确继续')),
        if (!_running &&
            const [WorkflowState.paused, WorkflowState.budgetExhausted]
                .contains(w.state))
          OutlinedButton(
              onPressed: _acting || !_current ? null : _addBudget,
              child: const Text('追加预算并继续')),
        if (!_running &&
            const [WorkflowState.complete, WorkflowState.waitingConfirmation]
                .contains(w.state)) ...[
          OutlinedButton(
              onPressed: _acting || !_current ? null : _saveResult,
              child: const Text('确认保存成果')),
          OutlinedButton(
              onPressed: _acting || !_current
                  ? null
                  : () => _action(() => _recheck(w)),
              child: const Text('重新验收'))
        ],
        if (!_running &&
            w.state != WorkflowState.complete &&
            w.state != WorkflowState.cancelled)
          TextButton(
              onPressed: _acting || !_current
                  ? null
                  : () => _action(
                      () => _coordinator.stop(_dao!, _scope!, w, cancel: true)),
              child: const Text('结束任务')),
        if (_nodes
            .any((n) => n.role == WorkflowRole.writing && n.result.isNotEmpty))
          TextButton(
              onPressed: !_current
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(
                          text: _nodes
                              .singleWhere(
                                  (n) => n.role == WorkflowRole.writing)
                              .result));
                      if (mounted && _current) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('稿件已复制')));
                      }
                    },
              child: const Text('复制稿件')),
      ]),
    ]));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('多Agent协作'), actions: [
        IconButton(
            tooltip: '云任务',
            icon: const Icon(Icons.cloud_outlined),
            onPressed: _scope?.isCurrent == true
                ? () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => CloudWorkflowPage(
                            cid: widget.conversation?.cid,
                            expectedAccountHash: _scope!.accountHash)))
                : null),
        IconButton(
            tooltip: '刷新',
            onPressed: _busy || _acting ? null : _load,
            icon: const Icon(Icons.refresh))
      ]),
      body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('本机分工，顺序执行；中断后不自动计费。执行记录不随备份或游客迁移，已确认成果沿用工作区备份。'),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_busy || _acting) const LinearProgressIndicator(),
        if (!_busy &&
            widget.conversation != null &&
            _parentId == null &&
            _current)
          _configuration(),
        if (_detail != null && _current) _detailView(),
        if (_current)
          TextButton(
              onPressed: _acting
                  ? null
                  : () => _action(() => _coordinator.stopAll(_scope!)),
              child: const Text('停止全部本机任务')),
        const Divider(),
        const Text('本地协作记录'),
        for (final r in _rows)
          ListTile(
              title: Text(r.task, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle:
                  Text('${workflowStateLabel(r.state)} · ${r.dispatches} 次请求'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _acting || !_current
                  ? null
                  : () {
                      setState(() => _parentId = r.id);
                      unawaited(_load());
                    }),
        if (_hasMore)
          TextButton(
              onPressed: _busy || _acting ? null : () => _load(more: true),
              child: const Text('加载更多记录')),
      ])));
}
